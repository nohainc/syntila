import 'dart:convert';
import 'dart:io';

import 'package:syntila_workspace/plugin_service.dart'
    show pluginConsentStatement;
import 'package:syntila_workspace/workspace_cli.dart';
import 'package:syntila_workspace/workspace_manager_ipc.dart';
import 'package:syntila_workspace/workspace_manager_plugins.dart';
import 'package:test/test.dart';

import 'support/plugin_fakes.dart';
import 'support/plugin_package.dart';

late Directory temp;
late TestPluginService harness;
late WorkspacePluginCommands commands;
final events = <Map<String, Object?>>[];

Future<void> expectIpcCode(Future<Object?> future, String code) => expectLater(
      future,
      throwsA(
        isA<WorkspaceManagerProtocolException>().having(
          (e) => e.code,
          'code',
          code,
        ),
      ),
    );

void main() {
  setUp(() {
    temp = Directory.systemTemp.createTempSync('plugin-cli-ipc-test');
    harness = TestPluginService(temp);
    events.clear();
    commands = WorkspacePluginCommands(harness.service, publish: events.add);
  });
  tearDown(() {
    Process.runSync('chmod', ['-R', 'u+w', temp.path]);
    temp.deleteSync(recursive: true);
  });

  group('IPC commands', () {
    test('only plugins.* commands are handled here', () {
      expect(WorkspacePluginCommands.handles('plugins.list'), isTrue);
      expect(WorkspacePluginCommands.handles('workers.list'), isFalse);
    });

    test('validates payloads before touching the service', () async {
      await expectIpcCode(
        commands.handle('plugins.show', {'pluginId': 'Not A Plugin'}),
        'invalid_request',
      );
      await expectIpcCode(
        commands.handle('plugins.show', {'pluginId': 'ok', 'version': '1.2'}),
        'invalid_request',
      );
      await expectIpcCode(
        commands.handle('plugins.register', {
          'pluginId': 'ok',
          'acceptHash': 'short',
        }),
        'invalid_request',
      );
      await expectIpcCode(
        commands.handle('plugins.import', {'path': 'relative/path'}),
        'invalid_request',
      );
      await expectIpcCode(
        commands.handle('plugins.export', {
          'pluginId': 'ok',
          'outputPath': 'out.zip',
        }),
        'invalid_request',
      );
      await expectIpcCode(
        commands.handle('plugins.bogus', {}),
        'unsupported_command',
      );
    });

    test('service failures keep their stable code and safe detail', () async {
      await expectIpcCode(
        commands.handle('plugins.show', {'pluginId': 'missing'}),
        'plugin_not_found',
      );
      final bad = writePluginPackage(temp, edit: (m) => m['oops'] = 1);
      await expectLater(
        commands.handle('plugins.import', {'path': bad}),
        throwsA(
          isA<WorkspaceManagerProtocolException>()
              .having((e) => e.code, 'code', 'plugin_manifest_invalid')
              .having((e) => e.message, 'message', contains('oops')),
        ),
      );
    });

    test('a Free account gets paid_plan_required over IPC', () async {
      harness.cloud.paid = false;
      await expectIpcCode(
        commands.handle('plugins.import', {
          'path': writePluginPackage(temp),
        }),
        'paid_plan_required',
      );
    });

    test('plugins.test streams progress as events and returns the report',
        () async {
      await commands.handle('plugins.import', {
        'path': writePluginPackage(temp),
      });
      final result = await commands.handle('plugins.test', {
        'pluginId': 'acme-reviewer',
      }) as Map;
      expect(result['passed'], isTrue);
      expect(events.single['name'], 'plugin.testProgress');
      expect(events.single['pluginId'], 'acme-reviewer');
      expect(events.single['message'], startsWith('conformance:'));
    });

    test('this build advertises the plugins capability additively', () {
      expect(workspaceManagerCapabilities, contains('plugins.v1'));
      expect(workspaceManagerProtocolVersion, 1);
    });
  });

  group('CLI', () {
    late StringBuffer out;
    late StringBuffer err;
    late List<(String, Map<String, Object?>)> sent;

    Future<int> run(
      List<String> args,
      Object? Function(String, Map<String, Object?>) reply,
    ) {
      final dir = Directory.systemTemp.createTempSync('plugin-cli');
      addTearDown(() => dir.deleteSync(recursive: true));
      return WorkspaceCli(
        out: out,
        err: err,
        request: (name, payload) async {
          sent.add((name, payload));
          return reply(name, payload);
        },
      ).run(['--data-dir', dir.path, ...args]);
    }

    setUp(() {
      out = StringBuffer();
      err = StringBuffer();
      sent = [];
    });

    test('sends absolute paths: the Service has a different working directory',
        () async {
      await run(
          ['plugins', 'import', 'rel/pkg'],
          (_, __) => {
                'pluginId': 'a',
                'version': '1.0.0',
                'manifestDigest': 'a' * 64,
                'next': 'validate',
              });
      expect(File(sent.single.$2['path'] as String).isAbsolute, isTrue);
      expect(sent.single.$1, 'plugins.import');

      sent.clear();
      await run(
          ['plugins', 'export', 'acme', 'out.zip'],
          (_, __) => {
                'pluginId': 'acme',
                'version': '1.0.0',
                'manifestDigest': 'b' * 64,
              });
      expect(sent.single.$1, 'plugins.export');
      expect(File(sent.single.$2['outputPath'] as String).isAbsolute, isTrue);
    });

    Map<String, Object?> consentReply() => {
          'consentRequired': true,
          'documentHash': 'c' * 64,
          'document': {
            'operation': 'register',
            'plugin': {
              'id': 'acme',
              'version': '1.0.0',
              'displayName': 'Acme',
              'author': 'Acme',
              'authorVerified': false,
            },
            'origin': {'kind': 'local_path', 'locator': 'pkg'},
            'digest': {
              'manifest': 'a' * 64,
              'artifact': 'b' * 64,
              'platform': 'linux-x64',
            },
            'requestedAccess': {
              'workRoot': 'write',
              'network': {'mode': 'none'},
              'subprocess': false,
              'env': <String>[],
            },
            'isolation': {'tier': 'none', 'readOnlyEnforced': false},
            'signature': {'status': 'unsigned'},
            'statement': pluginConsentStatement,
          },
        };

    test('shows the consent document and exits 3 until it is accepted',
        () async {
      final code =
          await run(['plugins', 'register', 'acme'], (_, __) => consentReply());
      expect(code, 3);
      final text = '$out';
      expect(text, contains('Review before you register this plugin'));
      expect(text, contains('a' * 64));
      expect(text, contains('unverified, as claimed'));
      expect(text, contains('This program runs as you'));
      expect(text, contains('--accept ${'c' * 64}'));
      expect(text, isNot(contains('Registered')));
    });

    test('--accept is forwarded and a completed registration exits 0',
        () async {
      final code = await run(
        [
          'plugins',
          'register',
          'acme',
          '--accept',
          'c' * 64,
          '--version',
          '1.0.0'
        ],
        (_, __) => {
          'registered': true,
          'pluginRef': 'plugin-3fa91c04b2d7',
          'version': '1.0.0'
        },
      );
      expect(code, 0);
      expect(sent.single.$2['acceptHash'], 'c' * 64);
      expect(sent.single.$2['version'], '1.0.0');
      expect('$out', contains('plugin-3fa91c04b2d7'));
    });

    test('signer commands remain IPC-only and consent exits 3', () async {
      final fingerprint = 'a' * 64;
      var code = await run(
          ['plugins', 'trust-signer', 'acme', '--version', '1.0.0'],
          (_, __) => {
                'consentRequired': true,
                'documentHash': 'b' * 64,
                'document': {
                  'pluginId': 'acme',
                  'version': '1.0.0',
                  'manifestDigest': 'c' * 64,
                  'fingerprint': fingerprint,
                  'statement': 'Recognition does not approve execution.'
                },
              });
      expect(code, 3);
      expect(sent.single.$1, 'plugins.trustSigner');
      expect(sent.single.$2['version'], '1.0.0');
      expect('$out', contains(fingerprint));
      expect('$out', contains('--accept ${'b' * 64}'));
      sent.clear();
      code = await run(
          ['plugins', 'trust-signer', 'acme', '--accept', 'b' * 64],
          (_, __) => {'trustedLocally': true, 'fingerprint': fingerprint});
      expect(code, 0);
      expect(sent.single.$2['acceptHash'], 'b' * 64);
      sent.clear();
      await run(['plugins', 'untrust-signer', fingerprint],
          (_, __) => {'removed': true, 'fingerprint': fingerprint});
      expect(sent.single.$1, 'plugins.untrustSigner');
      expect(sent.single.$2['fingerprint'], fingerprint);
      sent.clear();
      await run(
          ['plugins', 'signers'],
          (_, __) => {
                'signers': [
                  {'fingerprint': fingerprint, 'acceptedAt': 'now'}
                ],
                'statement': 'Local recognition only.',
              });
      expect(sent.single.$1, 'plugins.signers');
      expect('$out', contains('Local recognition only.'));
    });

    test('--json prints the raw reply and still exits 3 for pending consent',
        () async {
      final code = await run(
          ['--json', 'plugins', 'enable', 'acme'], (_, __) => consentReply());
      expect(code, 3);
      expect((jsonDecode('$out') as Map)['documentHash'], 'c' * 64);
    });

    test('renders conformance with the disclaimer and exits 0', () async {
      final code = await run(
          ['plugins', 'test', 'acme'],
          (_, __) => {
                'suiteVersion': '1.0.0',
                'passed': false,
                'cases': [
                  {'id': 'handshake.identity', 'status': 'passed', 'ms': 4},
                  {
                    'id': 'cancel.within_grace',
                    'status': 'failed',
                    'ms': 5300,
                    'detail': 'No terminal frame'
                  },
                ],
                'disclaimer': 'Conformance shows protocol behavior only.',
              });
      expect(code, 0);
      expect('$out', contains('cancel.within_grace'));
      expect('$out', contains('No terminal frame'));
      expect('$out', contains('FAILED'));
      expect('$out', contains('protocol behavior only'));
    });

    test('shows when Plus is not verified and that enabled plugins pause',
        () async {
      await run(
          ['plugins', 'list'],
          (_, __) => {
                'entitlement': {'entitled': false},
                'plugins': [
                  {
                    'pluginId': 'acme',
                    'displayName': 'Acme',
                    'versions': [
                      {
                        'version': '1.0.0',
                        'manifestDigest': 'a' * 64,
                        'registered': true
                      },
                    ],
                    'workspace': {
                      'pinnedVersion': '1.0.0',
                      'effective': 'disabled',
                      'reason': 'plus_required',
                    },
                  },
                ],
              });
      expect('$out', contains('Syntila Plus is not verified'));
      expect('$out', contains('plus_required'));
    });

    test('a reply it cannot render falls back instead of crashing', () async {
      final code =
          await run(['plugins', 'list'], (_, __) => {'plugins': 'nonsense'});
      expect(code, 0);
      expect('$err', isEmpty);
    });

    test('service errors print the stable code and exit 1', () async {
      final code = await run(['plugins', 'import', 'x'], (_, __) {
        throw const WorkspaceManagerProtocolException(
          'paid_plan_required',
          'Custom Worker plugins require Syntila Plus.',
        );
      });
      expect(code, 1);
      expect('$err', contains('paid_plan_required'));
    });
  });
}
