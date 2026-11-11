@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';

import 'package:syntila_cli_worker_engine/src/mcp_host.dart';
import 'package:syntila_cli_worker_engine/src/mcp_worker_runner.dart';
import 'package:syntila_cli_worker_engine/src/external_worker_process_host.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_external_worker_protocol/syntila_external_worker_protocol.dart';
import 'package:test/test.dart';

const workerPath = '../../examples/mcp/echo_worker/echo_worker.dart';

late String dartDigest;
late Directory root;
final plugins = ExternalWorkerProcessHost();

McpServerSpec spec(String mode, {ToolPins? pins, bool secret = false}) =>
    McpServerSpec(
      serverId: 'echo-$mode',
      workspaceId: 'ws1',
      requireWorkerProfile: true,
      pins: pins,
      launch: ExternalWorkerLaunch(
        executable: Platform.resolvedExecutable,
        arguments: [File(workerPath).absolute.path, mode],
        artifactSha256: dartDigest,
        pluginId: 'echo-$mode',
        version: '1.0.0',
        dataDirectory: root.path,
        workingDirectory: root.path,
        environment: {
          ...ExternalWorkerProcessHost.buildEnvironment(),
          if (secret) 'SECRET_TOKEN': 'sup3r-s3cret-value',
        },
        hostVersion: '1.4.0',
      ),
    );

ExternalWorkerRunRequest request(
  String prompt, {
  String access = 'read_write',
  Duration deadline = const Duration(seconds: 20),
}) => ExternalWorkerRunRequest(
  executeId: 'e1',
  prompt: prompt,
  access: access,
  deadline: deadline,
  model: 'm1',
  sessionKey: 's1',
  sessionMode: 'resume',
);

