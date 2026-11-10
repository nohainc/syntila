import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart'
    show McpServerLaunch;
import 'package:syntila_workspace/mcp_action_handler.dart';
import 'package:syntila_workspace/mcp_registry.dart';
import 'package:syntila_workspace/mcp_service.dart';
import 'package:test/test.dart';

class _FakeProbe implements McpProbePort {
  bool failNext = false;

  @override
  Future<List<Map<String, Object?>>> listTools(
    McpServerRecord server,
    McpServerLaunch launch,
  ) async {
    if (failNext) throw StateError('probe failed');
    return [
      {
        'name': 'read_file',
        'description': 'Reads a file',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'}
          },
        },
      },
    ];
  }

  @override
  Future<List<Map<String, Object?>>> listRemoteTools(
    McpServerRecord server,
    McpRemoteTarget remote,
  ) async {
    if (failNext) throw StateError('remote probe failed');
    return [
      {
        'name': 'query_remote',
        'description': 'Queries remote database',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'q': {'type': 'string'}
          },
        },
      },
    ];
  }
}

void main() {
  late Directory tempDir;
  late McpRegistry registry;
  late _FakeProbe probe;
  late McpService service;
  late McpActionHandler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mcp-action-test');
    File('${tempDir.path}/srv').writeAsBytesSync([1, 2, 3]);
    registry = McpRegistry(File('${tempDir.path}/servers.json'));
    probe = _FakeProbe();
    service = McpService(
      registry,
      probe,
      environment: {'REMOTE_TOKEN': 'token-xyz'},
    );
    handler = McpActionHandler(service);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('validates required fields', () async {
    final result = await handler.handle({});
    expect(result['ok'], false);
    expect((result['error'] as Map)['code'], 'invalid_request');
  });

  test('supports consent, enable, disable, test and remove lifecycle',
      () async {
    // Servers are added only in the Workspace app, never through Cloud.
    service.addRemote(
      serverId: 'remote-db',
      displayName: 'Remote DB',
      endpoint: 'https://example.com/mcp',
      tokenEnv: 'REMOTE_TOKEN',
    );

    // 2. test
    final testResult = await handler.handle({
      'actionId': 'act-test',
      'action': 'test',
      'serverId': 'remote-db',
    });
    expect(testResult['ok'], true);
    final testOutcome = testResult['result'] as Map;
    expect(testOutcome['reachable'], true);
    expect(testOutcome['toolsCount'], 1);

    // 3. consent request (review phase)
    final reviewResult = await handler.handle({
      'actionId': 'act-review',
      'action': 'consent',
      'serverId': 'remote-db',
    });
    expect(reviewResult['ok'], true);
    final reviewOutcome = reviewResult['result'] as Map;
    expect(reviewOutcome['consentRequired'], true);
    final docHash = reviewOutcome['documentHash'] as String;

    // 4. consent accept
    final acceptResult = await handler.handle({
      'actionId': 'act-accept',
      'action': 'consent',
      'serverId': 'remote-db',
      'acceptHash': docHash,
    });
    expect(acceptResult['ok'], true);
    expect((acceptResult['result'] as Map)['consented'], true);

    // 5. enable
    final enableResult = await handler.handle({
      'actionId': 'act-enable',
      'action': 'enable',
      'serverId': 'remote-db',
    });
    expect(enableResult['ok'], true);
    expect((enableResult['result'] as Map)['enabled'], true);

    // 6. disable
    final disableResult = await handler.handle({
      'actionId': 'act-disable',
      'action': 'disable',
      'serverId': 'remote-db',
    });
    expect(disableResult['ok'], true);
    expect((disableResult['result'] as Map)['enabled'], false);

    // 7. remove
    final removeResult = await handler.handle({
      'actionId': 'act-remove',
      'action': 'remove',
      'serverId': 'remote-db',
    });
    expect(removeResult['ok'], true);
    expect((removeResult['result'] as Map)['removed'], true);
  });

  test('Cloud cannot add servers or bind them to Workers', () async {
    for (final action in ['addRemote', 'bind', 'unbind']) {
      final result = await handler.handle({
        'actionId': 'act-$action',
        'action': action,
        'serverId': 'remote-db',
        'displayName': 'Remote DB',
        'endpoint': 'https://example.com/mcp',
        'workerTypeId': 'codex',
      });
      expect(result['ok'], false);
      expect((result['error'] as Map)['code'], 'unsupported_action');
    }
    expect(service.list(), isEmpty);
  });

  test('reports errors as structured outcomes without throwing', () async {
    final result = await handler.handle({
      'actionId': 'act-err',
      'action': 'enable',
      'serverId': 'non-existent',
    });
    expect(result['ok'], false);
    expect((result['error'] as Map)['code'], 'mcp_not_found');
  });
}
