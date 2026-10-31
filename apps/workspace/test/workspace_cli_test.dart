import 'dart:io';
import 'dart:convert';

import 'package:syntila_workspace/desktop_auth.dart';
import 'package:syntila_workspace/secure_credentials.dart';
import 'package:syntila_workspace/workspace_cli.dart';
import 'package:syntila_workspace/linux_service_manager.dart';
import 'package:syntila_workspace/workspace_background_service.dart';
import 'package:syntila_workspace/workspace_configuration.dart';
import 'package:syntila_workspace/workspace_lifecycle_store.dart';
import 'package:syntila_workspace/workspace_settings.dart';
import 'package:test/test.dart';

class _MemoryCredentials implements SecureCredentialStore {
  final values = <String, String>{};
  @override
  String? readSync(String key) => values[key];
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _FakeAuthClient extends DesktopAuthClient {
  _FakeAuthClient({this.failPassword = false})
      : super(cloudUrl: 'https://example.test');
  final bool failPassword;
  @override
  Future<DesktopHumanSession> signInWithPassword(String email, String password,
      {String? deviceId}) async {
    if (failPassword) {
      throw const DesktopPasswordSignInException(401);
    }
    expect(email, 'user@example.test');
    expect(password, 'private-password');
    return DesktopHumanSession(
      credential: 'private-human-token',
      sessionId: 'session',
      userId: 'user',
      displayName: 'User',
      email: email,
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<void> validateSession(DesktopHumanSession session) async {}

  String? releaseError;
  int releases = 0;
  @override
  Future<void> releaseWorkspace({
    required DesktopHumanSession session,
    required String installationId,
    required String workspaceId,
    required String runtimeId,
  }) async {
    releases++;
    if (releaseError != null) throw StateError(releaseError!);
  }
}

void main() {
  Future<(int, String, String, List<String>)> run(List<String> args) async {
    final out = StringBuffer(), err = StringBuffer(), calls = <String>[];
    final code = await WorkspaceCli(
      out: out,
      err: err,
      request: (command, payload) async {
        calls.add('$command $payload');
        return {'ok': true};
      },
    ).run(args);
    return (code, out.toString(), err.toString(), calls);
  }

  test('addresses Workers by type', () async {
    final calls = <String>[];
    final cli = WorkspaceCli(
      out: StringBuffer(),
      err: StringBuffer(),
      request: (command, payload) async {
        calls.add('$command $payload');
        if (command == 'workers.list') {
          return [
            {'workerId': 'w-1', 'productWorkerTypeId': 'gemini'},
          ];
        }
        return {'workerId': 'w-1'};
      },
    );
    expect(await cli.run(['workers', 'disable', 'gemini']), 0);
    expect(calls, ['workers.list {}', 'workers.disableWorker {workerId: w-1}']);
    expect(await cli.run(['workers', 'test', 'codex']), 66);
  });

  test('maps commands to IPC requests', () async {
    expect((await run(['--json', 'status'])).$4, ['service.getStatus {}']);
    expect((await run(['workers', 'test', 'w1'])).$4, [
      'workers.list {}',
      'workers.testWorker {workerId: w1}',
    ]);
    expect((await run(['--json', 'assignments', 'cancel', 'a1'])).$4, [
      'execution.cancelAssignment {assignmentId: a1}',
    ]);
    expect((await run(['folders', 'list'])).$4, ['folders.list {}']);
    expect(
        (await run(['folders', 'add', '/path/to/project', '--name', 'MyProj']))
            .$4,
        [
          'folders.add {path: /path/to/project, displayName: MyProj}',
        ]);
    expect((await run(['folders', 'remove', 'folder-123'])).$4, [
      'folders.remove {folderId: folder-123}',
    ]);
    expect((await run(['workers', 'catalog'])).$4, [
      'workers.getCatalogSnapshot {}',
    ]);
    expect((await run(['workers', 'add', 'gemini'])).$4, [
      'workers.configureWorker {workerTypeId: gemini}',
    ]);
    expect((await run(['workers', 'remove', 'w1'])).$4, [
      'workers.list {}',
      'workers.removeWorker {workerId: w1}',
    ]);
  });

  test(
    'login stores only the session and never prints credentials',
    () async {
      final root = Directory.systemTemp.createTempSync('cli-login');
      addTearDown(() => root.deleteSync(recursive: true));
      final store = _MemoryCredentials();
      final out = StringBuffer(), err = StringBuffer();
      final code = await WorkspaceCli(
        out: out,
        err: err,
        readCredentials: () =>
            (email: 'user@example.test', password: 'private-password'),
        authClientFactory: (_) => _FakeAuthClient(),
        credentialStore: store,
        request: (command, payload) async =>
            fail('login must not need the service: $command'),
      ).run(['--data-dir', root.path, 'login']);
      expect(code, 0);
      expect(out.toString().trim(), 'Signed in.');
      expect(store.values.keys, [desktopHumanCredentialKey]);
      expect(File('${root.path}/workspace-registration.json').existsSync(),
          isFalse);
      expect('$out$err', isNot(contains('private-password')));
      expect('$out$err', isNot(contains('user@example.test')));
    },
  );

  test('login --password accepts alias and prints json failure on error',
      () async {
    final root = Directory.systemTemp.createTempSync('cli-login-fail');
    addTearDown(() => root.deleteSync(recursive: true));
    final store = _MemoryCredentials();
    final out = StringBuffer(), err = StringBuffer();
    final code = await WorkspaceCli(
      out: out,
      err: err,
      readCredentials: () =>
          (email: 'bad@example.test', password: 'bad-password'),
      authClientFactory: (_) => _FakeAuthClient(failPassword: true),
      credentialStore: store,
    ).run(['--data-dir', root.path, 'login', '--password']);
    expect(code, 1);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json['phase'], 'failed');
    expect(json['stage'], 'password_sign_in');
  });

  test('register without a stored sign-in asks to run login', () async {
    final root = Directory.systemTemp.createTempSync('cli-register');
    addTearDown(() => root.deleteSync(recursive: true));
    final err = StringBuffer();
    final code = await WorkspaceCli(
      out: StringBuffer(),
      err: err,
      authClientFactory: (_) => _FakeAuthClient(),
      credentialStore: _MemoryCredentials(),
      request: (_, __) async => throw const SocketException('down'),
    ).run(['--data-dir', root.path, 'register']);
    expect(code, 1);
    expect(err.toString(), contains('syntila login'));
  });

  test(
    'service install uses the Linux host adapter and never calls Cloud',
    () async {
      final root = await Directory.systemTemp.createTemp('cli-host-');
      addTearDown(() => root.delete(recursive: true));
      final executable = File('${root.path}/workspace')
        ..writeAsStringSync('fixture');
      final systemctl = <List<String>>[];
      final code = await WorkspaceCli(
        out: StringBuffer(),
        err: StringBuffer(),
        request: (_, __) async => fail('install must not call IPC'),
        hostManager: (state) => LinuxWorkspaceServiceManager(
          dataDirectory: state,
          executable: executable,
          unitDirectory: Directory('${root.path}/units'),
          systemctl: (args) async {
            systemctl.add(args);
            return ProcessResult(
              0,
              0,
              'UnitFileState=enabled\nActiveState=inactive',
              '',
            );
          },
        ),
      ).run(['--data-dir', '${root.path}/state', 'service', 'install']);
      expect(code, 0);
      expect(systemctl[0], ['daemon-reload']);
      expect(systemctl[1].first, 'enable');
      expect(Directory('${root.path}/units').listSync(), hasLength(1));
    },
  );

  group('setup', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('cli-setup-'));
    tearDown(() => root.deleteSync(recursive: true));

    WorkspaceServiceManager Function(Directory) hostManager({
      required bool active,
    }) =>
        (state) => LinuxWorkspaceServiceManager(
              dataDirectory: state,
              executable: File('${root.path}/workspace'),
              unitDirectory: Directory('${root.path}/units'),
              systemctl: (args) async => ProcessResult(
                0,
                0,
                'UnitFileState=enabled\nActiveState='
                    '${active ? 'active\nMainPID=1' : 'inactive'}',
                '',
              ),
            );

    test('is interrupted when the service is already running', () async {
      final err = StringBuffer();
      var asked = false;
      final code = await WorkspaceCli(
        out: StringBuffer(),
        err: err,
        readLine: (_) {
          asked = true;
          return '';
        },
        hostManager: hostManager(active: true),
        request: (command, _) async => {'healthy': true},
      ).run(['--data-dir', '${root.path}/state', 'setup']);
      expect(code, 1);
      expect(asked, isFalse);
      expect(err.toString(), contains('already running'));
      expect(File('${root.path}/state/workspace.nano').existsSync(), isFalse);
    });

    test('creates the config, asks for the name, then signs in', () async {
      final questions = <String>[];
      final out = StringBuffer(), err = StringBuffer();
      final code = await WorkspaceCli(
        out: out,
        err: err,
        readLine: (question) {
          questions.add(question);
          return 'Build Server';
        },
        // Empty credentials stop the flow before any network call.
        readCredentials: () => (email: '', password: ''),
        hostManager: hostManager(active: false),
        request: (_, __) async => throw const SocketException('down'),
      ).run(['--data-dir', '${root.path}/state', 'setup']);
      expect(code, 64);
      expect(out.toString(), contains('Config created:'));
      expect(questions, hasLength(1));
      expect(questions.single, startsWith('Workspace name ['));
      final settings =
          WorkspaceSettingsStore(Directory('${root.path}/state')).readSync()!;
      expect(settings.workspaceName, 'Build Server');
      expect(
        WorkspaceLifecyclePreferencesStore(Directory('${root.path}/state'))
            .readSync()
            .customWorkspaceName,
        'Build Server',
      );
    });
  });

