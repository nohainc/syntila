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
  test('changed Cloud URL blocks login and registration before side effects',
      () async {
    final root = await Directory.systemTemp.createTemp('cli-cloud-config');
    addTearDown(() => root.delete(recursive: true));
    final settings = WorkspaceSettingsStore(root);
    await settings.ensureDefaults();
    final current = settings.readSync()!;
    await settings.write(current.copyWith(cloudUrl: 'http://localhost:8787'));
    final calls = <String>[];
    final err = StringBuffer();
    final out = StringBuffer();
    final cli = WorkspaceCli(
        out: out,
        err: err,
        request: (command, payload) async {
          calls.add(command);
          if (command == 'service.getStatus') {
            return {
              'cloud': {'effectiveUrl': 'https://old.example'}
            };
          }
          return {'ok': true};
        });
    expect(await cli.run(['--data-dir', root.path, 'login']), 1);
    expect(await cli.run(['--data-dir', root.path, 'register']), 1);
    expect(err.toString(), contains('syntila service restart'));
    expect(calls, isNot(contains('connection.disconnect')));
    expect(calls, isNot(contains('auth.register')));
    expect(await cli.run(['--data-dir', root.path, 'status']), 0);
    expect(out.toString(), contains('Cloud config:  Changed'));
  });

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
    expect(calls, [
      'externalWorkers.list {}',
      'workers.list {}',
      'workers.disableWorker {workerId: w-1}',
    ]);
    expect(await cli.run(['workers', 'test', 'codex']), 66);
  });

  test('routes External Workers through the workers commands', () async {
    final calls = <String>[];
    final out = StringBuffer();
    final cli = WorkspaceCli(
      out: out,
      err: StringBuffer(),
      request: (command, payload) async {
        calls.add('$command $payload');
        switch (command) {
          case 'externalWorkers.list':
            return {
              'schemaVersion': 1,
              'plugins': [
                {'pluginId': 'ollama-mcp', 'pluginRef': 'plugin-abc'},
              ],
            };
          case 'externalWorkers.enable' when payload['acceptHash'] == null:
            return {
              'schemaVersion': 1,
              'consentRequired': true,
              'documentHash': 'h1',
              'document': {
                'plugin': {
                  'id': 'ollama-mcp',
                  'version': '1.0.0',
                  'displayName': 'Ollama',
                  'author': 'Syntila',
                },
                'digest': {
                  'manifest': 'm',
                  'artifact': 'a',
                  'platform': 'macos-arm64',
                },
                'requestedAccess': {
                  'subprocess': false,
                  'note': 'Not enforced.'
                },
                'signature': {'status': 'unsigned'},
                'mcp': {
                  'tools': [
                    {'name': 'syntila.execute', 'description': 'Run'},
                  ],
                },
                'statement': 'Runs as you.',
              },
            };
          case 'externalWorkers.enable':
            return {
              'schemaVersion': 1,
              'enabled': true,
              'pluginRef': 'plugin-abc',
              'version': '1.0.0',
            };
          case 'externalWorkers.register':
            return {'pluginRef': 'plugin-abc', 'version': '1.0.0'};
          case 'externalWorkers.show':
            return {
              'pluginId': 'ollama-mcp',
              'pluginRef': 'plugin-abc',
              'displayName': 'Ollama',
              'versions': [],
            };
        }
        return {'schemaVersion': 1};
      },
    );

    expect(await cli.run(['workers', 'enable', 'ollama-mcp']), 3);
    expect(out.toString(), contains('syntila.execute: Run'));
    expect(out.toString(), contains('--accept h1'));
    expect(
      await cli.run(['workers', 'enable', 'plugin-abc', '--accept', 'h1']),
      0,
    );
    expect(out.toString(), contains('Enabled ollama-mcp 1.0.0.'));
    expect(await cli.run(['workers', 'inspect', 'ollama-mcp']), 0);
    expect(await cli.run(['workers', 'register', 'ollama-mcp']), 0);
    expect(out.toString(), contains('Registered ollama-mcp 1.0.0.'));
    expect(await cli.run(['workers', 'show', 'ollama-mcp']), 0);
    expect(out.toString(), isNot(contains('plugin-abc')));
    expect(await cli.run(['workers', 'import', '/tmp/pkg']), 0);
    expect(calls, [
      'externalWorkers.list {}',
      'externalWorkers.enable {externalWorkerId: ollama-mcp}',
      'externalWorkers.list {}',
      'externalWorkers.enable {externalWorkerId: ollama-mcp, acceptHash: h1}',
      'externalWorkers.test {externalWorkerId: ollama-mcp}',
      'externalWorkers.register {externalWorkerId: ollama-mcp}',
      'externalWorkers.show {externalWorkerId: ollama-mcp}',
      'externalWorkers.import {path: /tmp/pkg}',
    ]);
  });

  test('lists and checks an External Worker by its package ID', () async {
    final out = StringBuffer();
    final calls = <String>[];
    final cli = WorkspaceCli(
      out: out,
      err: StringBuffer(),
      request: (command, payload) async {
        calls.add('$command $payload');
        if (command == 'externalWorkers.list') {
          return {
            'plugins': [
              {'pluginId': 'ollama-mcp', 'pluginRef': 'plugin-abc'},
            ],
          };
        }
        final worker = {
          'workerId': 'w-1',
          'productWorkerTypeId': 'plugin-abc',
          'activationState': 'enabled',
          'readinessState': 'ready',
        };
        if (command == 'workers.list') return [worker];
        if (command == 'workers.checkReadiness') {
          return {
            'workers': [worker]
          };
        }
        if (command == 'workers.testWorker') {
          return {...worker, 'lastLiveTestPassed': true};
        }
        return {};
      },
    );
    expect(await cli.run(['workers', 'list']), 0);
    expect(await cli.run(['workers', 'check', 'ollama-mcp']), 0);
    expect(await cli.run(['workers', 'test', 'ollama-mcp']), 0);
    expect(out.toString(), contains('ollama-mcp\tenabled\tready'));
    expect(out.toString(), contains('ollama-mcp: Passed'));
    expect(out.toString(), isNot(contains('plugin-abc')));
    expect(
        calls, contains('workers.checkReadiness {workerTypeId: plugin-abc}'));
    expect(calls, contains('workers.testWorker {workerId: w-1}'));
  });

  test('action summaries preserve JSON and hide worker IDs', () async {
    Future<String> output(List<String> args) async {
      final out = StringBuffer();
      final code = await WorkspaceCli(
        out: out,
        err: StringBuffer(),
        request: (command, payload) async {
          if (command == 'workers.list') {
            return [
              {'workerId': 'secret-id', 'productWorkerTypeId': 'gemini'}
            ];
          }
          if (command.startsWith('workers.')) {
            return {'workerId': 'secret-id', 'state': 'removed'};
          }
          return {'short': 1, 'longFieldName': 2};
        },
      ).run(args);
      expect(code, 0);
      return out.toString();
    }

    for (final entry in <(List<String>, String)>[
      (['assignments'], 'No active assignments.'),
      (
        ['assignments', 'cancel', 'a1'],
        'Cancellation was not requested for a1'
      ),
      (['folders', 'add', '/tmp/project'], 'Folder added:'),
      (['folders', 'remove', 'f1'], 'Folder f1 was not found.'),
    ]) {
      expect(await output(entry.$1), contains(entry.$2));
      expect(await output(['--json', ...entry.$1]),
          contains('"longFieldName": 2'));
    }
    for (final action in ['add', 'remove', 'enable', 'disable']) {
      final text = await output(['workers', action, 'gemini']);
      expect(
          text,
          'gemini ${switch (action) {
            'add' => 'added',
            'remove' => 'removed',
            'enable' => 'enabled',
            _ => 'disabled'
          }}\n');
      expect(text, isNot(contains('secret-id')));
    }
  });

  test('summaries show actionable results and preserve detailed JSON',
      () async {
    final responses = <String, Object?>{
      'workers.list': [
        {
          'workerId': 'id-1',
          'productWorkerTypeId': 'gemini',
          'activationState': 'enabled',
          'readinessState': 'needsAttention',
          'readinessIssueCode': 'not_installed'
        }
      ],
      'workers.checkReadiness': {
        'workers': [
          {
            'productWorkerTypeId': 'gemini',
            'activationState': 'enabled',
            'readinessState': 'needsAttention',
            'readinessIssueCode': 'not_installed'
          }
        ]
      },
      'workers.testWorker': {
        'productWorkerTypeId': 'gemini',
        'lastLiveTestPassed': false,
        'lastLiveTestIssueCode': 'test_failed'
      },
      'workers.removeWorker': {'state': 'removing', 'workerId': 'id-1'},
      'folders.list': {
        'folders': [
          {
            'id': 'f1',
            'displayName': 'Project',
            'path': '/project',
            'status': 'ready',
            'checkedAt': 'internal'
          }
        ]
      },
      'folders.remove': {'removed': true},
      'execution.listActiveAssignments': {
        'activeAssignmentIds': ['a1', 'a2']
      },
      'execution.cancelAssignment': {'cancelled': true},
      'execution.getSlots': {
        'active': 1,
        'queued': 2,
        'limit': 3,
        'workers': [
          {
            'workerId': 'id-1',
            'workerTypeId': 'gemini',
            'active': 1,
            'queued': 2
          }
        ],
        'activeAssignmentIds': ['a1']
      },
      'diagnostics.getMetrics': {
        'processId': 9,
        'residentMemoryBytes': 1048576,
        'cpuPercent': 2.0,
        'sampledAt': 'today',
        'activeAssignments': 1,
        'workerCount': 1,
        'cloudConnected': true,
        'reconnectCount': 0
      },
      'connection.resume': {
        'cloud': {'connected': false, 'acceptingNewWork': false}
      },
    };
    Future<String> runOutput(List<String> args) async {
      final out = StringBuffer();
      expect(
          await WorkspaceCli(
              out: out,
              err: StringBuffer(),
              request: (command, _) async => responses[command]).run(args),
          0);
      return out.toString();
    }

    final workers = await runOutput(['workers']);
    expect(workers, contains('gemini\tenabled\tneedsAttention'));
    expect(workers, contains('not_installed'));
    expect(workers, isNot(contains('id-1')));
    expect(await runOutput(['workers', 'check']), contains('not_installed'));
    expect(await runOutput(['workers', 'test', 'gemini']),
        contains('gemini: Failed'));
    expect(await runOutput(['workers', 'remove', 'gemini']),
        contains('removing after current work'));
    final folders = await runOutput(['folders']);
    expect(
        folders,
        allOf(contains('Project'), contains('/project'), contains('f1'),
            isNot(contains('internal'))));
    expect(await runOutput(['folders', 'remove', 'f1']),
        contains('Files remain on disk'));
    expect(await runOutput(['assignments']), 'a1\na2\n');
    expect(await runOutput(['assignments', 'cancel', 'a1']),
        contains('Cancellation requested for a1'));
    final slots = await runOutput(['slots']);
    expect(
        slots,
        allOf(contains('gemini'), isNot(contains('id-1')),
            isNot(contains('a1'))));
    expect(await runOutput(['metrics']), contains('1.0 MiB'));
    expect(await runOutput(['resume']), contains('Connect to Cloud first'));
    expect(jsonDecode(await runOutput(['--json', 'slots'])),
        responses['execution.getSlots']);
  });

  test('reset retains runtime files when service stop fails', () async {
    final root = await Directory.systemTemp.createTemp('reset-stop-failure');
    addTearDown(() => root.delete(recursive: true));
    final config = File('${root.path}/workspace.nano')
      ..writeAsStringSync('preserve');
    final err = StringBuffer();
    final result = await WorkspaceCli(
      out: StringBuffer(),
      err: err,
      hostManager: (_) => const UnsupportedWorkspaceServiceManager(),
    ).run(['--data-dir', root.path, 'reset']);
    expect(result, 1);
    expect(err.toString(), contains('Reset incomplete'));
    expect(config.readAsStringSync(), 'preserve');
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
      'externalWorkers.list {}',
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
            throw const SocketException('down'),
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

  test('login accepts an email and reads the password from stdin', () async {
    final root = Directory.systemTemp.createTempSync('cli-login-stdin');
    addTearDown(() => root.deleteSync(recursive: true));
    final out = StringBuffer(), err = StringBuffer();
    final code = await WorkspaceCli(
      out: out,
      err: err,
      readLine: (_) => 'private-password',
      authClientFactory: (_) => _FakeAuthClient(),
      credentialStore: _MemoryCredentials(),
    ).run([
      '--data-dir',
      root.path,
      'login',
      '--email',
      'user@example.test',
      '--password-stdin'
    ]);
    expect(code, 0);
    expect(out.toString(), contains('Signed in.'));
    expect('$out$err', isNot(contains('private-password')));
  });

  test('connect waits for readiness and reports failure on timeout', () async {
    final root = Directory.systemTemp.createTempSync('cli-connect');
    addTearDown(() => root.deleteSync(recursive: true));
    var polls = 0;
    final out = StringBuffer(), err = StringBuffer();
    final code = await WorkspaceCli(
      out: out,
      err: err,
      connectPollInterval: Duration.zero,
      request: (command, _) async {
        if (command == 'service.getStatus') polls++;
        return {
          'cloud': {
            'connected': polls >= 2,
            'connectionStage': polls >= 2 ? 'ready' : 'synchronizing'
          }
        };
      },
    ).run(['--data-dir', root.path, 'connect']);
    expect(code, 0);
    expect(polls, 2);
    expect(out.toString(), 'Connected\n');
    final failureErr = StringBuffer();
    final failure = await WorkspaceCli(
      out: StringBuffer(),
      err: failureErr,
      connectTimeout: Duration.zero,
      request: (_, __) async => {
        'cloud': {
          'connected': false,
          'connectionStage': 'offline',
          'lastError': 'unavailable'
        }
      },
    ).run(['--data-dir', root.path, 'connect']);
    expect(failure, 1);
    expect(failureErr.toString(), contains('not connected'));
  });

  test('connection actions print concise success messages', () async {
    for (final entry in {
      'disconnect': 'Disconnected',
      'pause': 'Paused (not accepting new work)',
      'resume': 'Resumed (accepting work)',
    }.entries) {
      final out = StringBuffer();
      final root = Directory.systemTemp.createTempSync('cli-action');
      try {
        expect(
            await WorkspaceCli(
                out: out,
                err: StringBuffer(),
                request: (_, __) async => {
                      'cloud': {'acceptingNewWork': true}
                    }).run(['--data-dir', root.path, entry.key]),
            0);
        expect(out.toString(), '${entry.value}\n');
      } finally {
        root.deleteSync(recursive: true);
      }
    }
  });

  test('metrics and slots use tab-separated fields while --json remains JSON',
      () async {
    for (final command in ['metrics', 'slots']) {
      final out = StringBuffer();
      final code = await WorkspaceCli(
        out: out,
        err: StringBuffer(),
        request: (_, __) async => {'count': 3, 'ready': true},
      ).run([command]);
      expect(code, 0);
      expect(out.toString(),
          contains(command == 'metrics' ? 'Process ID' : 'active'));
      final jsonOut = StringBuffer();
      expect(
          await WorkspaceCli(
            out: jsonOut,
            err: StringBuffer(),
            request: (_, __) async => {'count': 3},
          ).run(['--json', command]),
          0);
      expect(jsonDecode(jsonOut.toString()), {'count': 3});
    }
  });

  test('slots summarizes capacity and worker use', () async {
    final out = StringBuffer();
    final result = {
      'limit': null,
      'workers': [
        {'workerId': 'w1', 'active': 2},
      ],
      'activeAssignmentIds': <String>[]
    };
    expect(
        await WorkspaceCli(
            out: out,
            err: StringBuffer(),
            request: (_, __) async => result).run(['slots']),
        0);
    expect(out.toString(),
        'active\t0\nqueued\t0\nlimit\tunknown\n\nworker\tunknown\nactive\t2\nqueued\t0\n');
  });

  test('logs preserve lines and retain JSON output', () async {
    Future<Object?> request(String _, Map<String, Object?> __) async =>
        {'text': 'first entry\nsecond entry\n'};
    final out = StringBuffer();
    expect(
        await WorkspaceCli(out: out, err: StringBuffer(), request: request)
            .run(['logs']),
        0);
    expect(out.toString(), 'first entry\nsecond entry\n');
    final jsonOut = StringBuffer();
    expect(
        await WorkspaceCli(out: jsonOut, err: StringBuffer(), request: request)
            .run(['--json', 'logs']),
        0);
    expect(jsonDecode(jsonOut.toString()),
        {'text': 'first entry\nsecond entry\n'});
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
      final output = StringBuffer();
      final code = await WorkspaceCli(
        out: output,
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
      expect(output.toString(), isNot(contains('Hint:')));
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

    test('setup with stdin credentials does not prompt for the workspace name',
        () async {
      final questions = <String>[];
      final err = StringBuffer();
      final code = await WorkspaceCli(
        out: StringBuffer(),
        err: err,
        readLine: (question) {
          questions.add(question);
          return '';
        },
        hostManager: hostManager(active: false),
        request: (_, __) async => throw const SocketException('down'),
      ).run([
        '--data-dir',
        '${root.path}/state',
        'setup',
        '--name',
        'Build Server',
        '--email',
        'test@example.com',
        '--password-stdin'
      ]);
      expect(code, 64);
      expect(questions, ['']);
      expect(err.toString(), contains('Cloud email and password are required'));
      expect(
          WorkspaceSettingsStore(Directory('${root.path}/state'))
              .readSync()!
              .workspaceName,
          'Build Server');
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
      expect(validated.$2, contains('Restart the service to apply changes'));
      expect(validated.$2, isNot(contains('{')));
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
          request: (c, p) async => c == 'connection.connect'
              ? {
                  'cloud': {'connected': true, 'connectionStage': 'ready'}
                }
              : {'ok': true},
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

      // Reset must retain local registration when Cloud refuses release.
      final resetFailure = StringBuffer();
      final failedReset = await WorkspaceCli(
        out: StringBuffer(),
        err: resetFailure,
        authClientFactory: (_) => client,
        credentialStore: store,
        request: (c, p) async => {'ok': true},
      ).run(['--data-dir', root.path, 'reset']);
      expect(failedReset, 1);
      expect(resetFailure.toString(), contains('Reset incomplete'));
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
      expect(outUnreg.toString(), isNot(contains('Hint:')));
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
      expect(outReset.toString(), 'Workspace reset.\n');
      expect(errReset.toString(), isEmpty);
    });
  });
}
