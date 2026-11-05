@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';

import 'package:syntila_cli_worker_engine/src/plugin_host.dart';
import 'package:syntila_cli_worker_engine/src/plugin_redactor.dart';
import 'package:syntila_cli_worker_engine/src/plugin_resource_monitor.dart';
import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:test/test.dart';

import 'support/plugin_test_binaries.dart';

late Directory root;
late String fixture;
late String fixtureDigest;
final host = PluginHost();

PluginLaunch launch(String fault, {String? digest, Directory? work}) {
  final cwd = work ?? Directory.systemTemp.createTempSync('plugin-work');
  return PluginLaunch(
    executable: fixture,
    arguments: ['--fault=$fault'],
    artifactSha256: digest ?? fixtureDigest,
    pluginId: 'fixture-plugin',
    version: '1.0.0',
    dataDirectory: root.path,
    workingDirectory: cwd.path,
    environment: PluginHost.buildEnvironment(),
    hostVersion: '1.4.0',
  );
}

PluginRunRequest request({
  Duration deadline = const Duration(seconds: 20),
  String prompt = 'hi',
}) => PluginRunRequest(
  executeId: 'e1',
  prompt: prompt,
  access: 'read_write',
  deadline: deadline,
);

bool alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

void main() {
  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('plugin-host');
    fixture = (await PluginTestBinaries.ensure()).fixture;
    fixtureDigest = await host.sha256OfFile(fixture);
  });

  tearDownAll(() => root.deleteSync(recursive: true));

  test('runs a well-behaved plugin end to end', () async {
    final frames = <PluginFrame>[];
    final outcome = await host.run(
      launch(''),
      request(prompt: 'hello'),
      onFrame: frames.add,
    );
    expect(outcome, isA<PluginRunSuccess>());
    expect((outcome as PluginRunSuccess).output, 'echo: hello');
    expect(frames.map((f) => f.type), contains('progress'));
  });

  test(
    'protocol 1.2 transports a prompt larger than the old frame limit',
    () async {
      final text = 'x' * (1024 * 1024 + 1);
      final outcome = await host.run(launch('large'), request(prompt: text));
      expect(outcome, isA<PluginRunSuccess>());
      expect((outcome as PluginRunSuccess).output, 'accepted:${text.length}');
    },
  );

  test('legacy plugins receive a clear error for oversized prompts', () async {
    final outcome = await host.run(
      launch(''),
      request(prompt: 'x' * (512 * 1024 + 1)),
    );
    expect(outcome, isA<PluginRunFailure>());
    expect((outcome as PluginRunFailure).code, 'context_limit_exceeded');
    expect(outcome.message, contains('older protocol'));
  });

  test('observed memory breach fails work and kills the plugin', () async {
    final work = Directory.systemTemp.createTempSync('plugin-memory');
    addTearDown(() => work.deleteSync(recursive: true));
    final constrained = PluginHost(
      resourceLimits: const PluginResourceLimits(
        memoryBytes: 1,
        interval: Duration(milliseconds: 50),
      ),
    );
    final outcome = await constrained.run(
      launch('ignore-cancel', work: work),
      request(),
    );
    expect((outcome as PluginRunFailure).code, 'plugin_resource_limit');
    final marker = File('${work.path}/plugin.pid');
    if (marker.existsSync()) {
      expect(alive(int.parse(marker.readAsStringSync().trim())), isFalse);
    }
  }, skip: Platform.isWindows);

  test('refuses an artifact that does not match the pinned digest', () async {
    final work = Directory.systemTemp.createTempSync('plugin-work');
    final outcome = await host.run(
      launch('', digest: 'a' * 64, work: work),
      request(),
    );
    expect(
      (outcome as PluginRunFailure).code,
      PluginHostFailure.digestMismatch,
    );
    // The plugin writes plugin.pid first thing; it must never have started.
    expect(File('${work.path}/plugin.pid').existsSync(), isFalse);
  });

  test('refuses an identity that differs from the pinned manifest', () async {
    final outcome = await host.run(launch('bad-identity'), request());
    expect(
      (outcome as PluginRunFailure).code,
      PluginHostFailure.identityMismatch,
    );
  });

  test('terminates a plugin that writes non-protocol text to stdout', () async {
    final work = Directory.systemTemp.createTempSync('plugin-work');
    final outcome = await host.run(launch('noise', work: work), request());
    expect(
      (outcome as PluginRunFailure).code,
      PluginHostFailure.protocolViolation,
    );
    final pid = int.parse(File('${work.path}/plugin.pid').readAsStringSync());
    expect(alive(pid), isFalse);
  });

  test('terminates a plugin that sends an oversize frame', () async {
    final outcome = await host.run(launch('oversize'), request());
    expect(
      (outcome as PluginRunFailure).code,
      PluginHostFailure.protocolViolation,
    );
  });

  test('rejects an artifact path that escapes the working directory', () async {
    final outcome = await host.run(launch('escape'), request());
    expect(
      (outcome as PluginRunFailure).code,
      PluginHostFailure.protocolViolation,
    );
  });

  test('accepts a declared artifact that exists', () async {
    final outcome = await host.run(launch('artifact'), request());
    expect((outcome as PluginRunSuccess).artifacts, ['out.txt']);
  });

  test('reports a crash with its exit status', () async {
    final outcome = await host.run(launch('crash'), request());
    final failure = outcome as PluginRunFailure;
    expect(failure.code, PluginHostFailure.crashed);
    expect(failure.message, contains('3'));
  });

  test('passes a plugin error through with a normalized code', () async {
    final outcome = await host.run(launch('error'), request());
    final failure = outcome as PluginRunFailure;
    expect(failure.code, 'sign_in_required');
    expect(failure.fromPlugin, isTrue);
  });

  test('redacts secrets and local paths from stderr', () async {
    final outcome = await host.run(launch('stderr-secret'), request());
    final tail = (outcome as PluginRunFailure).stderrTail;
    expect(tail, isNot(contains('sk-abcdefghijklmnopqrstuvwxyz0123')));
    expect(tail, isNot(contains('/Users/someone')));
    expect(tail, contains('<redacted>'));
    expect(tail, contains('<path>'));
  });

  test('a cooperative cancel ends the run with cancelled', () async {
    final cancel = Completer<void>();
    Timer(const Duration(milliseconds: 500), cancel.complete);
    final outcome = await host.run(
      launch('slow'),
      request(),
      cancel: cancel.future,
    );
    expect((outcome as PluginRunFailure).code, 'cancelled');
  });

  test('a cancel requested before execute is never lost', () async {
    final outcome = await host.run(
      launch('slow'),
      request(),
      cancel: Future<void>.value(),
    );
    expect((outcome as PluginRunFailure).code, 'cancelled');
  });

  test('the deadline cancels the plugin and reports timeout', () async {
    final outcome = await host.run(
      launch('slow'),
      request(deadline: const Duration(seconds: 1)),
    );
    expect((outcome as PluginRunFailure).code, 'timeout');
  });

  test(
    'a plugin that ignores cancel is killed after the grace period',
    () async {
      final work = Directory.systemTemp.createTempSync('plugin-work');
      final started = DateTime.now();
      final outcome = await host.run(
        launch('ignore-cancel', work: work),
        request(deadline: const Duration(seconds: 1)),
      );
      expect((outcome as PluginRunFailure).code, 'timeout');
      expect(
        DateTime.now().difference(started),
        greaterThanOrEqualTo(const Duration(seconds: 5)),
      );
      final pid = int.parse(File('${work.path}/plugin.pid').readAsStringSync());
      expect(alive(pid), isFalse);
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );

  group('environment', () {
    test(
      'is built from an allow-list plus consented names, never SYNTILA_*',
      () {
        final env = PluginHost.buildEnvironment(
          consentedNames: ['ACME_ENDPOINT', 'SYNTILA_TOKEN', 'MISSING'],
          parentEnvironment: {
            'PATH': '/usr/bin',
            'ACME_ENDPOINT': 'https://x.example',
            'SYNTILA_TOKEN': 'secret',
            'SYNTILA_WORKSPACE_ID': 'w',
            'AWS_SECRET_ACCESS_KEY': 'must-not-leak',
          },
        );
        expect(env['PATH'], '/usr/bin');
        expect(env['ACME_ENDPOINT'], 'https://x.example');
        expect(env.keys.where((k) => k.startsWith('SYNTILA_')), isEmpty);
        expect(env.containsKey('AWS_SECRET_ACCESS_KEY'), isFalse);
        expect(env.containsKey('MISSING'), isFalse);
      },
    );
  });

  group('redactor', () {
    test('masks tokens, private keys, env secrets and paths', () {
      final redactor = PluginRedactor(secrets: ['hunter2-secret']);
      final text = redactor.redact(
        'Authorization: Bearer abcdefgh12345678 key AKIAABCDEFGHIJKLMNOP '
        'pw hunter2-secret at /home/me/project/file.txt and C:\\Users\\me\\x.txt '
        '-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----',
      );
      expect(text, isNot(contains('abcdefgh12345678')));
      expect(text, isNot(contains('AKIAABCDEFGHIJKLMNOP')));
      expect(text, isNot(contains('hunter2-secret')));
      expect(text, isNot(contains('/home/me')));
      expect(text, isNot(contains(r'C:\Users')));
      expect(text, isNot(contains('BEGIN RSA')));
    });

    test('ignores very short secrets that would mangle ordinary text', () {
      expect(
        PluginRedactor(secrets: ['a', '1']).redact('a plain 1 line'),
        'a plain 1 line',
      );
    });
  });
}