  test('rejects excess arguments', () async {
    for (final args in [
      ['status', 'extra'],
      ['workers', 'test', 'w', 'extra'],
      ['login', 'extra'],
    ]) {
      expect((await run(args)).$1, 64);
    }
  });

  test('rejects unknown commands with usage', () async {
    final result = await run(['bogus']);
    expect(result.$1, 64);
    expect(result.$3, contains('Usage:'));
    expect(result.$4, isEmpty);
  });

  group('help visibility', () {
    List<String> commandNames(String text) => [
          for (final line in text.split('\n'))
            if (line.startsWith('  ') && !line.startsWith('   '))
              line.trim().split(RegExp(r'\s+')).first,
        ];

    test('lists only the first-run commands without workspace.nano', () {
      final names = commandNames(
        WorkspaceCli.usageText(configExists: false),
      ).toSet();
      expect(names, {'config', 'reset', 'setup', 'status', 'version'});
    });

    test('lists every command once workspace.nano exists, sorted', () {
      final names = commandNames(WorkspaceCli.usageText(configExists: true));
      final unique = names.toSet().toList()..sort();
      expect(unique, containsAll(['service', 'workers', 'slots', 'folders']));
      expect(unique.length, greaterThan(7));
      // First occurrence of each command follows alphabetical order.
      final firstSeen = <String>[];
      for (final name in names) {
        if (!firstSeen.contains(name)) firstSeen.add(name);
      }
      expect(firstSeen, [...firstSeen]..sort());
    });

    test('--help --all lists everything even without workspace.nano', () {
      expect(
        WorkspaceCli.usageText(configExists: false, all: true),
        equals(WorkspaceCli.usageText(configExists: true)),
      );
    });

    test('help does not depend on the service being reachable', () async {
      final dir = Directory.systemTemp.createTempSync('cli-help');
      addTearDown(() => dir.deleteSync(recursive: true));
      final out = StringBuffer();
      final code = await WorkspaceCli(
        out: out,
        err: StringBuffer(),
        request: (_, __) async => throw StateError('service must not be used'),
      ).run(['--data-dir', dir.path, '--help']);
      expect(code, 0);
      expect(out.toString(), isNot(contains('workers')));
      expect(out.toString(), contains('config init'));
    });
  });

