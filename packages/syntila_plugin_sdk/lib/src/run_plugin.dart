import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';

import 'plugin_worker.dart';

/// Runs [plugin] over stdin/stdout until the host shuts it down or closes
/// stdin. `print` is redirected to stderr so stdout stays pure protocol.
///
/// Dart is single-threaded per isolate: a long synchronous loop in `execute`
/// stops heartbeats and cancel handling. Use `await` points, or compute in an
/// isolate, and check `context.isCancelled` between steps.
Future<void> runPlugin(
  PluginWorker plugin, {
  Stream<List<int>>? input,
  IOSink? output,
  IOSink? log,
}) {
  final sink = output ?? stdout;
  final errors = log ?? stderr;
  return runZoned(
    () => _Runner(plugin, input ?? stdin, sink, errors).run(),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => errors.writeln(line),
    ),
  );
}

class _Runner implements WorkContext {
  _Runner(this.plugin, this.input, this.out, this.log);

  final PluginWorker plugin;
  final Stream<List<int>> input;
  final IOSink out;
  final IOSink log;

  String _dataDirectory = Directory.systemTemp.path;
  String? _activeId;
  Completer<void>? _cancel;
  var _terminalSent = false;
  var _helloDone = false;
  final _progressClock = Stopwatch()..start();
  int _lastProgressMs = -1000;
  final _tasks = <Future<void>>[];
  Future<void> _writes = Future<void>.value();

  @override
  String get dataDirectory => _dataDirectory;

  @override
  bool get isCancelled => _cancel?.isCompleted ?? false;

  @override
  Future<void> get cancelled => _cancel?.future ?? Completer<void>().future;

  @override
  void progress(String message, {int? percent}) {
    final id = _activeId;
    if (id == null || _terminalSent) return;
    final now = _progressClock.elapsedMilliseconds;
    if (now - _lastProgressMs < 50) return;
    _lastProgressMs = now;
    _send({
      'type': 'progress',
      'id': id,
      'message': message.length > 2000 ? message.substring(0, 2000) : message,
      if (percent != null) 'percent': percent.clamp(0, 100),
    });
  }

  void _send(Map<String, Object?> frame) {
    final line = jsonEncode(frame);
    if (utf8.encode(line).length + 1 > PluginProtocolLimits.maxFrameBytes) {
      log.writeln('dropped an oversize ${frame['type']} frame');
      return;
    }
    _writes = _writes.then((_) async {
      out.writeln(line);
      await out.flush();
    }).catchError((Object _) {});
  }

