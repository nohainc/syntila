import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';

/// MCP Streamable HTTP client transport (`MCP_HOST_V1.md`, section 1): every
/// JSON-RPC message is a POST to one endpoint, and the reply is a JSON body, an
/// SSE stream, or `202 Accepted` for notifications. Replies are fed back through
/// [lines] so [McpClient] is unaware of the transport.
///
/// Safety rules enforced here: https only (plain http is accepted for a
/// loopback host when [allowInsecureLoopback] is set, for tests and local
/// development), TLS certificates are validated by `dart:io`, every body is size
/// bounded, and credentials come from [headers] and are never logged or placed
/// in an error message. A 401 becomes the `authRequired` failure so callers can
/// prompt for credentials.
///
/// Not supported yet: the optional server-to-client GET stream, so a server can
/// only talk to the client inside replies to its POSTs. Callers must therefore
/// re-list tools themselves to notice definition changes (see
/// `McpServerSpec.relistBeforeCall`).
class StreamableHttpTransport implements McpTransport {
  StreamableHttpTransport({
    required this.endpoint,
    Map<String, String> headers = const {},
    bool allowInsecureLoopback = false,
    this.maxMessageBytes = McpLimits.maxFrameBytes,
    this.requestTimeout = const Duration(minutes: 10),
  }) : _headers = Map.unmodifiable(headers) {
    final loopback = const {
      '127.0.0.1',
      'localhost',
      '::1',
      '[::1]',
    }.contains(endpoint.host);
    final secure = endpoint.scheme == 'https';
    final plainOk =
        endpoint.scheme == 'http' && allowInsecureLoopback && loopback;
    if (!secure && !plainOk) {
      throw McpException(
        McpFailure.protocolViolation,
        'Remote MCP servers require https.',
      );
    }
    if (endpoint.userInfo.isNotEmpty) {
      throw McpException(
        McpFailure.protocolViolation,
        'The MCP endpoint must not contain credentials.',
      );
    }
  }

  final Uri endpoint;
  final int maxMessageBytes;
  final Duration requestTimeout;
  final Map<String, String> _headers;
  final _controller = StreamController<String>();
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final _inFlight = <Object, HttpClientRequest>{};
  String? _sessionId;
  String? _protocolVersion;
  var _closed = false;

  /// Test and diagnostics hook: the session the server assigned, if any.
  String? get sessionId => _sessionId;

  @override
  Stream<String> get lines => _controller.stream;

  @override
  void send(String line) {
    if (_closed) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final id = decoded['id'];
    final isRequest = decoded.containsKey('method') && id != null;
    if (decoded['method'] == 'notifications/cancelled') {
      // Stop waiting for the cancelled call's reply, as the spec allows.
      final target = (decoded['params'] as Map?)?['requestId'];
      _inFlight.remove(target)?.abort();
    }
    unawaited(_post(line, isRequest ? id : null));
  }

