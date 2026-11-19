import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_agent/syntila_worker_agent.dart';
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

  WorkerCli cli({String os = 'linux'}) => WorkerCli(
    out: out,
    err: err,
    environment: {
      'HOME': '${sandbox.path}/home',
      'XDG_DATA_HOME': '${sandbox.path}/data',
    },
    operatingSystem: os,
    runner: runner,
    executable: '/opt/syntila/syntila-worker',
  );

  Future<String> install(
    FakeWorker worker, [
    List<String> extra = const [],
  ]) async {
    final code = cloud.createPairing(worker.id).encode();
    final status = await cli().run([
      'install',
      '--pairing-code',
      code,
      ...extra,
    ]);
    expect(status, 0, reason: '$err');
    return '${sandbox.path}/data/Syntila/Workers/${worker.id}';
  }

  test(
    'install pairs, writes a service that does not auto-start, and never prints the secret',
    () async {
      final worker = cloud.createWorker();
      final code = cloud.createPairing(worker.id);
      expect(
        await cli().run(['install', '--pairing-code', code.encode()]),
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
    await install(worker, ['--auto-start']);
    expect(
      runner.calls.map((c) => c.join(' ')),
      contains('systemctl --user enable syntila-worker-${worker.id}.service'),
    );
  });

  test(
    'install with a refused code fails with a clear message and leaves no service',
    () async {
      final worker = cloud.createWorker();
      final code = cloud.createPairing(worker.id);
      await cli().run([
        'install',
        '--pairing-code',
        code.encode(),
        '--no-service',
      ]);
      err.clear();
      expect(
        await cli().run([
          'install',
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
    expect(await cli().run(['install', '--pairing-code', 'nonsense']), 2);
    expect(await cli().run(['install']), 2);
  });

  test('status shows the registration and the service, as JSON too', () async {
    final worker = cloud.createWorker();
    await install(worker);
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
    await install(worker);
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
    'permissions: add, list, remove; dangerous folders are refused',
    () async {
      final worker = cloud.createWorker();
      await install(worker);
      final project = await Directory('${sandbox.path}/home/project').create();
      out.clear();
      expect(
        await cli().run(['permissions', 'add-folder', project.path]),
        0,
        reason: '$err',
      );
      final id = out.toString().trim().split(' ').last;
      out.clear();
      expect(await cli().run(['permissions', 'list']), 0);
      expect(out.toString(), contains(id));
      expect(
        await cli().run(['permissions', 'add-folder', '${sandbox.path}/home']),
        1,
      );
      expect(await cli().run(['permissions', 'remove-folder', id]), 0);
      expect(await cli().run(['permissions', 'remove-folder', id]), 1);
    },
  );

  test(
    'rotate-credential replaces the key on the server and on disk',
    () async {
      final worker = cloud.createWorker();
      final dir = await install(worker);
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
    final dir = await install(worker);
    await File('$dir/traces/agent.log').writeAsString('one\ntwo\nthree\n');
    out.clear();
    expect(await cli().run(['logs', '--lines', '2']), 0);
    expect(out.toString(), 'two\nthree\n');
  });

  test(
    'uninstall needs --yes, removes private state and the service, keeps work folders',
    () async {
      final worker = cloud.createWorker();
      final dir = await install(worker);
      final work = await Directory('${sandbox.path}/home/project').create();
      await File('${work.path}/a.txt').writeAsString('mine');
      expect(await cli().run(['uninstall']), 2);
      expect(Directory(dir).existsSync(), isTrue);
      expect(await cli().run(['uninstall', '--yes']), 0, reason: '$err');
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

  test('several Workers need an explicit choice; --worker picks one', () async {
    final a = cloud.createWorker();
    final b = cloud.createWorker();
    await install(a);
    await install(b);
    expect(await cli().run(['status']), 2);
    expect(err.toString(), contains('--worker'));
    out.clear();
    expect(
      await cli().run(['status', '--worker', b.id, '--json']),
      0,
      reason: '$err',
    );
    expect(jsonDecode(out.toString()), containsPair('workerId', b.id));
  });

  test('help and unknown commands', () async {
    expect(await cli().run(['help']), 0);
    expect(out.toString(), contains('install --pairing-code'));
    expect(await cli().run(['frobnicate']), 2);
  });

  test('a running Agent is seen by status and blocks a second one', () async {
    final worker = cloud.createWorker();
    final dir = await install(worker);
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
