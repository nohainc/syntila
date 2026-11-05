import 'dart:async';
import 'dart:convert';

import 'jsonrpc.dart';
import 'limits.dart';

/// Newline-delimited JSON-RPC transport (stdio today; HTTP adapts to this).
abstract interface class McpTransport {
  Stream<String> get lines;
  void send(String line);
  Future<void> close();
}

typedef McpProgressCallback = void Function(
    num progress, num? total, String? message);

class McpCall {
  McpCall._(this.result, this._cancel);

  /// Completes with the JSON-RPC `result`, or fails with [McpException].
  final Future<Map<String, Object?>> result;
  final void Function(String reason) _cancel;

  /// Sends `notifications/cancelled`; [result] then fails with `mcp_timeout`
  /// only if the server never answers - a late answer still completes it.
  void cancel([String reason = 'cancelled by host']) => _cancel(reason);
}

/// MCP client per `MCP_HOST_V1.md`. Advertises no client capabilities
/// (sampling, roots and elicitation are refused with method-not-found).
class McpClient {
  McpClient(this._transport,
      {this.clientName = 'syntila', this.clientVersion = '0'}) {
    _sub = _transport.lines.listen(_onLine, onDone: _onClosed);
  }

  final McpTransport _transport;
  final String clientName;
  final String clientVersion;
  late final StreamSubscription<String> _sub;

  final _pending = <Object, Completer<Object?>>{};
  final _progress = <String, McpProgressCallback>{};
  var _nextId = 1;
  var _closed = false;

  bool get isClosed => _closed;

  String? negotiatedVersion;
  Map<String, Object?> serverCapabilities = const {};
  Map<String, Object?> serverInfo = const {};
  Map<String, Object?> initializeMeta = const {};

  /// Set when the server sent `notifications/tools/list_changed`.
  bool toolsListChanged = false;
  final unsupportedRequests = <String>[];

  Future<void> initialize({Duration? timeout}) async {
    final res = await _request(
      'initialize',
      {
        'protocolVersion': McpLimits.supportedProtocolVersions.first,
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': clientName, 'version': clientVersion},
      },
      timeout ?? McpLimits.initializeTimeout,
    );
    final version = res['protocolVersion'];
    if (version is! String ||
        !McpLimits.supportedProtocolVersions.contains(version)) {
      await close();
      throw McpException(McpFailure.versionUnsupported,
          'server selected unsupported protocol version: $version');
    }
    negotiatedVersion = version;
    serverCapabilities =
        (res['capabilities'] as Map?)?.cast<String, Object?>() ?? const {};
    serverInfo =
        (res['serverInfo'] as Map?)?.cast<String, Object?>() ?? const {};
    initializeMeta =
        (res['_meta'] as Map?)?.cast<String, Object?>() ?? const {};
    _send(const JsonRpcNotification('notifications/initialized'));
  }

  Future<List<Map<String, Object?>>> listTools({Duration? timeout}) async {
    final tools = <Map<String, Object?>>[];
    String? cursor;
    do {
      final res = await _request(
        'tools/list',
        {if (cursor != null) 'cursor': cursor},
        timeout ?? McpLimits.maxCallTimeout,
      );
      for (final t in (res['tools'] as List? ?? const [])) {
        tools.add((t as Map).cast<String, Object?>());
        if (tools.length > McpLimits.maxTools) {
          throw McpException(McpFailure.protocolViolation,
              'server exposes more than ${McpLimits.maxTools} tools');
        }
      }
      cursor = res['nextCursor'] as String?;
    } while (cursor != null);
    toolsListChanged = false;
    return tools;
  }

