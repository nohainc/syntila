import 'dart:convert';

import 'limits.dart';

/// JSON-RPC 2.0 error codes used by the client.
abstract final class JsonRpcCodes {
  static const parseError = -32700;
  static const invalidRequest = -32600;
  static const methodNotFound = -32601;
  static const invalidParams = -32602;
}

sealed class JsonRpcMessage {
  const JsonRpcMessage();
}

final class JsonRpcRequest extends JsonRpcMessage {
  const JsonRpcRequest(this.id, this.method, [this.params]);
  final Object id; // int or String
  final String method;
  final Map<String, Object?>? params;
}

final class JsonRpcNotification extends JsonRpcMessage {
  const JsonRpcNotification(this.method, [this.params]);
  final String method;
  final Map<String, Object?>? params;
}

final class JsonRpcResponse extends JsonRpcMessage {
  const JsonRpcResponse(this.id, this.result);
  final Object id;
  final Object? result;
}

final class JsonRpcError extends JsonRpcMessage {
  const JsonRpcError(this.id, this.code, this.message, [this.data]);
  final Object? id; // null for parse errors
  final int code;
  final String message;
  final Object? data;
}

String encodeMessage(JsonRpcMessage m) {
  final Map<String, Object?> j = switch (m) {
    JsonRpcRequest() => {
        'jsonrpc': '2.0',
        'id': m.id,
        'method': m.method,
        if (m.params != null) 'params': m.params,
      },
    JsonRpcNotification() => {
        'jsonrpc': '2.0',
        'method': m.method,
        if (m.params != null) 'params': m.params,
      },
    JsonRpcResponse() => {'jsonrpc': '2.0', 'id': m.id, 'result': m.result},
    JsonRpcError() => {
        'jsonrpc': '2.0',
        'id': m.id,
        'error': {
          'code': m.code,
          'message': m.message,
          if (m.data != null) 'data': m.data,
        },
      },
  };
  final line = jsonEncode(j);
  if (utf8.encode(line).length > McpLimits.maxFrameBytes) {
    throw McpException(
        McpFailure.protocolViolation, 'outbound frame too large');
  }
  return line;
}

/// Decodes one newline-delimited frame. Throws [McpException] on oversize or
/// malformed frames. Batches are not supported (removed in later MCP revisions).
JsonRpcMessage decodeMessage(String line) {
  if (utf8.encode(line).length > McpLimits.maxFrameBytes) {
    throw McpException(McpFailure.protocolViolation, 'frame too large');
  }
  final Object? raw;
  try {
    raw = jsonDecode(line);
  } on FormatException {
    throw McpException(McpFailure.protocolViolation, 'invalid JSON frame',
        jsonRpcCode: JsonRpcCodes.parseError);
  }
  if (raw is! Map<String, Object?> || raw['jsonrpc'] != '2.0') {
    throw McpException(
        McpFailure.protocolViolation, 'not a JSON-RPC 2.0 object',
        jsonRpcCode: JsonRpcCodes.invalidRequest);
  }
  final id = raw['id'];
  final method = raw['method'];
  if (id != null && id is! int && id is! String) {
    throw McpException(McpFailure.protocolViolation, 'invalid id type');
  }
  if (method is String) {
    final params = raw['params'];
    if (params != null && params is! Map<String, Object?>) {
      throw McpException(
          McpFailure.protocolViolation, 'params must be an object');
    }
    final p = params as Map<String, Object?>?;
    return id == null
        ? JsonRpcNotification(method, p)
        : JsonRpcRequest(id, method, p);
  }
  if (raw.containsKey('error')) {
    final e = raw['error'];
    if (e is! Map<String, Object?> || e['code'] is! int) {
      throw McpException(
          McpFailure.protocolViolation, 'malformed error object');
    }
    return JsonRpcError(
        id, e['code'] as int, '${e['message'] ?? ''}', e['data']);
  }
  if (raw.containsKey('result') && id != null) {
    return JsonRpcResponse(id, raw['result']);
  }
  throw McpException(McpFailure.protocolViolation, 'unclassifiable message');
}
