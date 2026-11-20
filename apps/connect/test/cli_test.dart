import 'dart:convert';
import 'dart:io';

import 'package:syntila_connect/syntila_connect.dart';
import 'package:test/test.dart';

import 'support/fake_cloud.dart';
import 'support/recording_runner.dart';

void main() {
  late FakeCloud cloud;
  late Directory sandbox;
  late RecordingRunner runner;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() async {
    cloud = await FakeCloud.start();
    sandbox = await Directory.systemTemp.createTemp('syntila-cli-');
    await Directory('${sandbox.path}/home').create();
    runner = RecordingRunner();
    out = StringBuffer();
    err = StringBuffer();
  });
  tearDown(() async {
    await cloud.close();
    await sandbox.delete(recursive: true);
  });

  WorkerCli cli({
    String os = 'linux',
    Future<String?> Function()? secretLine,
  }) => WorkerCli(
    readSecretLine: secretLine,
    out: out,
    err: err,
    environment: {
      'HOME': '${sandbox.path}/home',
      'XDG_DATA_HOME': '${sandbox.path}/data',
    },
    operatingSystem: os,
    runner: runner,
    executable: '/opt/syntila/syntila-connect',
  );

  Future<String> pairWorker(
    FakeWorker worker, [
    List<String> extra = const [],
  ]) async {
    final code = cloud.createPairing(worker.id).encode();
    final status = await cli().run(['pair', '--pairing-code', code, ...extra]);
    expect(status, 0, reason: '$err');
    return '${sandbox.path}/data/Syntila/Workers/${worker.id}';
  }

  test(
    'service start, stop, restart, status, install and uninstall drive the installed service',
    () async {
      final worker = cloud.createWorker();
      await pairWorker(worker, ['--no-service']);
      expect(await cli().run(['service', 'start']), 1);
      expect('$err', contains('no background service'));
      err.clear();

      expect(await cli().run(['service', 'install']), 0, reason: '$err');
      out.clear();
      expect(
        await cli().run(['service', 'status', '--json']),
        0,
        reason: '$err',
      );
      final serviceStatus = jsonDecode(out.toString()) as Map<String, Object?>;
      expect(serviceStatus['workerId'], worker.id);

      runner.calls.clear();
      expect(await cli().run(['service', 'stop']), 0, reason: '$err');
      expect(await cli().run(['service', 'start']), 0, reason: '$err');
      expect(await cli().run(['service', 'restart']), 0, reason: '$err');
      final calls = runner.calls.map((c) => c.join(' ')).toList();
      expect(calls.where((c) => c.contains('stop')), isNotEmpty);
      expect(calls.where((c) => c.contains('start')), isNotEmpty);

      expect(await cli().run(['service', 'uninstall']), 0, reason: '$err');
      expect(await cli().run(['service', 'start']), 1);
    },
  );

  test('pair reads the pairing code from standard input', () async {
    final worker = cloud.createWorker();
    final code = cloud.createPairing(worker.id);
    final status = await cli(
      secretLine: () async => '${code.encode()}\n',
    ).run(['pair', '--pairing-code-stdin', '--no-service']);
    expect(status, 0, reason: '$err');
    expect('$out$err', isNot(contains(code.secret)));
    expect(worker.publicKey, isNotNull);
  });

  test('pair refuses an empty stdin and both code sources', () async {
    expect(
      await cli(
        secretLine: () async => '',
      ).run(['pair', '--pairing-code-stdin']),
      2,
    );
    expect(
      await cli(
        secretLine: () async => 'x',
      ).run(['pair', '--pairing-code-stdin', '--pairing-code', 'y']),
      2,
    );
  });

  test(
    'pair writes a service that does not auto-start, and never prints the secret',
    () async {
      final worker = cloud.createWorker();
      final code = cloud.createPairing(worker.id);
      expect(
        await cli().run(['pair', '--pairing-code', code.encode()]),
        0,
        reason: '$err',
      );
      expect('$out$err', isNot(contains(code.secret)));
      expect(out.toString(), contains('does not start by itself'));
      expect(worker.publicKey, isNotNull);
      final unit = File(
        '${sandbox.path}/home/.config/systemd/user/syntila-worker-${worker.id}.service',
      );
      expect(unit.existsSync(), isTrue);
      expect(unit.readAsStringSync(), contains('Syntila/Workers/${worker.id}'));
      expect(
        runner.calls.map((c) => c.join(' ')),
        isNot(
          contains(
            'systemctl --user enable syntila-worker-${worker.id}.service',
          ),
        ),
      );
    },
  );

  test('--auto-start opts in', () async {
    final worker = cloud.createWorker();
    await pairWorker(worker, ['--auto-start']);
    expect(
      runner.calls.map((c) => c.join(' ')),
      contains('systemctl --user enable syntila-worker-${worker.id}.service'),
    );
  });

  test(
    'pair with a refused code fails with a clear message and leaves no service',
    () async {
      final worker = cloud.createWorker();
      final code = cloud.createPairing(worker.id);
      await cli().run([
        'pair',
        '--pairing-code',
        code.encode(),
        '--no-service',
      ]);
      err.clear();
      expect(
        await cli().run([
          'pair',
          '--pairing-code',
          code.encode(),
          '--data-dir',
          '${sandbox.path}/second',
        ]),
        4,
      );
      expect(err.toString(), contains('refused'));
      expect(runner.calls, isEmpty);
    },
  );

  test('a bad pairing code is refused before any network call', () async {
    expect(await cli().run(['pair', '--pairing-code', 'nonsense']), 2);
    expect(await cli().run(['pair']), 2);
  });

  test('status shows the registration and the service, as JSON too', () async {
    final worker = cloud.createWorker();
    await pairWorker(worker);
    runner.exitCode = 3; // systemctl: not active, not enabled
    out.clear();
    expect(await cli().run(['status', '--json']), 0, reason: '$err');
    final status = jsonDecode(out.toString()) as Map<String, Object?>;
    expect(status['workerId'], worker.id);
    expect(status['registration'], 'paired');
    expect(status['running'], isFalse);
    expect(status['connection'], 'stopped');
    expect(status['service'], 'stopped');
    expect(out.toString(), isNot(contains('privateKey')));
  });

  test('config show and set; autoStart reinstalls the service unit', () async {
    final worker = cloud.createWorker();
    await pairWorker(worker);
    out.clear();
    expect(
      await cli().run(['config', 'set', 'maxConcurrent', '2']),
      0,
      reason: '$err',
    );
    expect(await cli().run(['config', 'set', 'maxConcurrent', '99']), 2);
    expect(
      await cli().run(['config', 'set', 'autoStart', 'true']),
      0,
      reason: '$err',
    );
    expect(
      runner.calls.map((c) => c.join(' ')),
      contains('systemctl --user enable syntila-worker-${worker.id}.service'),
    );
    out.clear();
    expect(await cli().run(['config', 'show']), 0);
    expect(jsonDecode(out.toString()), containsPair('maxConcurrent', 2));
  });

  test(
    'folders: add, list, remove, work-root; dangerous folders are refused',
    () async {
      final worker = cloud.createWorker();
      await pairWorker(worker);
      final project = await Directory('${sandbox.path}/home/project').create();
      out.clear();
      expect(
        await cli().run(['folders', 'add', project.path]),
        0,
        reason: '$err',
      );
      final id = out.toString().trim().split(' ').last;
      out.clear();
      expect(await cli().run(['folders', 'list']), 0);
      expect(out.toString(), contains(id));
      expect(await cli().run(['folders', 'add', '${sandbox.path}/home']), 1);
      expect(await cli().run(['folders', 'remove', id]), 0);
      expect(await cli().run(['folders', 'remove', id]), 1);

      final workDir = await Directory('${sandbox.path}/home/work').create();
      expect(
        await cli().run(['folders', 'work-root', workDir.path]),
        0,
        reason: '$err',
      );
      out.clear();
      expect(await cli().run(['folders', 'work-root']), 0, reason: '$err');
      expect(out.toString().trim(), workDir.resolveSymbolicLinksSync());
    },
  );

  test(
    'rotate-credential replaces the key on the server and on disk',
    () async {
      final worker = cloud.createWorker();
      final dir = await pairWorker(worker);
      final before = worker.publicKey;
      expect(await cli().run(['rotate-credential']), 0, reason: '$err');
      expect(worker.publicKey, isNot(before));
      expect(
        (await FileKeyStore(
          File('$dir/identity/key.json'),
        ).load())!.publicKeyText,
        worker.publicKey,
      );
    },
  );

  test('logs reads the Agent log', () async {
    final worker = cloud.createWorker();
    final dir = await pairWorker(worker);
    await File('$dir/traces/agent.log').writeAsString('one\ntwo\nthree\n');
    out.clear();
    expect(await cli().run(['logs', '--lines', '2']), 0);
    expect(out.toString(), 'two\nthree\n');
  });

  test(
    'unpair needs --yes, supports --keep-data, removes private state and the service, keeps work folders',
    () async {
      final worker = cloud.createWorker();
      final dir = await pairWorker(worker);
      final work = await Directory('${sandbox.path}/home/project').create();
      await File('${work.path}/a.txt').writeAsString('mine');
      await cli().run(['folders', 'add', work.path]);
      expect(await cli().run(['unpair']), 2);
      expect(Directory(dir).existsSync(), isTrue);

      // With --keep-data, identity is deleted while config and folder grants stay.
      expect(
        await cli().run(['unpair', '--yes', '--keep-data']),
        0,
        reason: '$err',
      );
      expect(Directory('$dir/identity').existsSync(), isFalse);
      expect(File('$dir/registry/allowed-folders.json').existsSync(), isTrue);

      // Full unpair deletes the data directory.
      expect(await cli().run(['unpair', '--yes']), 0, reason: '$err');
      expect(Directory(dir).existsSync(), isFalse);
      expect(
        File(
          '${sandbox.path}/home/.config/systemd/user/syntila-worker-${worker.id}.service',
        ).existsSync(),
        isFalse,
      );
      expect(File('${work.path}/a.txt').readAsStringSync(), 'mine');
    },
  );

  test(
    'several Workers are listed by status, while targeted commands need --worker',
    () async {
      final a = cloud.createWorker(workerType: 'gemini', name: 'Gemini Dev');
      final b = cloud.createWorker(workerType: 'claude', name: '');
      await pairWorker(a, ['--name', 'My Gemini']);
      await pairWorker(b);
      out.clear();
      expect(await cli().run(['status', '--json']), 0, reason: '$err');
      final all = jsonDecode(out.toString()) as Map<String, Object?>;
      final workers = (all['workers'] as List).cast<Map<String, Object?>>();
      expect(workers, hasLength(2));
      final byId = {for (final w in workers) w['workerId']: w};
      expect(byId[a.id]!['workerName'], 'My Gemini');
      expect(byId[a.id]!['workerType'], 'gemini');
      // When name is empty, falls back to workerType
      expect(byId[b.id]!['workerName'], 'claude');

      expect(await cli().run(['config', 'show']), 2);
      expect(err.toString(), contains('--worker'));
      out.clear();
      expect(
        await cli().run(['status', '--worker', b.id, '--json']),
        0,
        reason: '$err',
      );
      expect(jsonDecode(out.toString()), containsPair('workerId', b.id));

      // Machine-wide mcp-worker commands work without --worker even when several Workers exist.
      out.clear();
      expect(await cli().run(['mcp-worker', 'list']), 0, reason: '$err');
      expect(out.toString(), contains('No MCP Workers'));
    },
  );

  test('help, version and unknown commands', () async {
    expect(await cli().run(['help']), 0);
    expect(out.toString(), contains('pair --pairing-code'));
    out.clear();
    expect(await cli().run(['version']), 0);
    expect(out.toString().trim(), agentVersion);
    out.clear();
    expect(await cli().run(['version', '--json']), 0);
    expect(jsonDecode(out.toString()), containsPair('version', agentVersion));
    expect(await cli().run(['frobnicate']), 2);
  });

  test('a running Agent is seen by status and blocks a second one', () async {
    final worker = cloud.createWorker();
    final dir = await pairWorker(worker);
    final lock = await AgentLock.acquire(File('$dir/agent.lock'));
    addTearDown(lock.release);
    out.clear();
    expect(await cli().run(['status', '--json']), 0, reason: '$err');
    expect(jsonDecode(out.toString()), containsPair('running', true));
    expect(
      await cli().run(['rotate-credential']),
      3,
      reason: 'the data directory is owned by a running Agent',
    );
  });
}
