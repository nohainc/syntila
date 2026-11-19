import 'dart:io';

import 'package:syntila_worker_agent/syntila_worker_agent.dart';
import 'package:test/test.dart';

import 'support/recording_runner.dart';

ServiceSpec spec({bool autoStart = false, String? user, String id = 'wrk-1'}) =>
    ServiceSpec(
      workerId: id,
      executable: '/opt/syntila/syntila-worker',
      dataDir: '/data/Syntila/Workers/$id',
      autoStart: autoStart,
      runAsUser: user,
    );

void main() {
  test('every Worker gets its own service name and data directory', () {
    expect(spec(id: 'a').launchdLabel, isNot(spec(id: 'b').launchdLabel));
    expect(spec(id: 'a').systemdName, isNot(spec(id: 'b').systemdName));
    expect(spec(id: 'a').windowsTaskName, isNot(spec(id: 'b').windowsTaskName));
    expect(spec(id: 'a').arguments, contains('/data/Syntila/Workers/a'));
  });

  test('a Worker id cannot inject into a service name', () {
    expect(spec(id: '../../x; rm -rf').safeId, isNot(contains('/')));
    expect(spec(id: 'a b"c').launchdLabel, isNot(contains(' ')));
  });

  group('launchd', () {
    test('auto-start is opt-in', () {
      expect(
        launchdPlist(spec()),
        contains('<key>RunAtLoad</key>\n  <false/>'),
      );
      expect(
        launchdPlist(spec(autoStart: true)),
        contains('<key>RunAtLoad</key>\n  <true/>'),
      );
    });

    test('separate user adds UserName; paths are escaped', () {
      final plist = launchdPlist(spec(user: 'syntila-w1'));
      expect(plist, contains('<key>UserName</key>'));
      final tricky = ServiceSpec(
        workerId: 'w',
        executable: '/a&b/<c>',
        dataDir: '/d',
      );
      expect(launchdPlist(tricky), contains('/a&amp;b/&lt;c&gt;'));
    });

    test(
      'install writes the plist; start/stop/uninstall use launchctl',
      () async {
        final home = await Directory.systemTemp.createTemp('syntila-home-');
        addTearDown(() => home.delete(recursive: true));
        final runner = RecordingRunner();
        final manager = LaunchdServiceManager(
          runner,
          home: home.path,
          uid: 501,
        );
        final s = spec();
        await manager.install(s);
        final plist = File(
          '${home.path}/Library/LaunchAgents/${s.launchdLabel}.plist',
        );
        expect(plist.existsSync(), isTrue);
        expect(
          runner.calls,
          isEmpty,
          reason: 'installing does not start it without opt-in',
        );
        runner.exitCode = 113; // `launchctl print` finds nothing loaded
        expect((await manager.status(s)).state, ServiceState.stopped);
        runner.exitCode = 0;
        await manager.start(s);
        expect(runner.calls.last, [
          'launchctl',
          'bootstrap',
          'gui/501',
          plist.path,
        ]);
        await manager.uninstall(s);
        expect(plist.existsSync(), isFalse);
        expect((await manager.status(s)).state, ServiceState.notInstalled);
      },
    );

    test('auto-start installs and starts', () async {
      final home = await Directory.systemTemp.createTemp('syntila-home-');
      addTearDown(() => home.delete(recursive: true));
      final runner = RecordingRunner();
      await LaunchdServiceManager(
        runner,
        home: home.path,
        uid: 501,
      ).install(spec(autoStart: true));
      expect(runner.calls.single.sublist(0, 2), ['launchctl', 'bootstrap']);
    });
  });

  group('systemd', () {
    test('a unit never enables itself; enabling is the opt-in', () async {
      final home = await Directory.systemTemp.createTemp('syntila-home-');
      addTearDown(() => home.delete(recursive: true));
      final runner = RecordingRunner();
      final manager = SystemdServiceManager(runner, home: home.path);
      final s = spec();
      await manager.install(s);
      final unit = File('${home.path}/.config/systemd/user/${s.systemdName}');
      expect(
        unit.readAsStringSync(),
        contains(
          'ExecStart="/opt/syntila/syntila-worker" "run" "--data-dir" "/data/Syntila/Workers/wrk-1"',
        ),
      );
      expect(
        runner.calls.map((c) => c.join(' ')),
        contains('systemctl --user disable ${s.systemdName}'),
      );
      expect(
        runner.calls.map((c) => c.join(' ')),
        isNot(contains('systemctl --user enable ${s.systemdName}')),
      );
      await manager.install(spec(autoStart: true));
      expect(
        runner.calls.map((c) => c.join(' ')),
        contains('systemctl --user enable ${s.systemdName}'),
      );
      await manager.uninstall(s);
      expect(unit.existsSync(), isFalse);
    });

    test('separate user runs as a system unit with User=', () {
      final unit = systemdUnit(spec(user: 'syntila-w1'));
      expect(unit, contains('User=syntila-w1'));
      expect(unit, contains('WantedBy=multi-user.target'));
      expect(unit, contains('NoNewPrivileges=true'));
      expect(systemdUnit(spec()), contains('WantedBy=default.target'));
    });
  });

  group('windows', () {
    test('values reach the script only as environment variables', () async {
      final runner = RecordingRunner();
      final manager = WindowsServiceManager(runner);
      await manager.install(spec(autoStart: true, id: 'w1'));
      expect(runner.calls.single.first, 'powershell.exe');
      final script = runner.calls.single.last;
      expect(script, isNot(contains('/data/Syntila')));
      expect(script, isNot(contains('w1')));
      final env = runner.environments.single;
      expect(env['SYNTILA_WORKER_TASK'], 'Syntila Worker w1');
      expect(env['SYNTILA_WORKER_AUTOSTART'], 'true');
      expect(env['SYNTILA_WORKER_OPERATION'], 'register');
    });

    test('status is read from the task answer', () async {
      final runner = RecordingRunner()
        ..stdout = '{"registered":true,"running":true,"autoStart":false}';
      final status = await WindowsServiceManager(runner).status(spec());
      expect(status.state, ServiceState.running);
      expect(status.autoStart, isFalse);
    });
  });

  test(
    'the separate OS user plan is printed, never run, and its limits are stated',
    () {
      expect(
        separateUserCommands('linux', 'syntila-w1').single,
        contains('useradd'),
      );
      expect(
        separateUserCommands('macos', 'syntila-w1').single,
        contains('sysadminctl'),
      );
      expect(
        separateUserCommands('windows', 'syntila-w1').first,
        contains('net user'),
      );
      expect(isolationNotes, contains('not isolated'));
      expect(isolationNotes, contains('CPU'));
    },
  );
}
