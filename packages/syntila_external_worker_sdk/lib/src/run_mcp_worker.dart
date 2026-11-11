import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_external_worker_protocol/syntila_external_worker_protocol.dart'
    show ExternalWorkerLimits, validateExternalWorkerModels;

import 'external_worker.dart';

/// Runs [worker] as a Syntila MCP Worker (MCP_WORKER_PROFILE_V1) over
/// stdin/stdout until stdin closes.
///
/// Provides `syntila.execute` and `syntila.probe`, plus `syntila.models` when the
/// Worker declares `modelDiscovery: true`. Exactly one answer is sent per
/// request, `print` goes to stderr so stdout stays pure protocol, and a cancel
/// (`notifications/cancelled`) completes [WorkContext.cancelled].
///
/// Dart is single-threaded per isolate: a long synchronous loop in `execute`
/// blocks cancel handling. Use `await` points and check `context.isCancelled`.
Future<void> runMcpWorker(
  ExternalWorker worker, {
  Stream<List<int>>? input,
  IOSink? output,
  IOSink? log,
}) {
  final errors = log ?? stderr;
  return runZoned(
    () => _McpRunner(worker, input ?? stdin, output ?? stdout, errors).run(),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => errors.writeln(line),
    ),
  );
}

const _executeTool = 'syntila.execute';
const _probeTool = 'syntila.probe';
const _modelsTool = 'syntila.models';

class _McpRunner {
  _McpRunner(this.worker, this.input, this.out, this.log);

  final ExternalWorker worker;
  final Stream<List<int>> input;
  final IOSink out;
  final IOSink log;

  final _tasks = <Future<void>>[];
  Future<void> _writes = Future<void>.value();
  _Call? _active;

  bool get _modelDiscovery => worker.capabilities['modelDiscovery'] == true;

  void _send(JsonRpcMessage message) {
    final String line;
    try {
      line = encodeMessage(message);
    } on McpException {
      log.writeln('dropped an oversize message');
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
      if (line.trim().isEmpty) continue;
      final JsonRpcMessage message;
      try {
        message = decodeMessage(line);
      } on McpException {
        _send(const JsonRpcError(
            null, JsonRpcCodes.parseError, 'Invalid message'));
        continue;
      }
      try {
        _handle(message);
      } on Object catch (error) {
        // A bug while handling one message must not take the Worker down.
        log.writeln('message handler failed: ${error.runtimeType}');
      }
    }
    // Host closed stdin: finish what is running, then leave.
    await Future.wait(_tasks);
    await _writes;
  }

  void _handle(JsonRpcMessage message) {
    switch (message) {
      case JsonRpcRequest():
        _request(message);
      case JsonRpcNotification():
        if (message.method == 'notifications/cancelled') {
          final call = _active;
          final id = message.params?['requestId'];
          if (call != null && call.id == id) call.cancel();
        }
      case JsonRpcResponse() || JsonRpcError():
        break; // This server sends no requests, so there is nothing to match.
    }
  }

  void _request(JsonRpcRequest request) {
    switch (request.method) {
      case 'initialize':
        final asked = request.params?['protocolVersion'];
        _send(JsonRpcResponse(request.id, {
          'protocolVersion': McpLimits.supportedProtocolVersions.contains(asked)
              ? asked
              : McpLimits.supportedProtocolVersions.first,
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': worker.name, 'version': worker.version},
          '_meta': {'syntila.worker': '1'},
        }));
      case 'ping':
        _send(JsonRpcResponse(request.id, <String, Object?>{}));
      case 'tools/list':
        _send(JsonRpcResponse(request.id, {
          'tools': [
            _tool(_executeTool, 'Run an assignment.'),
            _tool(_probeTool, 'Report readiness.'),
            if (_modelDiscovery) _tool(_modelsTool, 'List selectable models.'),
          ],
        }));
      case 'tools/call':
        // Not awaited: the loop must keep reading so a cancel can arrive.
        _tasks.add(_call(request));
      default:
        _send(JsonRpcError(
          request.id,
          JsonRpcCodes.methodNotFound,
          'Method not found',
        ));
    }
  }

  Map<String, Object?> _tool(String name, String description) => {
        'name': name,
        // Part of the pinned definition: changing it re-triggers consent.
        'description': description,
        'inputSchema': {'type': 'object'},
      };

