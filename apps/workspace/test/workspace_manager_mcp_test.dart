import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart'
    show McpServerLaunch;
import 'package:syntila_workspace/mcp_registry.dart';
import 'package:syntila_workspace/mcp_service.dart';
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
}