  McpCall callTool(
    String name,
    Map<String, Object?> arguments, {
    McpProgressCallback? onProgress,
    Duration? timeout,
  }) {
    final id = _nextId++;
    final token = 'p$id';
    if (onProgress != null) _progress[token] = onProgress;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _send(JsonRpcRequest(id, 'tools/call', {
      'name': name,
      'arguments': arguments,
      if (onProgress != null) '_meta': {'progressToken': token},
    }));
    final limit = timeout ?? McpLimits.maxCallTimeout;
    final timer = Timer(limit, () {
      if (_pending.remove(id) != null) {
        _notifyCancelled(id, 'timeout');
        completer.completeError(
            McpException(McpFailure.timeout, 'tools/call $name timed out'));
      }
    });
    final future = completer.future.whenComplete(() {
      timer.cancel();
      _progress.remove(token);
    }).then((v) => _checkResult(v));
    return McpCall._(future, (reason) {
      if (_pending.containsKey(id)) _notifyCancelled(id, reason);
    });
  }

  Future<void> ping({Duration timeout = const Duration(seconds: 5)}) async {
    await _request('ping', null, timeout);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failAll(McpException(McpFailure.serverCrashed, 'connection closed'));
    await _sub.cancel();
    await _transport.close();
  }

  // -- internals -----------------------------------------------------------

  Map<String, Object?> _checkResult(Object? v) {
    final map = (v as Map?)?.cast<String, Object?>() ?? <String, Object?>{};
    if (utf8.encode(jsonEncode(map)).length > McpLimits.maxResultBytes) {
      throw McpException(McpFailure.resultTooLarge,
          'tool result exceeds ${McpLimits.maxResultBytes} bytes');
    }
    return map;
  }

  Future<Map<String, Object?>> _request(
      String method, Map<String, Object?>? params, Duration timeout) async {
    final id = _nextId++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send(JsonRpcRequest(id, method, params));
    try {
      final v = await c.future.timeout(timeout, onTimeout: () {
        _pending.remove(id);
        throw McpException(McpFailure.timeout, '$method timed out');
      });
      return (v as Map?)?.cast<String, Object?>() ?? <String, Object?>{};
    } finally {
      _pending.remove(id);
    }
  }

  void _notifyCancelled(int id, String reason) => _send(JsonRpcNotification(
      'notifications/cancelled', {'requestId': id, 'reason': reason}));

  void _send(JsonRpcMessage m) {
    if (_closed) {
      throw McpException(McpFailure.serverCrashed, 'connection closed');
    }
    _transport.send(encodeMessage(m));
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final JsonRpcMessage m;
    try {
      m = decodeMessage(line);
    } on McpException catch (e) {
      _failAll(e);
      close();
      return;
    }
    switch (m) {
      case JsonRpcResponse():
        _pending.remove(m.id)?.complete(m.result);
      case JsonRpcError():
        final c = m.id == null ? null : _pending.remove(m.id);
        c?.completeError(McpException(
            m.code == -32001
                ? McpFailure.authRequired
                : McpFailure.protocolViolation,
            m.message,
            jsonRpcCode: m.code));
      case JsonRpcNotification():
        _onNotification(m);
      case JsonRpcRequest():
        if (m.method == 'ping') {
          _send(JsonRpcResponse(m.id, <String, Object?>{}));
        } else {
          unsupportedRequests.add(m.method);
          _send(JsonRpcError(m.id, JsonRpcCodes.methodNotFound,
              'client does not support ${m.method}'));
        }
    }
  }

  void _onNotification(JsonRpcNotification n) {
    final p = n.params ?? const <String, Object?>{};
    switch (n.method) {
      case 'notifications/progress':
        final cb = _progress['${p['progressToken']}'];
        final prog = p['progress'];
        if (cb != null && prog is num) {
          cb(prog, p['total'] as num?, p['message'] as String?);
        }
      case 'notifications/tools/list_changed':
        toolsListChanged = true;
    }
  }

  void _onClosed() {
    if (_closed) return;
    _closed = true;
    _failAll(
        McpException(McpFailure.serverCrashed, 'server closed the stream'));
  }

  void _failAll(McpException e) {
    final all = _pending.values.toList();
    _pending.clear();
    for (final c in all) {
      if (!c.isCompleted) c.completeError(e);
    }
  }
}
