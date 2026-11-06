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

/// Marker for transports that route by HTTP headers (`Mcp-Method`, `Mcp-Name`,
/// `Mcp-Param-*`). Used to refuse features that need headers we cannot build.
abstract interface class McpHeaderRoutedTransport {}

/// Which protocol family [McpClient.connect] may use.
enum McpProtocolMode {
  /// Try stateless `server/discover`; fall back to `initialize` only when the
  /// server shows it is not a modern server (see [McpClient.connect]).
  auto,

  /// Stateless revisions only; a non-modern server fails.
  modern,

  /// `initialize` handshake only (the pre-2026 behavior).
  legacy,
}

const _metaVersion = 'io.modelcontextprotocol/protocolVersion';
const _metaCapabilities = 'io.modelcontextprotocol/clientCapabilities';
const _metaClientInfo = 'io.modelcontextprotocol/clientInfo';
const _metaServerInfo = 'io.modelcontextprotocol/serverInfo';

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
/// (sampling, roots, elicitation, extensions and subscriptions are not offered;
/// server requests for them are refused with method-not-found).
///
/// Two protocol families: legacy (`initialize` handshake, 2025-06-18 and older)
/// and modern/stateless (2026-07-28: every request carries its version,
/// capabilities and client identity in `_meta`; no handshake, no session).
/// [connect] chooses; [initialize] is the legacy handshake alone.
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

  /// True after a stateless (2026-07-28 or later) negotiation.
  bool get isModern =>
      negotiatedVersion != null &&
      McpLimits.modernProtocolVersions.contains(negotiatedVersion);

  final _toolSchemas = <String, Object?>{};
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
        'protocolVersion': McpLimits.legacyProtocolVersions.first,
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': clientName, 'version': clientVersion},
      },
      timeout ?? McpLimits.initializeTimeout,
    );
    final version = res['protocolVersion'];
    if (version is! String ||
        !McpLimits.legacyProtocolVersions.contains(version)) {
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

  /// Establishes the connection in the requested [mode].
  ///
  /// `auto` sends `server/discover`. A discover result negotiates the newest
  /// mutually supported modern version. Only these mean "not a modern server"
  /// and fall back to `initialize`: JSON-RPC method-not-found / invalid-request,
  /// no answer within [McpLimits.discoverTimeout], an empty success that claims
  /// neither a `resultType` nor `supportedVersions`, or a discover result that
  /// lists only legacy versions we support. A recognized modern error
  /// (unsupported version, header mismatch, missing capability, invalid params)
  /// never falls back: it fails with a stable diagnostic.
  Future<void> connect({
    McpProtocolMode mode = McpProtocolMode.auto,
    Duration? timeout,
  }) async {
    if (mode == McpProtocolMode.legacy) return initialize(timeout: timeout);
    final proposed = McpLimits.modernProtocolVersions.first;
    Map<String, Object?> result;
    try {
      result = await _request(
        'server/discover',
        {'_meta': _modernMeta(proposed)},
        timeout ?? McpLimits.discoverTimeout,
      );
    } on McpException catch (e) {
      final silentOrLegacy = e.code == McpFailure.timeout ||
          e.jsonRpcCode == JsonRpcCodes.methodNotFound ||
          e.jsonRpcCode == JsonRpcCodes.invalidRequest;
      if (mode == McpProtocolMode.auto && silentOrLegacy) {
        return initialize(timeout: timeout);
      }
      await close();
      if (e.jsonRpcCode == JsonRpcCodes.unsupportedProtocolVersion ||
          silentOrLegacy) {
        throw McpException(McpFailure.versionUnsupported, e.message,
            jsonRpcCode: e.jsonRpcCode);
      }
      rethrow;
    }
    final type = result['resultType'];
    final listed = result['supportedVersions'];
    if (listed == null && type == null && mode == McpProtocolMode.auto) {
      // An empty success is how some handshake servers answer any method; it
      // does not claim to be a stateless reply, so use the handshake.
      return initialize(timeout: timeout);
    }
    if (type != null && type != 'complete') {
      await close();
      throw McpException(McpFailure.protocolViolation,
          'server/discover returned an unsupported resultType');
    }
    if (listed is! List || listed.any((v) => v is! String)) {
      await close();
      throw McpException(McpFailure.protocolViolation,
          'server/discover result has no supportedVersions list');
    }
    final versions = listed.cast<String>();
    final common =
        McpLimits.modernProtocolVersions.where(versions.contains).toList();
    if (common.isEmpty) {
      final legacyOnly = mode == McpProtocolMode.auto &&
          McpLimits.legacyProtocolVersions.any(versions.contains);
      if (legacyOnly) return initialize(timeout: timeout);
      await close();
      throw McpException(McpFailure.versionUnsupported,
          'server supports no compatible protocol version: $versions');
    }
    negotiatedVersion = common.first;
    serverCapabilities =
        (result['capabilities'] as Map?)?.cast<String, Object?>() ?? const {};
    initializeMeta =
        (result['_meta'] as Map?)?.cast<String, Object?>() ?? const {};
    serverInfo =
        (initializeMeta[_metaServerInfo] as Map?)?.cast<String, Object?>() ??
            const {};
  }

  Map<String, Object?> _modernMeta(String version) => {
        _metaVersion: version,
        _metaCapabilities: <String, Object?>{},
        _metaClientInfo: {'name': clientName, 'version': clientVersion},
      };

  /// Adds the per-request metadata a stateless server requires.
  Map<String, Object?>? _withMeta(Map<String, Object?>? params,
      [Map<String, Object?> extra = const {}]) {
    if (!isModern) {
      if (extra.isEmpty) return params;
      return {...?params, '_meta': extra};
    }
    return {
      ...?params,
      '_meta': {..._modernMeta(negotiatedVersion!), ...extra},
    };
  }

  Future<List<Map<String, Object?>>> listTools({Duration? timeout}) async {
    final tools = <Map<String, Object?>>[];
    String? cursor;
    do {
      final res = await _request(
        'tools/list',
        _withMeta({if (cursor != null) 'cursor': cursor}),
        timeout ?? McpLimits.maxCallTimeout,
      );
      _checkResultType(res, 'tools/list');
      for (final t in (res['tools'] as List? ?? const [])) {
        tools.add((t as Map).cast<String, Object?>());
        _toolSchemas['${tools.last['name']}'] = tools.last['inputSchema'];
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
    if (isModern &&
        _transport is McpHeaderRoutedTransport &&
        _containsKey(_toolSchemas[name], 'x-mcp-header')) {
      // Mcp-Param-* routing headers are not built; a server would reject the
      // call, so refuse it with a stable diagnostic instead of guessing.
      throw McpException(McpFailure.unsupportedFeature,
          'tool $name uses x-mcp-header parameters, which are not supported');
    }
    final id = _nextId++;
    final token = 'p$id';
    if (onProgress != null) _progress[token] = onProgress;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _send(JsonRpcRequest(
        id,
        'tools/call',
        _withMeta({
          'name': name,
          'arguments': arguments,
        }, {
          if (onProgress != null) 'progressToken': token,
        })));
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

  /// Legacy liveness check. `ping` was removed from stateless revisions, so
  /// there it does nothing; the next request reveals a dead connection.
  Future<void> ping({Duration timeout = const Duration(seconds: 5)}) async {
    if (isModern) return;
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

  static bool _containsKey(Object? node, String key) {
    if (node is Map) {
      return node.containsKey(key) ||
          node.values.any((v) => _containsKey(v, key));
    }
    if (node is List) return node.any((v) => _containsKey(v, key));
    return false;
  }

  /// Stateless results carry `resultType`. Absent means complete (legacy);
  /// `input_required` needs client input we never offer; anything else is
  /// invalid for a client that advertises no extensions.
  void _checkResultType(Map<String, Object?> result, String method) {
    final type = result['resultType'];
    if (type == null || type == 'complete') return;
    if (type == 'input_required') {
      throw McpException(McpFailure.interactionRequired,
          '$method needs interactive input, which Syntila does not provide');
    }
    throw McpException(McpFailure.protocolViolation,
        '$method returned unsupported resultType');
  }

  Map<String, Object?> _checkResult(Object? v) {
    var map = (v as Map?)?.cast<String, Object?>() ?? <String, Object?>{};
    _checkResultType(map, 'tools/call');
    if (map.containsKey('resultType')) {
      map = Map.of(map)..remove('resultType');
    }
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
                : m.code == JsonRpcCodes.unsupportedProtocolVersion
                    ? McpFailure.versionUnsupported
                    : McpFailure.protocolViolation,
            m.code == JsonRpcCodes.unsupportedProtocolVersion
                ? 'server does not support the requested protocol version'
                    '${_supportedFrom(m.data)}'
                : m.message,
            jsonRpcCode: m.code));
      case JsonRpcNotification():
        _onNotification(m);
      case JsonRpcRequest():
        if (m.method == 'ping' && !isModern) {
          _send(JsonRpcResponse(m.id, <String, Object?>{}));
        } else {
          unsupportedRequests.add(m.method);
          _send(JsonRpcError(m.id, JsonRpcCodes.methodNotFound,
              'client does not support ${m.method}'));
        }
    }
  }

  static String _supportedFrom(Object? data) {
    final supported = data is Map ? data['supported'] : null;
    if (supported is! List) return '';
    final safe = supported
        .whereType<String>()
        .where((v) => RegExp(r'^[0-9A-Za-z._-]{1,32}$').hasMatch(v))
        .take(8);
    return safe.isEmpty ? '' : ' (supports: ${safe.join(', ')})';
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
