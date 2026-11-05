import 'dart:convert';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

ExecuteRequest request(List<McpServerLaunch> servers) => ExecuteRequest(
      requestId: 'r1',
      assignmentId: 'a1',
      prompt: 'hi',
      timeoutMs: 1000,
      sessionPolicy: WorkerSessionPolicy.stateless,
      mcpServers: servers,
    );

void main() {
  test('round-trips MCP servers and omits the field when empty', () {
    final frame = request([
      McpServerLaunch(
        name: 'files',
        command: '/usr/bin/files',
        arguments: ['--root', '/tmp'],
        environment: {'TOKEN': 'x'},
      ),
    ]);
    final decoded = decodeWorkerFrame(frame.encode()) as ExecuteRequest;
    expect(decoded.mcpServers.single.name, 'files');
    expect(decoded.mcpServers.single.arguments, ['--root', '/tmp']);
    expect(decoded.mcpServers.single.environment, {'TOKEN': 'x'});
    expect(
        jsonDecode(request(const []).encode()), isNot(contains('mcpServers')));
  });

  test('rejects invalid servers', () {
    final bad = <McpServerLaunch Function()>[
      () => McpServerLaunch(name: 'Bad Name', command: '/bin/x'),
      () => McpServerLaunch(name: 'ok', command: 'relative/x'),
      () => McpServerLaunch(
            name: 'ok',
            command: '/bin/x',
            environment: {'SYNTILA_SECRET': 'x'},
          ),
      () => McpServerLaunch(
            name: 'ok',
            command: '/bin/x',
            environment: {'1BAD': 'x'},
          ),
      () => McpServerLaunch(
            name: 'ok',
            command: '/bin/x',
            arguments: List.filled(33, 'a'),
          ),
    ];
    for (final make in bad) {
      expect(make, throwsFormatException);
    }
  });

  test('rejects duplicate names and too many servers', () {
    McpServerLaunch s(String n) => McpServerLaunch(name: n, command: '/bin/x');
    expect(() => request([s('a'), s('a')]), throwsFormatException);
    expect(
      () => request([for (var i = 0; i < 9; i++) s('s$i')]),
      throwsFormatException,
    );
  });

  test('rejects malformed wire shapes', () {
    final json = jsonDecode(request(const []).encode()) as Map<String, Object?>;
    for (final value in <Object?>[
      'x',
      [1],
      [
        {'name': 'a', 'command': '/bin/x', 'extra': 1},
      ],
    ]) {
      expect(
        () => decodeWorkerFrame(jsonEncode({...json, 'mcpServers': value})),
        throwsFormatException,
      );
    }
  });
}
