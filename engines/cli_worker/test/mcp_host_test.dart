@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:syntila_cli_worker_engine/src/mcp_host.dart';
import 'package:syntila_cli_worker_engine/src/external_worker_process_host.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:test/test.dart';

const fixturePath =
    '../../packages/syntila_mcp_protocol/test/fixtures/echo_server.dart';

late String dartDigest;
late Directory root;
final plugins = ExternalWorkerProcessHost();

McpServerSpec spec(String mode, {ToolPins? pins, bool worker = false}) =>
    McpServerSpec(
      serverId: 'echo-$mode',
      workspaceId: 'ws1',
      requireWorkerProfile: worker,
      pins: pins,
      launch: ExternalWorkerLaunch(
        executable: Platform.resolvedExecutable,
        arguments: [File(fixturePath).absolute.path, mode],
        artifactSha256: dartDigest,
        pluginId: 'echo-$mode',
        version: '1.0.0',
        dataDirectory: root.path,
        workingDirectory: root.path,
        environment: ExternalWorkerProcessHost.buildEnvironment(),
        hostVersion: '1.4.0',
      ),
    );

Future<ToolPins> consent(McpHost host, String mode) async {
  final lease = await host.acquire(spec(mode));
  final pins = ToolPins.fromTools(lease.tools);
  lease.release();
  return pins;
}

void main() {
  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('mcp-host');
    dartDigest = await plugins.sha256OfFile(Platform.resolvedExecutable);
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  test('reuses one warm server across leases', () async {
    final host = McpHost(pluginHost: plugins);
    addTearDown(host.closeAll);
    final pins = await consent(host, 'normal');
    final a = await host.acquire(spec('normal', pins: pins));
    final first = a.client;
    final res = await (await a.callTool('echo', {'text': 'one'})).result;
    expect((res['content'] as List).first['text'], 'one');
    a.release();
    final b = await host.acquire(spec('normal', pins: pins));
    expect(identical(b.client, first), isTrue);
    expect(host.warmSessions, 1);
    b.release();
  });

  test('refuses calls before consent (no pins)', () async {
    final host = McpHost(pluginHost: plugins);
    addTearDown(host.closeAll);
    final lease = await host.acquire(spec('normal'));
    await expectLater(
      lease.callTool('echo', {'text': 'x'}),
      throwsA(
        isA<McpException>().having(
          (e) => e.code,
          'code',
          McpFailure.definitionChanged,
        ),
      ),
    );
    lease.release();
  });

  test('blocks a tool whose definition drifted after consent', () async {
    final host = McpHost(pluginHost: plugins);
    addTearDown(host.closeAll);
    final pins = await consent(host, 'normal');
    final lease = await host.acquire(spec('normal', pins: pins));
    await (await lease.callTool('mutate', {})).result;
    final diff = await lease.pinDiff();
    expect(diff!.changed, ['echo']);
    await expectLater(
      lease.callTool('echo', {'text': 'x'}),
      throwsA(
        isA<McpException>().having(
          (e) => e.code,
          'code',
          McpFailure.definitionChanged,
        ),
      ),
    );
    lease.release();
  });

  test('restarts a crashed server on the next acquire', () async {
    final host = McpHost(pluginHost: plugins);
    addTearDown(host.closeAll);
    final pins = await consent(host, 'crash');
    final lease = await host.acquire(spec('crash', pins: pins));
    final first = lease.client;
    await expectLater(
      (await lease.callTool('echo', {})).result,
      throwsA(
        isA<McpException>().having(
          (e) => e.code,
          'code',
          McpFailure.serverCrashed,
        ),
      ),
    );
    lease.release();
    final again = await host.acquire(spec('crash', pins: pins));
    expect(identical(again.client, first), isFalse);
    expect(again.client.isClosed, isFalse);
    again.release();
  });

  test('rejects a Worker-class server without the profile marker', () async {
    final host = McpHost(pluginHost: plugins);
    addTearDown(host.closeAll);
    await expectLater(
      host.acquire(spec('noprofile', worker: true)),
      throwsA(isA<McpException>()),
    );
    expect(host.warmSessions, 0);
  });

  test('rejects a pinned launch whose binary digest differs', () async {
    final host = McpHost(pluginHost: plugins);
    addTearDown(host.closeAll);
    final good = spec('normal');
    final bad = McpServerSpec(
      serverId: good.serverId,
      workspaceId: good.workspaceId,
      launch: ExternalWorkerLaunch(
        executable: good.launch!.executable,
        arguments: good.launch!.arguments,
        artifactSha256: '0' * 64,
        pluginId: good.launch!.pluginId,
        version: good.launch!.version,
        dataDirectory: good.launch!.dataDirectory,
        workingDirectory: good.launch!.workingDirectory,
        environment: good.launch!.environment,
        hostVersion: good.launch!.hostVersion,
      ),
    );
    await expectLater(
      host.acquire(bad),
      throwsA(isA<ExternalWorkerLaunchException>()),
    );
  });

  test('closes idle servers after the TTL', () async {
    final host = McpHost(
      pluginHost: plugins,
      idleTtl: const Duration(milliseconds: 300),
    );
    addTearDown(host.closeAll);
    final lease = await host.acquire(spec('normal'));
    lease.release();
    expect(host.warmSessions, 1);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(host.warmSessions, 0);
  });

  test('serialises concurrent leases on a maxConcurrent=1 server', () async {
    final host = McpHost(pluginHost: plugins);
    addTearDown(host.closeAll);
    final a = await host.acquire(spec('normal'));
    var gotSecond = false;
    final second = host.acquire(spec('normal')).then((l) {
      gotSecond = true;
      return l;
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(gotSecond, isFalse);
    a.release();
    (await second).release();
    expect(gotSecond, isTrue);
  });
}