  group('service stopped', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('cli-down'));
    tearDown(() => root.deleteSync(recursive: true));

    Future<(int, String, String)> runDown(List<String> args) async {
      final out = StringBuffer(), err = StringBuffer();
      final code = await WorkspaceCli(
        out: out,
        err: err,
        hostManager: (state) => LinuxWorkspaceServiceManager(
          dataDirectory: state,
          executable: File('/bin/syntila'),
          unitDirectory: Directory('${root.path}/units'),
          systemctl: (args) async => ProcessResult(
            0,
            0,
            'UnitFileState=enabled\nActiveState=inactive',
            '',
          ),
        ),
        request: (_, __) async => throw const SocketException('down'),
      ).run(['--data-dir', '${root.path}/state', ...args]);
      return (code, out.toString(), err.toString());
    }

    test('version works locally', () async {
      final version = (await runDown(['version'])).$2.trim();
      expect(version, isNotEmpty);
      expect(version, isNot(contains('{')));
    });

    test('login status/cancel no longer exist', () async {
      for (final args in [
        ['login', 'status'],
        ['login', 'cancel'],
      ]) {
        final result = await runDown(args);
        expect(result.$1, 64);
        expect(result.$3, contains('Usage:'));
      }
    });

    test('health and updates commands no longer exist', () async {
      for (final command in ['health', 'updates']) {
        final result = await runDown([command]);
        expect(result.$1, 64);
        expect(result.$3, contains('Usage:'));
      }
    });