  Future<void> _post(String body, Object? requestId) async {
    try {
      final request = await _client.postUrl(endpoint).timeout(requestTimeout);
      if (requestId != null) _inFlight[requestId] = request;
      request.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
      for (final entry in _headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      final session = _sessionId;
      if (session != null) request.headers.set('Mcp-Session-Id', session);
      final version = _protocolVersion;
      if (version != null) request.headers.set('MCP-Protocol-Version', version);
      final bytes = utf8.encode(body);
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(requestTimeout);
      _sessionId = response.headers.value('Mcp-Session-Id') ?? _sessionId;
      await _handle(response, requestId);
    } on TimeoutException {
      _fail(requestId, -32000, 'The MCP server did not answer in time.');
    } on HttpException {
      // Includes a request we aborted ourselves after a cancel.
      if (requestId != null && !_closed && _inFlight.containsKey(requestId)) {
        _fail(requestId, -32000, 'The connection to the MCP server failed.');
      }
    } on SocketException {
      _fail(requestId, -32000, 'The MCP server is not reachable.');
    } on HandshakeException {
      _fail(requestId, -32000, 'The MCP server certificate was rejected.');
    } finally {
      if (requestId != null) _inFlight.remove(requestId);
    }
  }

  Future<void> _handle(HttpClientResponse response, Object? requestId) async {
    final status = response.statusCode;
    if (status == 202) {
      await response.drain<void>();
      return;
    }
    if (status == 401) {
      await response.drain<void>();
      _fail(requestId, -32001, 'The MCP server requires authentication.');
      return;
    }
    if (status == 403) {
      await response.drain<void>();
      _fail(requestId, -32002, 'The MCP server refused the request.');
      return;
    }
    if (status == 404 && _sessionId != null) {
      await response.drain<void>();
      _sessionId = null;
      _fail(requestId, -32003, 'The MCP session expired.');
      return;
    }
    if (status < 200 || status >= 300) {
      await response.drain<void>();
      _fail(requestId, -32000, 'The MCP server answered HTTP $status.');
      return;
    }
    final type = response.headers.contentType?.mimeType;
    if (type == 'text/event-stream') {
      await _readEvents(response, requestId);
    } else if (type == 'application/json') {
      final body = await _readBounded(response);
      if (body == null) {
        _fail(requestId, -32000, 'The MCP reply is too large.');
      } else {
        _emit(body);
      }
    } else {
      await response.drain<void>();
      _fail(requestId, -32000, 'The MCP server sent an unsupported reply.');
    }
  }

  Future<String?> _readBounded(HttpClientResponse response) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
      if (bytes.length > maxMessageBytes) {
        // Returning cancels the subscription, which discards the connection.
        return null;
      }
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  /// Parses a server-sent-events body; each `data` payload is one message.
  Future<void> _readEvents(
    HttpClientResponse response,
    Object? requestId,
  ) async {
    final data = StringBuffer();
    var total = 0;
    void dispatch() {
      if (data.isEmpty) return;
      final message = data.toString();
      data.clear();
      _emit(message);
    }

    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      total += line.length + 1;
      if (total > maxMessageBytes * 8) {
        _fail(requestId, -32000, 'The MCP event stream is too large.');
        return;
      }
      if (line.isEmpty) {
        dispatch();
      } else if (line.startsWith(':')) {
        continue;
      } else if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.write('\n');
        final value = line.substring(5);
        data.write(value.startsWith(' ') ? value.substring(1) : value);
        if (data.length > maxMessageBytes) {
          _fail(requestId, -32000, 'The MCP reply is too large.');
          return;
        }
      }
      // `event:`, `id:` and `retry:` are not needed for request replies.
    }
    dispatch();
  }

  void _emit(String message) {
    if (_closed || _controller.isClosed) return;
    // Remember the negotiated version for the headers of later requests.
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map && decoded['result'] is Map) {
        final result = decoded['result'] as Map;
        if (result['serverInfo'] != null &&
            result['protocolVersion'] is String) {
          _protocolVersion = result['protocolVersion'] as String;
        }
      }
    } on FormatException {
      // Pass it on; the client reports the malformed frame.
    }
    _controller.add(message);
  }

  /// Turns a transport failure into a JSON-RPC error for the waiting request,
  /// so a call fails promptly instead of waiting for its timeout.
  void _fail(Object? requestId, int code, String message) {
    if (requestId == null || _closed || _controller.isClosed) return;
    _controller.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': requestId,
        'error': {'code': code, 'message': message},
      }),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final request in _inFlight.values.toList()) {
      request.abort();
    }
    _inFlight.clear();
    final session = _sessionId;
    if (session != null) {
      try {
        final request = await _client
            .deleteUrl(endpoint)
            .timeout(const Duration(seconds: 3));
        for (final entry in _headers.entries) {
          request.headers.set(entry.key, entry.value);
        }
        request.headers.set('Mcp-Session-Id', session);
        final response = await request.close().timeout(
          const Duration(seconds: 3),
        );
        await response.drain<void>();
      } on Object {
        // Best effort: the server expires idle sessions anyway.
      }
    }
    _client.close(force: true);
    await _controller.close();
  }
}
