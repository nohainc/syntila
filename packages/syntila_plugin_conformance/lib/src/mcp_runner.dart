import 'dart:async';
import 'dart:convert';

import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';

import 'connection.dart';
import 'report.dart';

/// Runs the Syntila MCP Worker profile cases (MCP_WORKER_PROFILE_V1.md) against
/// a stdio MCP server. Like the NDJSON suite it shows protocol behaviour only.
class McpConformanceRunner {
  McpConformanceRunner({
    required this.launcher,
    this.caseTimeout = const Duration(seconds: 20),
  });

  final ConformanceLauncher launcher;
  final Duration caseTimeout;

  static const _probeStates = {
    'ready',
    'setup_required',
    'sign_in_required',
    'unavailable',
    'failed',
  };
  static const _sessionStates = {'created', 'resumed', 'unavailable'};

  Future<ConformanceReport> run(
      {void Function(ConformanceCase)? onCase}) async {
    final cases = <String, Future<void> Function(_McpWire)>{
      'mcp.version_negotiation': _versionNegotiation,
      'mcp.version_fallback': _versionFallback,
      'mcp.advertisement': _advertisement,
      'mcp.tools_present': _toolsPresent,
      'mcp.tool_definitions': _toolDefinitions,
      'mcp.ping': _ping,
      'mcp.probe_shape': _probeShape,
      'mcp.execute_result': _executeResult,
      'mcp.execute_single_terminal': _singleTerminal,
      'mcp.unknown_method_errors': _unknownMethod,
    };
    final results = <ConformanceCase>[];
    for (final entry in cases.entries) {
      final result = await _runCase(entry.key, entry.value);
      onCase?.call(result);
      results.add(result);
    }
    return ConformanceReport(protocol: 'mcp/syntila.worker.1', cases: results);
  }

  Future<ConformanceCase> _runCase(
    String id,
    Future<void> Function(_McpWire) body,
  ) async {
    final timer = Stopwatch()..start();
    PluginConnection? connection;
    ConformanceCase outcome(ConformanceStatus status, [String? detail]) =>
        ConformanceCase(
          id: id,
          status: status,
          milliseconds: timer.elapsedMilliseconds,
          detail: detail,
        );
    try {
      connection = await launcher.launch();
      await body(_McpWire(connection)).timeout(caseTimeout);
      return outcome(ConformanceStatus.passed);
    } on _Failure catch (failure) {
      return outcome(ConformanceStatus.failed, failure.message);
    } on TimeoutException {
      return outcome(
          ConformanceStatus.failed, 'The case did not finish in $caseTimeout.');
    } on PluginExited {
      return outcome(
          ConformanceStatus.failed, 'The server exited unexpectedly.');
    } on Object catch (error) {
      return outcome(ConformanceStatus.failed,
          'The server could not be exercised: ${error.runtimeType}');
    } finally {
      await connection?.kill();
    }
  }

  Future<void> _versionNegotiation(_McpWire w) async {
    final init = await w.initialize();
    final version = init['protocolVersion'];
    if (!McpLimits.supportedProtocolVersions.contains(version)) {
      throw _Failure('server selected an unsupported protocol version.');
    }
  }