    test('status summarizes local state and exits 0', () async {
      final result = await runDown(['status']);
      expect(result.$1, 0);
      expect(result.$2, contains('Config:        Missing'));
      expect(result.$2, contains('Not registered'));
      expect(result.$2, isNot(contains('Hint')));
    });

    test('status validates an existing config file', () async {
      final state = Directory('${root.path}/state')
        ..createSync(recursive: true);
      await WorkspaceSettingsStore(state).ensureDefaults();
      var result = await runDown(['status']);
      expect(result.$1, 0);
      expect(result.$2, contains('Config:        Valid'));

      final file = WorkspaceSettingsStore(state).file;
      file.writeAsStringSync(
        file.readAsStringSync().replaceFirst(
            RegExp(r'connect_on_start \w+'), 'connect_on_start maybe'),
      );
      result = await runDown(['status']);
      expect(result.$1, 0);
      expect(result.$2, contains('Config:        Invalid'));
      expect(result.$2, contains('connect_on_start'));
      final json = await runDown(['--json', 'status']);
      expect(json.$2, contains('"state": "invalid"'));
    });

    test('commands that need the service still say so', () async {
      for (final args in [
        ['workers'],
        ['connect'],
      ]) {
        final result = await runDown(args);
        expect(result.$1, 69);
        expect(result.$3, contains('syntila setup'));
      }
    });

    test('with a config file the hint is to start the service', () async {
      Directory('${root.path}/state').createSync(recursive: true);
      File('${root.path}/state/workspace.nano').writeAsStringSync('x');
      final result = await runDown(['workers']);
      expect(result.$1, 69);
      expect(result.$3, contains('service start'));
    });

