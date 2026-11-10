@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:syntila_workspace/mcp_engine_probe.dart';
import 'package:syntila_workspace/mcp_registry.dart';
import 'package:syntila_workspace/mcp_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late McpService service;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mcp-engine-probe');
    final engine = File(
      '../../engines/cli_worker/bin/syntila_cli_worker.dart',
    ).absolute.path;
    service = McpService(
      McpRegistry(File('${root.path}/mcp.json')),
      EngineMcpProbe(
        locateEngine: () => (
          executable: Platform.resolvedExecutable,
          argumentsPrefix: [engine]
        ),
        workingDirectory: root,
      ),
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<void> addEcho(String mode) => service.add(
        serverId: 'echo',
        displayName: 'Echo',
        command: Platform.resolvedExecutable,
        arguments: [
          File(
            '../../packages/syntila_mcp_protocol/test/fixtures/echo_server.dart',
          ).absolute.path,
          mode,
        ],
      );

  test('consent through the real Engine shows and pins the tools', () async {
    await addEcho('normal');
    final shown = await service.consent('echo');
    final tools = (shown['document']! as Map)['tools'] as List;
    expect([
      for (final t in tools) (t as Map)['name']
    ], [
      'echo',
      'mutate',
      'slow',
    ]);
    await service.consent('echo', acceptHash: shown['documentHash']! as String);
    service.enable('echo');
    final launch = (await service.launchesForOwnerExecution()).single;
    expect(launch.name, 'echo');
  });

  test('an Engine-side failure surfaces as a stable error', () async {
    await addEcho('badversion');
    await expectLater(
      service.consent('echo'),
      throwsA(
        isA<McpPolicyException>().having(
          (e) => e.code,
          'code',
          'mcp_version_unsupported',
        ),
      ),
    );
  });
}