  Future<void> _versionFallback(_McpWire w) async {
    final result = await w.request('initialize', {
      'protocolVersion': '1900-01-01',
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'syntila-conformance', 'version': '1'},
    });
    final version = result['protocolVersion'];
    if (version is! String ||
        version == '1900-01-01' ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(version)) {
      throw _Failure(
          'server did not select a valid fallback protocol version.');
    }
  }

  Future<void> _advertisement(_McpWire w) async {
    final init = await w.initialize();
    final meta = init['_meta'];
    if (meta is! Map || meta['syntila.worker'] != '1') {
      throw _Failure('initialize result lacks _meta["syntila.worker"] = "1".');
    }
  }

  Future<void> _toolsPresent(_McpWire w) async {
    await w.initialize();
    final result = await w.request('tools/list', {});
    final names = [
      for (final tool in (result['tools'] as List? ?? const []))
        if (tool is Map) tool['name'],
    ];
    for (final required in const ['syntila.execute', 'syntila.probe']) {
      if (!names.contains(required)) {
        throw _Failure('tools/list does not offer $required.');
      }
    }
  }

  Future<void> _toolDefinitions(_McpWire w) async {
    await w.initialize();
    final result = await w.request('tools/list', {});
    final tools = result['tools'];
    if (tools is! List || tools.length > McpLimits.maxTools) {
      throw _Failure('tools/list must return a bounded list of definitions.');
    }
    final names = <String>{};
    for (final tool in tools) {
      if (tool is! Map ||
          tool['name'] is! String ||
          (tool['name'] as String).isEmpty ||
          !names.add(tool['name'] as String)) {
        throw _Failure('tool names must be non-empty and unique.');
      }
      final input = tool['inputSchema'];
      if (input is! Map || input['type'] != 'object') {
        throw _Failure('tool inputSchema must be an object schema.');
      }
      final output = tool['outputSchema'];
      if (output != null && (output is! Map || output['type'] != 'object')) {
        throw _Failure(
            'tool outputSchema must be an object schema when present.');
      }
    }
  }

  Future<void> _ping(_McpWire w) async {
    await w.initialize();
    await w.request('ping', {});
  }

  Future<void> _probeShape(_McpWire w) async {
    await w.initialize();
    final result = await w.request('tools/call', {
      'name': 'syntila.probe',
      'arguments': {'mode': 'passive'},
    });
    final probe = result['structuredContent'];
    if (probe is! Map) throw _Failure('probe has no structuredContent.');
    if (!_probeStates.contains(probe['state'])) {
      throw _Failure('probe state "${probe['state']}" is not recognised.');
    }
    final checks = probe['checks'];
    if (checks == null) return;
    if (checks is! List || checks.length > 32) {
      throw _Failure('probe checks must be a list of at most 32.');
    }
    for (final check in checks) {
      final message = check is Map ? check['message'] : null;
      if (check is! Map ||
          check['code'] is! String ||
          check['ok'] is! bool ||
          message is! String ||
          message.isEmpty ||
          message.length > 1024) {
        throw _Failure('a probe check is malformed.');
      }
    }
  }

  Future<Map<String, Object?>> _execute(_McpWire w, String prompt) async {
    await w.initialize();
    return w.request('tools/call', {
      'name': 'syntila.execute',
      'arguments': {
        'protocol': 'syntila.worker/1',
        'prompt': prompt,
        'access': 'work',
        'deadline': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 1))
            .toIso8601String(),
      },
    });
  }

  Future<void> _executeResult(_McpWire w) async {
    final result = await _execute(w, 'conformance check');
    final out = result['structuredContent'];
    if (result['isError'] == true) {
      final issue = out is Map ? out['issue'] : null;
      if (issue is! Map || issue['code'] is! String) {
        throw _Failure('an error result carries no issue code.');
      }
      return;
    }
    if (out is! Map || out['text'] is! String) {
      throw _Failure('execute result has no structuredContent.text.');
    }
    if (utf8.encode(out['text'] as String).length >
        PluginProtocolLimits.maxOutputBytes) {
      throw _Failure('execute text exceeds the UTF-8 byte limit.');
    }
    final session = out['session'];
    if (session != null &&
        (session is! Map || !_sessionStates.contains(session['state']))) {
      throw _Failure('session must have a recognised state.');
    }
    final artifacts = out['artifacts'];
    if (artifacts != null) {
      if (artifacts is! List ||
          artifacts.length > PluginProtocolLimits.maxArtifacts) {
        throw _Failure('artifacts must be a bounded list of paths.');
      }
      for (final artifact in artifacts) {
        if (artifact is! String ||
            artifact.isEmpty ||
            artifact.length > PluginProtocolLimits.maxPathLength ||
            artifact.startsWith('/') ||
            RegExp(r'^[A-Za-z]:[\\/]').hasMatch(artifact) ||
            artifact.split(RegExp(r'[\\/]')).contains('..') ||
            artifact.contains('\u0000')) {
          throw _Failure('artifact is not a safe relative path.');
        }
      }
    }
  }

  Future<void> _singleTerminal(_McpWire w) async {
    await _execute(w, 'conformance check');
    final extra = await w.nextResponse(const Duration(milliseconds: 400));
    if (extra != null) {
      throw _Failure('a second completion arrived for one execute call.');
    }
  }

  Future<void> _unknownMethod(_McpWire w) async {
    await w.initialize();
    final error = await w.rawRequest('syntila/unknown', {});
    if (error['error'] is! Map) {
      throw _Failure('an unknown method did not return a JSON-RPC error.');
    }
  }
}

class _Failure implements Exception {
  _Failure(this.message);
  final String message;
}

/// Minimal JSON-RPC client over a [PluginConnection].
class _McpWire {
  _McpWire(this._connection);

  final PluginConnection _connection;
  int _next = 1;

  Future<Map<String, Object?>> initialize() async {
    final result = await request('initialize', {
      'protocolVersion': McpLimits.supportedProtocolVersions.first,
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'syntila-conformance', 'version': '1'},
    });
    await _connection.send(
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
    return result;
  }

  Future<Map<String, Object?>> rawRequest(
    String method,
    Map<String, Object?> params,
  ) async {
    final id = _next++;
    await _connection.send(jsonEncode(
        {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    while (true) {
      final line = await _connection.readLine(const Duration(seconds: 8));
      if (line == null) throw _Failure('$method did not answer in time.');
      final message = _decode(line);
      if (message['id'] == id) return message;
    }
  }

  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> params,
  ) async {
    final message = await rawRequest(method, params);
    final result = message['result'];
    if (result is! Map) {
      throw _Failure('$method returned an error: ${message['error']}');
    }
    return Map<String, Object?>.from(result);
  }

  /// The next response (a message with an id), or null if none arrives.
  Future<Map<String, Object?>?> nextResponse(Duration wait) async {
    final deadline = DateTime.now().add(wait);
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return null;
      final line = await _connection.readLine(remaining);
      if (line == null) return null;
      final message = _decode(line);
      if (message.containsKey('id')) return message;
    }
  }

  Map<String, Object?> _decode(String line) {
    try {
      final value = jsonDecode(line);
      if (value is Map) return Map<String, Object?>.from(value);
    } on FormatException {
      // Falls through to the failure below.
    }
    throw _Failure('the server wrote a line that is not a JSON-RPC message.');
  }
}