    test('login without a service asks for credentials and stays local',
        () async {
      final err = StringBuffer();
      final code = await WorkspaceCli(
        out: StringBuffer(),
        err: err,
        readCredentials: () => (email: '', password: ''),
        request: (_, __) async => throw const SocketException('down'),
      ).run(['--data-dir', '${root.path}/state', 'login']);
      expect(code, 64);
      expect(err.toString(), contains('required'));
    });
  });

  group('logout', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('cli-logout'));
    tearDown(() => root.deleteSync(recursive: true));

    test('reports when there is no stored session', () async {
      final out = StringBuffer();
      final code = await WorkspaceCli(
        out: out,
        err: StringBuffer(),
        credentialStore: _MemoryCredentials(),
      ).run(['--data-dir', root.path, 'logout']);
      expect(code, 0);
      expect(out.toString().trim(), 'Not signed in.');
    });

    test('deletes the stored session', () async {
      final store = _MemoryCredentials()
        ..values[desktopHumanCredentialKey] = jsonEncode({'any': 'value'});
      final out = StringBuffer();
      final code = await WorkspaceCli(
        out: out,
        err: StringBuffer(),
        credentialStore: store,
      ).run(['--data-dir', root.path, 'logout']);
      expect(code, 0);
      expect(out.toString().trim(), 'Signed out.');
      expect(store.values, isEmpty);
    });
  });

  group('config init', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('cli-init'));
    tearDown(() => root.deleteSync(recursive: true));

    Future<(int, String)> init() async {
      final out = StringBuffer();
      final code = await WorkspaceCli(out: out, err: StringBuffer())
          .run(['--data-dir', root.path, 'config', 'init']);
      return (code, out.toString().trim());
    }

    test('prints just the path when it creates the file', () async {
      final result = await init();
      expect(result.$1, 0);
      expect(result.$2, endsWith('workspace.nano'));
      expect(result.$2, isNot(contains('valid')));
    });

    test('leaves an existing file untouched', () async {
      final file = File('${root.path}/workspace.nano')
        ..writeAsStringSync('keep me');
      final result = await init();
      expect(result.$1, 0);
      expect(result.$2, startsWith('Config already exists:'));
      expect(file.readAsStringSync(), 'keep me');
    });
  });

  group('workspace.nano', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('cli-config-'));
    tearDown(() => root.deleteSync(recursive: true));

    Future<(int, String, String)> config(List<String> args) async {
      final out = StringBuffer(), err = StringBuffer();
      final code = await WorkspaceCli(
        out: out,
        err: err,
        request: (command, payload) async => {'ok': true},
      ).run(['--data-dir', root.path, 'config', ...args]);
      return (code, out.toString(), err.toString());
    }

    test('config show fails before init, then init/show/validate/path work',
        () async {
      expect((await config(['show'])).$1, 66);
      expect((await config(['init'])).$1, 0);
      final shown = await config(['show']);
      expect(shown.$1, 0);
      expect(shown.$2, contains('connect_on_start'));
      // Parallel slots are set on the web Workspaces page.
      expect(shown.$2, isNot(contains('parallel_slots')));
      final validated = await config(['validate']);
      expect(validated.$1, 0);
      expect(validated.$2, contains('restartRequiredToApply'));
      final path = await config(['path']);
      expect(path.$2.trim(), endsWith('workspace.nano'));
    });

    test('config validate rejects an invalid file with exit code 65', () async {
      await WorkspaceSettingsStore(root).ensureDefaults();
      final file = WorkspaceSettingsStore(root).file;
      file.writeAsStringSync(
        file.readAsStringSync().replaceFirst(
            RegExp(r'connect_on_start \w+'), 'connect_on_start maybe'),
      );
      expect((await config(['validate'])).$1, 65);
    });

    test('rejects unknown config actions', () async {
      expect((await config(['bogus'])).$1, 64);
    });

    test('connect and disconnect persist connect_on_start', () async {
      Future<void> send(String command) async {
        final code = await WorkspaceCli(
          out: StringBuffer(),
          err: StringBuffer(),
          request: (c, p) async => {'ok': true},
        ).run(['--data-dir', root.path, command]);
        expect(code, 0);
      }

      await send('connect');
      expect(WorkspaceSettingsStore(root).readSync()!.connectOnStart, isTrue);
      await send('disconnect');
      expect(WorkspaceSettingsStore(root).readSync()!.connectOnStart, isFalse);
    });

    test('work-dir displays and updates work root', () async {
      await WorkspaceSettingsStore(root).ensureDefaults();
      final out1 = StringBuffer(), err1 = StringBuffer();
      final code1 = await WorkspaceCli(
        out: out1,
        err: err1,
      ).run(['--data-dir', root.path, 'work-dir']);
      expect(code1, 0);
      expect(out1.toString().trim(), isNotEmpty);

      final newWorkPath = Directory('${root.path}/custom-work').path;
      final out2 = StringBuffer(), err2 = StringBuffer();
      final code2 = await WorkspaceCli(
        out: out2,
        err: err2,
      ).run(['--data-dir', root.path, 'work-dir', newWorkPath]);
      expect(code2, 0);
      expect(out2.toString(), contains('Work Root updated to'));

      final out3 = StringBuffer(), err3 = StringBuffer();
      final code3 = await WorkspaceCli(
        out: out3,
        err: err3,
      ).run(['--data-dir', root.path, 'work-dir']);
      expect(code3, 0);
      expect(out3.toString().trim(), equals(newWorkPath));
    });

    test('unregister releases in Cloud, then forgets only the registration',
        () async {
      final regStore = WorkspaceRegistrationStore(root);
      await regStore.write(const WorkspaceRegistration(
        workspaceRuntimeId: 'rt-1',
        workspaceId: 'ws-1',
        cloudUrl: 'https://syntila.test',
        name: 'Test WS',
        hostname: 'testhost',
        installationId: 'inst-1',
      ));
      expect(regStore.readSync(), isNotNull);
      final workersFile = File('${root.path}/configured-workers.json')
        ..writeAsStringSync('{}');
      final store = _MemoryCredentials()
        ..values[desktopHumanCredentialKey] = jsonEncode(DesktopHumanSession(
          credential: 'token',
          sessionId: 'session',
          userId: 'user',
          displayName: 'User',
          email: 'user@example.test',
          issuedAt: DateTime.now(),
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ).toSecureJson());
      final client = _FakeAuthClient()..releaseError = 'runtime still online';

      // Cloud refuses: nothing changes locally.
      final errRefused = StringBuffer();
      var code = await WorkspaceCli(
        out: StringBuffer(),
        err: errRefused,
        authClientFactory: (_) => client,
        credentialStore: store,
        request: (c, p) async => {'ok': true},
      ).run(['--data-dir', root.path, 'unregister']);
      expect(code, 1);
      expect(errRefused.toString(), contains('runtime still online'));
      expect(regStore.readSync(), isNotNull);
      expect(workersFile.existsSync(), isTrue);

      // Cloud accepts: local state is cleared.
      client.releaseError = null;
      final outUnreg = StringBuffer(), errUnreg = StringBuffer();
      code = await WorkspaceCli(
        out: outUnreg,
        err: errUnreg,
        authClientFactory: (_) => client,
        credentialStore: store,
        request: (c, p) async => {'ok': true},
      ).run(['--data-dir', root.path, 'unregister']);
      expect(code, 0);
      expect(outUnreg.toString(), contains('unregistered'));
      expect(outUnreg.toString(), isNot(contains('ws-1')));
      expect(regStore.readSync(), isNull);
      // Local setup is kept for the next registration.
      expect(workersFile.existsSync(), isTrue);

      final outReset = StringBuffer(), errReset = StringBuffer();
      final resetCode = await WorkspaceCli(
        out: outReset,
        err: errReset,
        request: (c, p) async => {'ok': true},
      ).run(['--data-dir', root.path, 'reset']);
      expect(resetCode, 0);
      expect(outReset.toString(), isEmpty);
      expect(errReset.toString(), isEmpty);
    });
  });
}
