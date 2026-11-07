import 'dart:io';

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
    harness = TestPluginService(temp, mcpInspect: FakePluginMcpInspect());
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

    test('a Free account can import over IPC', () async {
      final result = await commands.handle('plugins.import', {
        'path': writePluginPackage(temp),
      });
      expect(result, isA<Map>());
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
    test('plugins commands are removed from the workspace app CLI', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await WorkspaceCli(
        out: out,
        err: err,
      ).run(['plugins']);
      expect(code, 64);
      expect('$err', contains('Could not find a command named "plugins"'));
    });
  });
}
