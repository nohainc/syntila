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
  late File binary;
  late McpRegistry registry;
  late _FakeProbe probe;
  late McpService service;
  late McpActionHandler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('mcp-action-test');
    binary = File('${tempDir.path}/srv')..writeAsBytesSync([1, 2, 3]);
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

  test('supports addRemote, consent, enable, disable, and test lifecycle',
      () async {
    // 1. addRemote
    final addResult = await handler.handle({
      'actionId': 'act-add',
      'action': 'addRemote',
      'serverId': 'remote-db',
      'displayName': 'Remote DB',
      'endpoint': 'https://example.com/mcp',
      'tokenEnv': 'REMOTE_TOKEN',
    });
    expect(addResult['ok'], true);
    expect(addResult['serverId'], 'remote-db');

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

  test('bind and unbind for local servers', () async {
    await service.add(
      serverId: 'local-srv',
      displayName: 'Local Srv',
      command: binary.path,
    );
    await service.consent('local-srv');

    final bindResult = await handler.handle({
      'actionId': 'act-bind',
      'action': 'bind',
      'serverId': 'local-srv',
      'workerTypeId': 'codex',
    });
    expect(bindResult['ok'], true);
    expect((bindResult['result'] as Map)['bound'], true);

    final unbindResult = await handler.handle({
      'actionId': 'act-unbind',
      'action': 'unbind',
      'serverId': 'local-srv',
      'workerTypeId': 'codex',
    });
    expect(unbindResult['ok'], true);
    expect((unbindResult['result'] as Map)['bound'], false);
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