  Future<void> _call(JsonRpcRequest request) async {
    final params = request.params ?? const <String, Object?>{};
    final args = (params['arguments'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    final token = (params['_meta'] as Map?)?['progressToken'];
    Map<String, Object?> result;
    _Call? call;
    try {
      switch (params['name']) {
        case _executeTool:
          if (_active != null) {
            result = _failure('invalid_request', 'One request at a time',
                retryable: true);
            break;
          }
          call = _active = _Call(request.id, token, this);
          result = await _execute(args, call);
        case _probeTool:
          result = await _probe(args['mode'] == 'live');
        case _modelsTool when _modelDiscovery:
          result = await _models();
        default:
          result = _failure('invalid_request', 'Unknown tool');
      }
    } on ExternalWorkerFailure catch (failure) {
      result =
          _failure(failure.code, failure.message, retryable: failure.retryable);
    } on Object catch (error) {
      // Never leak internals or stack traces into a response.
      log.writeln('tool failed: ${error.runtimeType}');
      result = _failure('internal', 'The plugin failed');
    } finally {
      if (identical(_active, call)) _active = null;
    }
    _send(JsonRpcResponse(request.id, result));
  }

  Future<Map<String, Object?>> _execute(
    Map<String, Object?> args,
    _Call call,
  ) async {
    final prompt = args['prompt'];
    if (prompt is! String || prompt.isEmpty) {
      return _failure('invalid_request', 'The prompt is empty');
    }
    var deadline = const Duration(minutes: 10);
    final stamp = DateTime.tryParse('${args['deadline']}');
    if (stamp != null) {
      deadline = stamp.difference(DateTime.now());
      if (deadline <= Duration.zero) {
        return _failure('timeout', 'The deadline had already passed',
            retryable: true);
      }
    }
    final session = args['session'];
    final mode = session is Map ? session['mode'] : null;
    ExternalWorkerConversation? conversation;
    if (args['conversation'] != null) {
      try {
        final raw = args['conversation'];
        if (raw is! Map) throw const FormatException('Invalid conversation');
        conversation =
            ExternalWorkerConversation.fromJson(Map<String, Object?>.from(raw));
      } on FormatException {
        return _failure('invalid_request', 'Invalid conversation');
      } on TypeError {
        return _failure('invalid_request', 'Invalid conversation');
      }
    }
    ExternalWorkerExecution? execution;
    if (args['execution'] != null) {
      try {
        execution = ExternalWorkerExecution.fromJson(
            Map<String, Object?>.from(args['execution'] as Map));
      } on Object {
        return _failure('invalid_request', 'Invalid execution metadata');
      }
    }
    final request = WorkRequest(
      execution: execution,
      id: '${call.id}',
      prompt: prompt,
      conversation: conversation,
      workingDirectory:
          args['workingDirectory'] as String? ?? Directory.current.path,
      readOnly: args['access'] == 'restricted',
      deadline: deadline,
      model: args['model'] as String?,
      sessionKey: session is Map ? session['key'] as String? : null,
      resumeSession: mode == 'resume',
      rebuildSession: mode == 'rebuild',
    );
    final result = await worker.execute(request, call);
    if (call.isCancelled) return _failure('cancelled', 'Cancelled');
    if (utf8.encode(result.output).length >
        ExternalWorkerLimits.maxOutputBytes) {
      return _failure('output_too_large', 'Output exceeds the protocol limit');
    }
    return {
      'content': [
        {'type': 'text', 'text': result.output},
      ],
      'structuredContent': {
        'text': result.output,
        if (result.artifacts.isNotEmpty) 'artifacts': result.artifacts,
        if (result.sessionState != null)
          'session': {'state': result.sessionState},
      },
    };
  }

  Future<Map<String, Object?>> _probe(bool live) async {
    ExternalWorkerReadiness readiness;
    try {
      readiness = await worker.probe(live: live);
    } on Object catch (error) {
      log.writeln('probe failed: ${error.runtimeType}');
      readiness = const ExternalWorkerReadiness.unavailable('probe_failed');
    }
    return {
      'content': <Object?>[],
      'structuredContent': {
        'state': readiness.state,
        if (readiness.issueCode != null) 'issueCode': readiness.issueCode,
        'checks': [
          for (final check
              in readiness.checks.take(ExternalWorkerLimits.maxChecks))
            {
              'code': check.code,
              'ok': check.ok,
              // The profile requires a message; a bare check gets a plain one.
              'message': check.message ?? (check.ok ? 'passed' : 'failed'),
            },
        ],
        'capabilities': worker.capabilities,
      },
    };
  }

  Future<Map<String, Object?>> _models() async {
    final models = [
      for (final model in await worker.discoverModels()) model.toJson(),
    ];
    validateExternalWorkerModels(models);
    return {
      'content': <Object?>[],
      'structuredContent': {'models': models},
    };
  }

  Map<String, Object?> _failure(
    String code,
    String message, {
    bool retryable = false,
  }) =>
      {
        'isError': true,
        'content': <Object?>[],
        'structuredContent': {
          'issue': {
            'code': code,
            'message': message,
            if (retryable) 'retryable': true,
          },
        },
      };
}

/// The running `syntila.execute`: the [WorkContext] handed to the Worker.
class _Call implements WorkContext {
  _Call(this.id, this.token, this._runner);

  final Object id;
  final Object? token;
  final _McpRunner _runner;
  final _cancel = Completer<void>();
  final _clock = Stopwatch()..start();
  var _lastMs = -1000;
  num _lastProgress = 0;

  void cancel() {
    if (!_cancel.isCompleted) _cancel.complete();
  }

  @override
  bool get isCancelled => _cancel.isCompleted;

  @override
  Future<void> get cancelled => _cancel.future;

  @override
  String get dataDirectory =>
      Platform.environment['SYNTILA_PLUGIN_DATA_DIR'] ??
      Directory.systemTemp.path;

  @override
  void progress(String message, {int? percent}) {
    if (token == null || isCancelled) return;
    final now = _clock.elapsedMilliseconds;
    if (now - _lastMs < 50) return;
    _lastMs = now;
    // MCP requires progress to increase with every notification.
    final value = percent == null
        ? _lastProgress + 1
        : (percent.clamp(0, 100) > _lastProgress
            ? percent.clamp(0, 100)
            : _lastProgress + 0.001);
    _lastProgress = value;
    _runner._send(JsonRpcNotification('notifications/progress', {
      'progressToken': token,
      'progress': value,
      if (percent != null) 'total': 100,
      'message': message.length > 2000 ? message.substring(0, 2000) : message,
    }));
  }
}