  Future<void> run() async {
    final lines = input.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      final PluginFrame frame;
      try {
        frame = decodePluginFrame(line, PluginDirection.hostToPlugin);
      } on PluginFrameException {
        _send({
          'type': 'error',
          'code': 'unsupported_frame',
          'message': 'Unrecognized frame',
          'retryable': false,
        });
        continue;
      }
      try {
        if (!await _handle(frame)) return;
      } on Object catch (error) {
        // A bug while handling one frame must not take the plugin down.
        log.writeln('frame handler failed: ${error.runtimeType}');
      }
    }
    // Host closed stdin: finish what is running, then leave.
    await Future.wait(_tasks);
    await _writes;
  }

  /// Returns false when the plugin should exit.
  Future<bool> _handle(PluginFrame frame) async {
    switch (frame.type) {
      case 'hello':
        if (!_hello(frame)) {
          await _writes;
          return false;
        }
      case 'probe':
        _tasks.add(_probe(frame));
      case 'models.list':
        if (_helloDone) _tasks.add(_listModels(frame));
      case 'execute':
        _tasks.add(_execute(frame));
      case 'cancel':
        // Idempotent: a repeated cancel is harmless.
        final cancel = _cancel;
        if (frame.id == _activeId && cancel != null && !cancel.isCompleted) {
          cancel.complete();
        }
      case 'ping':
        _send({'type': 'pong', 'nonce': frame.json['nonce']});
      case 'pong':
        break;
      case 'shutdown':
        await _writes;
        return false;
    }
    return true;
  }

  bool _hello(PluginFrame frame) {
    final protocol = Map<String, Object?>.from(frame.json['protocol'] as Map);
    final supported = List<String>.from(protocol['supported'] as List);
    final selected = PluginProtocolLimits.supportedProtocolVersions
        .where(supported.contains)
        .firstOrNull;
    if (selected == null) {
      _send({
        'type': 'error',
        'code': 'unsupported_protocol',
        'message': 'This plugin speaks ${PluginProtocolLimits.protocolVersion}',
        'retryable': false,
      });
      return false;
    }
    _dataDirectory = frame.json['dataDir'] as String;
    _helloDone = true;
    _send({
      'type': 'hello.result',
      'id': frame.id,
      'protocol': selected,
      'plugin': {
        'id': plugin.id,
        'version': plugin.version,
        'name': plugin.name
      },
      'capabilities': plugin.capabilities,
    });
    return true;
  }

  Future<void> _listModels(PluginFrame frame) async {
    try {
      if (plugin.capabilities['modelDiscovery'] != true) {
        throw const PluginFailure(
            'unsupported_frame', 'Model discovery is not supported');
      }
      final models = (await plugin.discoverModels())
          .map((model) => model.toJson())
          .toList();
      validatePluginModels(models);
      _send({'type': 'models.list.result', 'id': frame.id, 'models': models});
    } on Object {
      _send({
        'type': 'error',
        'id': frame.id,
        'code': 'not_ready',
        'message': 'Model discovery failed',
        'retryable': true
      });
    }
  }

  Future<void> _probe(PluginFrame frame) async {
    PluginReadiness readiness;
    try {
      readiness = await plugin.probe(live: frame.json['mode'] == 'live');
    } on Object catch (error) {
      log.writeln('probe failed: ${error.runtimeType}');
      readiness = const PluginReadiness.unavailable('probe_failed');
    }
    _send({
      'type': 'probe.result',
      'id': frame.id,
      'state': readiness.state,
      if (readiness.issueCode != null) 'issueCode': readiness.issueCode,
      'checks': [
        for (final check
            in readiness.checks.take(PluginProtocolLimits.maxChecks))
          {
            'code': check.code,
            'ok': check.ok,
            if (check.message != null) 'message': check.message,
          },
      ],
    });
  }

  Future<void> _execute(PluginFrame frame) async {
    if (!_helloDone) return;
    if (_activeId != null) {
      _send({
        'type': 'error',
        'id': frame.id,
        'code': 'invalid_request',
        'message': 'One request at a time',
        'retryable': true,
      });
      return;
    }
    final id = frame.id!;
    _activeId = id;
    _terminalSent = false;
    _cancel = Completer<void>();
    final session = frame.json['session'];
    final request = WorkRequest(
      id: id,
      prompt: frame.json['prompt'] as String,
      workingDirectory: frame.json['workingDirectory'] as String,
      readOnly: frame.json['access'] == 'read_only',
      deadline: Duration(milliseconds: frame.json['deadlineMs'] as int),
      model: frame.json['model'] as String?,
      sessionKey: session is Map ? session['key'] as String? : null,
      resumeSession: session is Map && session['mode'] == 'resume',
      rebuildSession: session is Map && session['mode'] == 'rebuild',
    );
    try {
      final result = await plugin.execute(request, this);
      if (isCancelled && !_terminalSent) {
        _finish({
          'type': 'error',
          'id': id,
          'code': 'cancelled',
          'message': 'Cancelled',
          'retryable': false,
        });
      } else if (utf8.encode(result.output).length >
          PluginProtocolLimits.maxOutputBytes) {
        _finish({
          'type': 'error',
          'id': id,
          'code': 'output_too_large',
          'message': 'Output exceeds the protocol limit',
          'retryable': false,
        });
      } else {
        _finish({
          'type': 'result',
          'id': id,
          'output': result.output,
          'artifacts': [
            for (final path in result.artifacts) {'path': path},
          ],
          if (result.sessionState != null)
            'session': {'state': result.sessionState},
        });
      }
    } on PluginFailure catch (failure) {
      _finish({
        'type': 'error',
        'id': id,
        'code': failure.code,
        'message': failure.message,
        'retryable': failure.retryable,
      });
    } on Object catch (error) {
      // Never leak internals or stack traces into a frame.
      log.writeln('execute failed: ${error.runtimeType}');
      _finish({
        'type': 'error',
        'id': id,
        'code': 'internal',
        'message': 'The plugin failed',
        'retryable': false,
      });
    }
  }

  /// Exactly one terminal frame per request, whatever happens.
  void _finish(Map<String, Object?> frame) {
    if (_terminalSent) return;
    try {
      decodePluginFrame(jsonEncode(frame), PluginDirection.pluginToHost);
    } on PluginFrameException {
      frame = {
        'type': 'error',
        'id': _activeId,
        'code': 'internal',
        'message': 'The plugin produced an invalid response',
        'retryable': false,
      };
    }
    _terminalSent = true;
    _send(frame);
    _activeId = null;
  }
}