void main() {
  late McpHost host;
  late McpWorkerRunner runner;

  Future<McpServerSpec> consented(String mode, {bool secret = false}) async {
    final lease = await host.acquire(spec(mode, secret: secret));
    final pins = ToolPins.fromTools(lease.tools);
    lease.release();
    return spec(mode, pins: pins, secret: secret);
  }

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('mcp-worker');
    dartDigest = await plugins.sha256OfFile(Platform.resolvedExecutable);
  });
  tearDownAll(() => root.deleteSync(recursive: true));
  setUp(() {
    host = McpHost(pluginHost: plugins);
    runner = McpWorkerRunner(host);
  });
  tearDown(() => host.closeAll());

  test(
    'runs an assignment, maps access/model/session and streams progress',
    () async {
      final progress = <(int?, String)>[];
      final outcome = await runner.run(
        await consented('normal'),
        request('hi'),
        onProgress: (p, m) => progress.add((p, m)),
      );
      final ok = outcome as ExternalWorkerRunSuccess;
      expect(ok.output, 'echo: hi | access: work | model: m1');
      // request() asks to resume a session; the Worker confirms it.
      expect(ok.sessionState, 'resumed');
      expect(progress, [(50, 'working')]);
    },
  );

  test('read_only is sent as restricted', () async {
    final outcome = await runner.run(
      await consented('normal'),
      request('hi', access: 'read_only'),
    );
    expect(
      (outcome as ExternalWorkerRunSuccess).output,
      contains('access: restricted'),
    );
  });

  test(
    'worker-reported errors keep known codes and normalise unknown ones',
    () async {
      final s = await consented('normal');
      final known =
          await runner.run(s, request('FAIL')) as ExternalWorkerRunFailure;
      expect(known.code, 'rate_limited');
      expect(known.fromPlugin, isTrue);
      expect(known.retryable, isTrue);
      expect(known.message, 'worker said no');
      final unknown =
          await runner.run(s, request('BADCODE')) as ExternalWorkerRunFailure;
      expect(unknown.code, 'internal');
    },
  );

  test('artifacts must be safe relative paths', () async {
    final s = await consented('normal');
    final good =
        await runner.run(s, request('ART')) as ExternalWorkerRunSuccess;
    expect(good.artifacts, ['out/report.md']);
    final bad =
        await runner.run(s, request('BADART')) as ExternalWorkerRunFailure;
    expect(bad.code, ExternalWorkerHostFailure.artifactPathInvalid);
  });

  test('oversize output is rejected', () async {
    final outcome = await runner.run(
      await consented('normal'),
      request('BIGTEXT'),
    );
    expect(outcome, isA<ExternalWorkerRunFailure>());
    expect(
      (outcome as ExternalWorkerRunFailure).code,
      anyOf('output_too_large', ExternalWorkerHostFailure.protocolViolation),
    );
  });

  test('enforces the output limit in UTF-8 bytes', () async {
    final s = await consented('normal');
    final within = await runner.run(s, request('MULTIBYTE_WITHIN_LIMIT'));
    expect(within, isA<ExternalWorkerRunSuccess>());
    final over = await runner.run(s, request('MULTIBYTE_OVER_LIMIT'));
    expect(over, isA<ExternalWorkerRunFailure>());
    expect((over as ExternalWorkerRunFailure).code, 'output_too_large');
  });

  test('a crash is reported and the next run starts a fresh server', () async {
    final s = await consented('normal');
    final crashed =
        await runner.run(s, request('CRASH')) as ExternalWorkerRunFailure;
    expect(crashed.code, ExternalWorkerHostFailure.crashed);
    final again =
        await runner.run(s, request('after')) as ExternalWorkerRunSuccess;
    expect(again.output, contains('echo: after'));
  });

  test('a deadline is a retryable timeout and the server is killed', () async {
    final outcome =
        await runner.run(
              await consented('normal'),
              request('SLOW', deadline: const Duration(milliseconds: 500)),
            )
            as ExternalWorkerRunFailure;
    expect(outcome.code, 'timeout');
    expect(outcome.retryable, isTrue);
  });

  test(
    'cancel is cooperative, then the server that ignores it is killed',
    () async {
      final s = await consented('normal');
      final cancel = Completer<void>();
      final clock = Stopwatch()..start();
      final running = runner.run(s, request('SLOW'), cancel: cancel.future);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      cancel.complete();
      final outcome = await running as ExternalWorkerRunFailure;
      expect(outcome.code, 'cancelled');
      // The echo worker never answers a cancel, so the grace period elapsed.
      expect(clock.elapsed, greaterThan(McpLimits.cancelGrace));
      expect(host.warmSessions, 0);
    },
  );

  test('without consent (no pins) nothing is executed', () async {
    final outcome = await runner.run(spec('normal'), request('hi'));
    expect(
      (outcome as ExternalWorkerRunFailure).code,
      ExternalWorkerHostFailure.identityMismatch,
    );
  });

  test('a server without syntila.execute is refused and discarded', () async {
    final outcome =
        await runner.run(await consented('noexecute'), request('hi'))
            as ExternalWorkerRunFailure;
    expect(outcome.code, ExternalWorkerHostFailure.protocolViolation);
    expect(host.warmSessions, 0);
  });

  test('probe maps the worker state and rejects unknown ones', () async {
    final ready = await runner.probe(await consented('normal'), 'passive');
    expect((ready as ExternalWorkerProbeSuccess).state, 'ready');
    expect(ready.checks.single, {
      'code': 'echo',
      'ok': true,
      'message': 'echo worker ready',
    });
    final bogus = await runner.probe(await consented('badprobe'), 'passive');
    expect(
      (bogus as ExternalWorkerRunFailure).code,
      ExternalWorkerHostFailure.protocolViolation,
    );
  });

  test('a malformed probe check is a protocol violation', () async {
    final outcome = await runner.probe(await consented('badcheck'), 'passive');
    expect(
      (outcome as ExternalWorkerRunFailure).code,
      ExternalWorkerHostFailure.protocolViolation,
    );
  });

  test(
    'secrets from the launch environment are redacted from errors',
    () async {
      final outcome =
          await runner.run(
                await consented('normal', secret: true),
                request('LEAK'),
              )
              as ExternalWorkerRunFailure;
      expect(outcome.message, isNot(contains('sup3r-s3cret-value')));
      expect(outcome.message, contains('<redacted>'));
    },
  );
}
