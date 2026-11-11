@Timeout(Duration(minutes: 2))
library;

import 'package:syntila_cli_worker_engine/src/mcp_host.dart';
import 'package:syntila_cli_worker_engine/src/mcp_probe.dart';
import 'package:syntila_cli_worker_engine/src/mcp_worker_runner.dart';
import 'package:syntila_cli_worker_engine/src/external_worker_process_host.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:test/test.dart';

import 'support/fake_mcp_http.dart';

void main() {
  late FakeMcpHttp fake;
  late McpHost host;
  late McpWorkerRunner runner;

  McpServerSpec spec({
    ToolPins? pins,
    String? token,
    bool worker = false,
    Uri? endpoint,
    bool insecure = true,
  }) => McpServerSpec(
    serverId: 'remote',
    workspaceId: 'ws1',
    requireWorkerProfile: worker,
    pins: pins,
    remote: McpRemote(
      endpoint: endpoint ?? fake.endpoint,
      bearerToken: token,
      allowInsecureLoopback: insecure,
    ),
  );

  Future<McpServerSpec> consented({String? token, bool worker = false}) async {
    final lease = await host.acquire(spec(token: token, worker: worker));
    final pins = ToolPins.fromTools(lease.tools);
    lease.release();
    return spec(pins: pins, token: token, worker: worker);
  }

  setUp(() async {
    fake = FakeMcpHttp();
    await fake.start();
    host = McpHost(pluginHost: ExternalWorkerProcessHost());
    runner = McpWorkerRunner(host);
  });
  tearDown(() async {
    await host.closeAll();
    await fake.stop();
  });

  test(
    'a remote server is listed, pinned and called through the host',
    () async {
      final s = await consented();
      final lease = await host.acquire(s);
      final result = await (await lease.callTool('echo', {
        'text': 'hi',
      })).result;
      expect((result['content'] as List).first['text'], 'json: hi');
      lease.release();
      expect(host.warmSessions, 1);
    },
  );

  test(
    'an unconsented remote server lists tools but cannot be called',
    () async {
      final lease = await host.acquire(spec());
      expect(lease.tools.single['name'], 'echo');
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
    },
  );

  test(
    'a definition changed on the server is caught with no push notice',
    () async {
      final s = await consented();
      final lease = await host.acquire(s);
      await (await lease.callTool('echo', {'text': 'ok'})).result;
      fake.toolDescription = 'now asks for your secrets';
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
      final diff = await lease.pinDiff();
      expect(diff!.changed, ['echo']);
      lease.release();
    },
  );

  test(
    'authentication failure, then a refreshed token on the same server',
    () async {
      fake.requiredToken = 'good-token';
      await expectLater(
        host.acquire(spec(token: 'stale-token')),
        throwsA(
          isA<McpException>().having(
            (e) => e.code,
            'code',
            McpFailure.authRequired,
          ),
        ),
      );
      expect(host.warmSessions, 0);
      final lease = await host.acquire(spec(token: 'good-token'));
      expect(lease.tools.single['name'], 'echo');
      lease.release();
    },
  );

  test('plain http is refused unless it is loopback and opted in', () async {
    await expectLater(
      host.acquire(spec(endpoint: Uri.parse('http://example.com/mcp'))),
      throwsA(isA<McpException>()),
    );
    await expectLater(
      host.acquire(spec(insecure: false)),
      throwsA(isA<McpException>()),
    );
    expect(host.warmSessions, 0);
  });

  test('a remote MCP Worker runs an assignment and answers probes', () async {
    fake.worker = true;
    final s = await consented(worker: true);
    final outcome = await runner.run(
      s,
      ExternalWorkerRunRequest(
        executeId: 'e',
        prompt: 'hello',
        access: 'read_only',
        deadline: const Duration(seconds: 30),
      ),
    );
    expect((outcome as ExternalWorkerRunSuccess).output, 'remote echo: hello');
    final probe =
        await runner.probe(s, 'passive') as ExternalWorkerProbeSuccess;
    expect(probe.state, 'ready');
    expect(probe.checks.single['code'], 'remote');
  });

  test(
    'a remote Worker never receives a local working-directory path',
    () async {
      fake.worker = true;
      final outcome = await runner.run(
        await consented(worker: true),
        ExternalWorkerRunRequest(
          executeId: 'e',
          prompt: 'hello',
          access: 'read_only',
          deadline: const Duration(seconds: 30),
        ),
        workingDirectory: '/local/private/path',
      );
      expect(outcome, isA<ExternalWorkerRunSuccess>());
      final call = fake.seen.lastWhere(
        (s) => s.body?['method'] == 'tools/call',
      );
      final params = call.body!['params'] as Map;
      expect(
        (params['arguments'] as Map).containsKey('workingDirectory'),
        isFalse,
      );
    },
  );

  test(
    'a remote server without the Worker profile is rejected as a Worker',
    () async {
      final outcome = await runner.run(
        spec(worker: true),
        ExternalWorkerRunRequest(
          executeId: 'e',
          prompt: 'x',
          access: 'read_only',
          deadline: const Duration(seconds: 10),
        ),
      );
      expect(outcome, isA<ExternalWorkerRunFailure>());
      expect(host.warmSessions, 0);
    },
  );

  test('the bearer token is redacted from Worker-reported errors', () async {
    fake
      ..worker = true
      ..requiredToken = 'tok-abcdef123456';
    final s = await consented(token: 'tok-abcdef123456', worker: true);
    fake.leakToken = true;
    final outcome =
        await runner.run(
              s,
              ExternalWorkerRunRequest(
                executeId: 'e',
                prompt: 'x',
                access: 'read_only',
                deadline: const Duration(seconds: 10),
              ),
            )
            as ExternalWorkerRunFailure;
    expect(outcome.message, isNot(contains('tok-abcdef123456')));
    expect(outcome.message, contains('<redacted>'));
  });

  test(
    'the one-shot probe accepts a remote server and never echoes the token',
    () async {
      fake.requiredToken = 'probe-token-123456';
      final ok = await runMcpProbe({
        'remote': {
          'endpoint': fake.endpoint.toString(),
          'bearerToken': 'probe-token-123456',
          'allowInsecureLoopback': true,
        },
      });
      expect(ok['ok'], isTrue);
      expect((ok['tools']! as List).single['name'], 'echo');
      final denied = await runMcpProbe({
        'remote': {
          'endpoint': fake.endpoint.toString(),
          'bearerToken': 'wrong-token-123456',
          'allowInsecureLoopback': true,
        },
      });
      expect(denied['ok'], isFalse);
      expect(denied['code'], McpFailure.authRequired);
      expect(denied.toString(), isNot(contains('wrong-token-123456')));
      final insecure = await runMcpProbe({
        'remote': {'endpoint': 'http://example.com/mcp'},
      });
      expect(insecure['ok'], isFalse);
    },
  );

  test('closing the host ends the remote session', () async {
    final lease = await host.acquire(spec());
    lease.release();
    await host.closeAll();
    expect(fake.seen.last.method, 'DELETE');
  });
}
