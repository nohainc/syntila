import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:syntila_plugin_sdk/syntila_plugin_sdk.dart';

class OllamaLocalWorker extends PluginWorker {
  OllamaLocalWorker(
      {this.executable = const String.fromEnvironment('OLLAMA_EXECUTABLE',
          defaultValue: '/opt/homebrew/bin/ollama'),
      this.model = const String.fromEnvironment('OLLAMA_MODEL',
          defaultValue: 'llama3.2:3b')});
  final String executable;
  final String model;
  @override
  String get id => 'ollama-local';
  @override
  String get version => '1.0.0';
  @override
  String get name => 'Ollama Local';

  Future<String> _run(List<String> args,
      {String? prompt, WorkRequest? request, WorkContext? context}) async {
    if (!File(executable).isAbsolute || !File(executable).existsSync()) {
      throw const PluginFailure('not_ready', 'Ollama executable is missing');
    }
    final child = await Process.start(executable, args,
        runInShell: false,
        includeParentEnvironment: false,
        environment: {
          'PATH': '/usr/bin:/bin',
          if (Platform.environment['HOME'] case final home?) 'HOME': home,
          'OLLAMA_HOST': '127.0.0.1:11434',
          'TERM': 'dumb',
          'NO_COLOR': '1',
        });
    var timeout = false;
    var cancelled = false;
    var oversized = false;
    final timer = Timer(request?.deadline ?? const Duration(seconds: 8), () {
      timeout = true;
      child.kill(ProcessSignal.sigkill);
    });
    final cancel = context?.cancelled.asStream().listen((_) {
      cancelled = true;
      child.kill(ProcessSignal.sigkill);
    });
    final bytes = <int>[];
    final output = child.stdout.listen((chunk) {
      if (bytes.length + chunk.length > 700 * 1024) {
        oversized = true;
        child.kill(ProcessSignal.sigkill);
      } else {
        bytes.addAll(chunk);
      }
    }).asFuture<void>();
    final errors = child.stderr.drain<void>();
    try {
      if (context?.isCancelled ?? false) {
        cancelled = true;
        child.kill(ProcessSignal.sigkill);
      }
      if (prompt != null) child.stdin.add(utf8.encode(prompt));
      try {
        await child.stdin.close();
      } on IOException {/* Check exit below. */}
      final status = await child.exitCode;
      await Future.wait([output, errors]);
      if (cancelled) throw const PluginFailure('cancelled', 'Cancelled');
      if (timeout) throw const PluginFailure('timeout', 'Ollama timed out');
      if (oversized)
        throw const PluginFailure('output_too_large', 'Output is too large');
      if (status != 0)
        throw const PluginFailure('not_ready', 'Local Ollama command failed');
      return utf8.decode(bytes, allowMalformed: true).trim();
    } finally {
      timer.cancel();
      await cancel?.cancel();
      child.kill(ProcessSignal.sigkill);
    }
  }

  Future<bool> _hasModel({WorkContext? context}) async {
    final listing = await _run(['list'], context: context);
    return listing
        .split('\n')
        .skip(1)
        .map((line) => line.trim().split(RegExp(r'\s+')).first)
        .contains(model);
  }

  @override
  Future<PluginReadiness> probe({required bool live}) async {
    try {
      if (!await _hasModel()) {
        return const PluginReadiness.setupRequired('ollama_model_missing');
      }
      return const PluginReadiness.ready();
    } catch (_) {
      return const PluginReadiness.unavailable('ollama_unavailable');
    }
  }

  @override
  Future<WorkResult> execute(WorkRequest request, WorkContext context) async {
    if (utf8.encode(request.prompt).length > 24 * 1024) {
      throw const PluginFailure(
          'invalid_request', 'Prompt exceeds the local worker limit of 24 KiB');
    }
    if (request.model != null && request.model != model) {
      throw const PluginFailure('invalid_request', 'Unsupported model');
    }
    if (!await _hasModel(context: context)) {
      throw const PluginFailure(
          'not_ready', 'Install the configured local model first');
    }
    context.progress('Running the local model');
    return WorkResult(await _run(['run', model, '--nowordwrap'],
        prompt: request.prompt, request: request, context: context));
  }
}
