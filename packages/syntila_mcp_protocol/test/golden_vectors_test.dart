import 'dart:io';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:test/test.dart';

const _vectorDirectory = '../../docs/specifications/mcp-vectors';

String replay(String name) {
  final file = File('$_vectorDirectory/$name.transcript');
  if (!file.existsSync()) throw StateError('Vector not found: $name');
  final lines =
      file.readAsLinesSync().where((line) => line.trim().isNotEmpty);

  final pendingRequests = <Object>{};
  final completedRequests = <Object>{};

  for (final line in lines) {
    final payload = line.substring(2);
    if (line.startsWith('→')) {
      final JsonRpcMessage frame;
      try {
        frame = decodeMessage(payload);
      } on McpException {
        return McpFailure.protocolViolation;
      }
      if (frame is JsonRpcRequest) {
        pendingRequests.add(frame.id);
      }
    } else if (line.startsWith('←')) {
      final JsonRpcMessage frame;
      try {
        frame = decodeMessage(payload);
      } on McpException {
        return McpFailure.protocolViolation;
      }
      if (frame is JsonRpcResponse) {
        if (!pendingRequests.contains(frame.id) ||
            completedRequests.contains(frame.id)) {
          return McpFailure.protocolViolation;
        }
        completedRequests.add(frame.id);
      } else if (frame is JsonRpcError) {
        if (frame.code == JsonRpcCodes.methodNotFound) {
          return 'method_not_found';
        }
        if (frame.message.toLowerCase().contains('cancel')) {
          return 'cancelled';
        }
        return 'error';
      }
    }
  }
  return 'ok';
}

void main() {
  test('valid-handshake-tools is accepted', () {
    expect(replay('valid-handshake-tools'), 'ok');
  });

  test('valid-call-progress is accepted', () {
    expect(replay('valid-call-progress'), 'ok');
  });

  test('valid-cancelled is handled as cancelled', () {
    expect(replay('valid-cancelled'), 'cancelled');
  });

  test('invalid-two-results is reported as protocol violation', () {
    expect(replay('invalid-two-results'), McpFailure.protocolViolation);
  });

  test('invalid-unknown-method is reported as method_not_found', () {
    expect(replay('invalid-unknown-method'), 'method_not_found');
  });

  test('invalid-stdout-noise is reported as protocol violation', () {
    expect(replay('invalid-stdout-noise'), McpFailure.protocolViolation);
  });
}
