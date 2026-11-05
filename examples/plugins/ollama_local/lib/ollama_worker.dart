import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:syntila_plugin_sdk/syntila_plugin_sdk.dart';

class OllamaLocalWorker extends PluginWorker {
  OllamaLocalWorker(
      {this.executable = const String.fromEnvironment('OLLAMA_EXECUTABLE',
          defaultValue: '/opt/homebrew/bin/ollama'),
      this.model});
  final String executable;

  /// Optional installation default; requests may select any discovered model.
  final String? model;
  @override
  String get id => 'ollama-local';
  @override
  String get version => '1.3.0';
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
    final errorBytes = <int>[];
    final errors = child.stderr.listen((chunk) {
      if (errorBytes.length < 16384) {
        errorBytes.addAll(chunk.take(16384 - errorBytes.length));
      }
    }).asFuture<void>();
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
      if (status != 0) {
        final detail =
            utf8.decode(errorBytes, allowMalformed: true).toLowerCase();
        if (RegExp(
                r'context (?:window|length|size).*(?:exceed|too (?:long|large)|limit)|(?:exceed|too (?:long|large)).*context (?:window|length|size)')
            .hasMatch(detail)) {
          throw const PluginFailure('context_limit_exceeded',
              'The conversation exceeds the model context window. Start a new conversation or reduce the context.');
        }
        throw const PluginFailure('not_ready', 'Local Ollama command failed');
      }
      return utf8.decode(bytes, allowMalformed: true).trim();
    } finally {
      timer.cancel();
      await cancel?.cancel();
      child.kill(ProcessSignal.sigkill);
    }
  }

  @override
  Map<String, Object?> get capabilities => const {
        'progress': true,
        'modelDiscovery': true,
        'continuity': {'strategy': 'history_replay'},
      };

  /// Native names remain local; namespaces map to stable safe public IDs.
  static String modelId(String native) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(native)
          ? native
          : 'model-${sha256.convert(utf8.encode(native))}';

  Future<Map<String, String>> _models(
      {WorkContext? context, WorkRequest? request}) async {
    final listing = await _run(['list'], context: context, request: request);
    final lines = const LineSplitter().convert(listing);
    if (lines.isEmpty || !lines.first.startsWith('NAME')) {
      throw const PluginFailure(
          'not_ready', 'Unrecognized Ollama model listing');
    }
    final models = <String, String>{};
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final native = line.trim().split(RegExp(r'\s+')).first;
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$').hasMatch(native)) {
        throw const PluginFailure('not_ready', 'Invalid Ollama model name');
      }
      // Explicit cloud entries and adapter-owned conversation snapshots are
      // not installed base models for this local text-generation adapter.
      if (native.endsWith(':cloud') || native.startsWith('syntila-session-'))
        continue;
      final id = modelId(native);
      if (models.containsKey(id))
        throw const PluginFailure('not_ready', 'Duplicate model');
      models[id] = native;
      if (models.length > 128)
        throw const PluginFailure('not_ready', 'Too many installed models');
    }
    return models;
  }

  @override
  Future<List<PluginModel>> discoverModels() async => [
        for (final entry in (await _models()).entries)
          PluginModel(id: entry.key, name: entry.value),
      ];

  @override
  Future<PluginReadiness> probe({required bool live}) async {
    if (!File(executable).isAbsolute || !File(executable).existsSync()) {
      return const PluginReadiness.unavailable('ollama_unavailable');
    }
    // Passive probes must not contact the daemon or load a model.
    if (!live) return const PluginReadiness.ready();
    try {
      final models = await _models();
      if (models.isEmpty || (model != null && !models.containsValue(model))) {
        return const PluginReadiness.setupRequired('ollama_model_missing');
      }
      return const PluginReadiness.ready();
    } catch (_) {
      return const PluginReadiness.unavailable('ollama_unavailable');
    }
  }

  @override
  Future<WorkResult> execute(WorkRequest request, WorkContext context) async {
    final clock = Stopwatch()..start();
    final models = await _models(context: context, request: request);
    final selected = request.model ??
        (model == null ? null : modelId(model!)) ??
        (models.length == 1 ? models.keys.single : null);
    if (selected == null) {
      throw const PluginFailure(
          'model_unavailable', 'Select an installed Ollama model');
    }
    final native = models[selected];
    if (native == null) {
      throw const PluginFailure(
          'model_unavailable', 'The selected model is no longer installed');
    }
    final remaining = request.deadline - clock.elapsed;
    if (remaining <= Duration.zero)
      throw const PluginFailure('timeout', 'Ollama timed out');
    context.progress('Running the selected local model');
    final bounded = WorkRequest(
        id: request.id,
        prompt: request.prompt,
        workingDirectory: request.workingDirectory,
        readOnly: request.readOnly,
        deadline: remaining);
    return WorkResult(await _run(['run', native, '--nowordwrap'],
        prompt: request.prompt, request: bounded, context: context));
  }
}
