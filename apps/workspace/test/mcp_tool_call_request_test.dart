import 'package:syntila_workspace/mcp_tool_call_request.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> request() => {
        'schemaVersion': 1,
        'taskId': 'task-one',
        'dispatchKey': 'mcp-tool-v1:task-one',
        'serverId': 'echo',
        'tool': 'echo',
        'toolDefinitionHash': 'a' * 64,
        'arguments': {'text': 'hello'},
        'timeoutMs': 30000,
      };

  test('accepts a frozen request and copies arguments', () {
    final input = request();
    final result = McpToolCallRequest.fromJson(input);
    (input['arguments'] as Map)['text'] = 'changed';
    expect(result.arguments['text'], 'hello');
    expect(() => result.arguments['text'] = 'mutated', throwsUnsupportedError);
  });

  test('rejects mismatched keys, invalid identities and extra fields', () {
    for (final input in [
      request()..['dispatchKey'] = 'mcp-tool-v1:other',
      request()..['serverId'] = '../outside',
      request()..['toolDefinitionHash'] = 'A' * 64,
      request()..['timeoutMs'] = 0,
      request()..['extra'] = true,
    ]) {
      expect(() => McpToolCallRequest.fromJson(input), throwsFormatException);
    }
  });

  test('limits UTF-8 bytes, not characters', () {
    final input = request()..['arguments'] = {'text': 'é' * 33000};
    expect(() => McpToolCallRequest.fromJson(input), throwsFormatException);
  });
}
