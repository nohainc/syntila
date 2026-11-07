import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart'
    show McpServerLaunch;
import 'package:syntila_workspace/mcp_registry.dart';
import 'package:syntila_workspace/mcp_service.dart';
import 'package:syntila_workspace/mcp_tool_call_fence.dart';
import 'package:syntila_workspace/workspace_manager_ipc.dart';
import 'package:syntila_workspace/workspace_manager_mcp.dart';
import 'package:test/test.dart';

class FakeProbe implements McpProbePort {
  @override
  Future<List<Map<String, Object?>>> listTools(
    McpServerRecord server,
    McpServerLaunch launch,
  ) async =>
      [
        {
          'name': 'read',
          'description': 'reads',
          'inputSchema': {'type': 'object'},
        },
      ];

  McpRemoteTarget? lastRemote;

  @override
  Future<List<Map<String, Object?>>> listRemoteTools(
    McpServerRecord server,
    McpRemoteTarget remote,
  ) async {
    lastRemote = remote;
    return [
      {
        'name': 'read',
        'description': 'reads',
        'inputSchema': {'type': 'object'},
      },
    ];
  }
}

void main() {
  late Directory root;
  late File binary;
  late WorkspaceMcpCommands commands;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mcp-ipc');
    binary = File('${root.path}/server')..writeAsBytesSync([1, 2, 3]);
    commands = WorkspaceMcpCommands(
      McpService(McpRegistry(File('${root.path}/mcp.json')), FakeProbe()),
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<Object?> add() => commands.handle('mcp.add', {
        'serverId': 'files',
        'displayName': 'Files',
        'command': binary.path,
        'arguments': ['--root', '/tmp'],
        'environmentNames': ['API_TOKEN'],
      });

  test('handles only mcp.* commands', () {
    expect(WorkspaceMcpCommands.handles('mcp.list'), isTrue);
    expect(WorkspaceMcpCommands.handles('plugins.list'), isFalse);
  });

  test('add, consent by hash, enable, list and remove', () async {
    await add();
    final shown =
        await commands.handle('mcp.consent', {'serverId': 'files'}) as Map;
    expect(shown['consentRequired'], isTrue);
    await commands.handle('mcp.consent', {
      'serverId': 'files',
      'acceptHash': shown['documentHash'],
    });
    await commands.handle('mcp.enable', {'serverId': 'files'});
    final listed = await commands.handle('mcp.list', {}) as Map;
    final server = (listed['servers'] as List).single as Map;
    expect(server['enabled'], isTrue);
    expect(server['tools'], ['read']);
    await commands.handle('mcp.remove', {'serverId': 'files'});
    expect((await commands.handle('mcp.list', {}) as Map)['servers'], isEmpty);
  });

  test('policy errors keep their stable codes', () async {
    await add();
    await expectLater(
      commands.handle('mcp.enable', {'serverId': 'files'}),
      throwsA(
        isA<WorkspaceManagerProtocolException>().having(
          (e) => e.code,
          'code',
          'mcp_not_consented',
        ),
      ),
    );
    await expectLater(
      commands.handle('mcp.consent', {
        'serverId': 'files',
        'acceptHash': 'a' * 64,
      }),
      throwsA(
        isA<WorkspaceManagerProtocolException>().having(
          (e) => e.code,
          'code',
          'mcp_consent_mismatch',
        ),
      ),
    );
  });

  test('rejects malformed payloads', () async {
    final bad = <Future<Object?> Function()>[
      () => commands.handle('mcp.enable', {'serverId': 'Bad Id'}),
      () => commands.handle('mcp.enable', {}),
      () => commands.handle('mcp.consent', {
            'serverId': 'files',
            'acceptHash': 'nothex',
          }),
      () => commands.handle('mcp.add', {
            'serverId': 'files',
            'displayName': 'x',
            'command': 'relative',
          }),
      () => commands.handle('mcp.add', {
            'serverId': 'files',
            'displayName': 'x',
            'command': binary.path,
            'arguments': [1],
          }),
      () => commands.handle('mcp.nope', {}),
    ];
    for (final call in bad) {
      await expectLater(
        call(),
        throwsA(isA<WorkspaceManagerProtocolException>()),
      );
    }
  });

  test('bind and unbind change what mcp.list reports', () async {
    await add();
    await commands.handle('mcp.bind', {
      'serverId': 'files',
      'workerTypeId': 'chatgpt',
    });
    var listed = await commands.handle('mcp.list', {}) as Map;
    expect(listed['bindings'], {
      'chatgpt': ['files'],
    });
    await commands.handle('mcp.unbind', {
      'serverId': 'files',
      'workerTypeId': 'chatgpt',
    });
    listed = await commands.handle('mcp.list', {}) as Map;
    expect(listed['bindings'], isEmpty);
    await expectLater(
      commands.handle('mcp.bind', {
        'serverId': 'files',
        'workerTypeId': 'Bad Type',
      }),
      throwsA(isA<WorkspaceManagerProtocolException>()),
    );
  });

  test('a corrupt registry gives a stable, actionable error', () async {
    File('${root.path}/mcp.json').writeAsStringSync('garbage');
    await expectLater(
      commands.handle('mcp.list', {}),
      throwsA(
        isA<WorkspaceManagerProtocolException>().having(
          (e) => e.code,
          'code',
          'mcp_registry_unreadable',
        ),
      ),
    );
  });

  test('addRemote validates its payload and stores only the variable name',
      () async {
    await commands.handle('mcp.addRemote', {
      'serverId': 'acme',
      'displayName': 'Acme',
      'endpoint': 'https://mcp.acme.example/mcp',
      'tokenEnv': 'ACME_TOKEN',
    });
    final listed = await commands.handle('mcp.list', {}) as Map;
    final server = (listed['servers'] as List).single as Map;
    expect(server['remote'], isTrue);
    expect(server['endpoint'], 'https://mcp.acme.example/mcp');
    for (final bad in <Map<String, Object?>>[
      {'serverId': 'b1', 'displayName': 'x', 'endpoint': 5},
      {
        'serverId': 'b2',
        'displayName': 'x',
        'endpoint': 'https://a.example/m',
        'tokenEnv': 7
      },
      {
        'serverId': 'b3',
        'displayName': 'x',
        'endpoint': 'https://a.example/m',
        'insecureLoopback': 'yes'
      },
    ]) {
      await expectLater(
        commands.handle('mcp.addRemote', bad),
        throwsA(isA<WorkspaceManagerProtocolException>()),
        reason: '$bad',
      );
    }
    await expectLater(
      commands.handle('mcp.addRemote', {
        'serverId': 'insecure',
        'displayName': 'x',
        'endpoint': 'http://mcp.acme.example/mcp',
      }),
      throwsA(
        isA<WorkspaceManagerProtocolException>().having(
          (e) => e.code,
          'code',
          'invalid_request',
        ),
      ),
    );
  });

  group('mcp.toolCallStatus', () {
    test('reports fence_unavailable when no fence is configured', () async {
      await expectLater(
        commands.handle('mcp.toolCallStatus', {'taskId': 'task-1'}),
        throwsA(
          isA<WorkspaceManagerProtocolException>().having(
            (e) => e.code,
            'code',
            'fence_unavailable',
          ),
        ),
      );
    });

    test('validates taskId parameter', () async {
      final fence = McpToolCallFence(Directory('${root.path}/fence'));
      final commandsWithFence = WorkspaceMcpCommands(
        McpService(McpRegistry(File('${root.path}/mcp.json')), FakeProbe()),
        fence: fence,
      );
      for (final bad in <Map<String, Object?>>[
        {},
        {'taskId': ''},
        {'taskId': 123},
        {'taskId': 'x' * 901},
      ]) {
        await expectLater(
          commandsWithFence.handle('mcp.toolCallStatus', bad),
          throwsA(
            isA<WorkspaceManagerProtocolException>().having(
              (e) => e.code,
              'code',
              'invalid_request',
            ),
          ),
        );
      }
    });

    test('returns unclaimed when dispatch key was never claimed', () async {
      final fence = McpToolCallFence(Directory('${root.path}/fence'));
      final commandsWithFence = WorkspaceMcpCommands(
        McpService(McpRegistry(File('${root.path}/mcp.json')), FakeProbe()),
        fence: fence,
      );
      final res = await commandsWithFence.handle('mcp.toolCallStatus', {
        'taskId': 'task-unclaimed',
      }) as Map;
      expect(res['taskId'], 'task-unclaimed');
      expect(res['dispatchKey'], 'mcp-tool-v1:task-unclaimed');
      expect(res['status'], 'unclaimed');
    });

    test('returns claimed_no_outcome when claimed without recorded outcome',
        () async {
      final fence = McpToolCallFence(Directory('${root.path}/fence'));
      final commandsWithFence = WorkspaceMcpCommands(
        McpService(McpRegistry(File('${root.path}/mcp.json')), FakeProbe()),
        fence: fence,
      );
      await fence.claim('mcp-tool-v1:task-claimed');
      final res = await commandsWithFence.handle('mcp.toolCallStatus', {
        'taskId': 'task-claimed',
      }) as Map;
      expect(res['taskId'], 'task-claimed');
      expect(res['dispatchKey'], 'mcp-tool-v1:task-claimed');
      expect(res['status'], 'claimed_no_outcome');
    });

    test('returns recorded outcome with state, code and result', () async {
      final fence = McpToolCallFence(Directory('${root.path}/fence'));
      final commandsWithFence = WorkspaceMcpCommands(
        McpService(McpRegistry(File('${root.path}/mcp.json')), FakeProbe()),
        fence: fence,
      );
      await fence.claim('mcp-tool-v1:task-recorded');
      await fence.recordOutcome(
        'mcp-tool-v1:task-recorded',
        state: 'completed',
        code: 'completed',
        result: {'output': 'hello world'},
      );
      final res = await commandsWithFence.handle('mcp.toolCallStatus', {
        'taskId': 'task-recorded',
      }) as Map;
      expect(res['taskId'], 'task-recorded');
      expect(res['dispatchKey'], 'mcp-tool-v1:task-recorded');
      expect(res['status'], 'recorded');
      expect(res['state'], 'completed');
      expect(res['code'], 'completed');
      expect(res['result'], {'output': 'hello world'});
    });
  });
}
