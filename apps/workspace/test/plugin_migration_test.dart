import 'dart:io';

import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:syntila_workspace/plugin_migration.dart';
import 'package:syntila_workspace/plugin_store.dart';
import 'package:test/test.dart';

import 'support/plugin_fakes.dart';
import 'support/plugin_package.dart';

PluginManifest manifest({
  String workRoot = 'none',
  Map<String, Object?> capabilities = const {},
  bool mcp = false,
}) {
  final map = <String, Object?>{
    'schemaVersion': 1,
    if (mcp) 'kind': 'mcp',
    'pluginId': 'acme-reviewer',
    'version': '1.0.0',
    'displayName': 'Acme',
    'description': 'x',
    'author': {'name': 'Acme'},
    'protocol': {'min': '1.0', 'max': '1.0'},
    'artifacts': {
      'linux-x64': {
        'command': 'bin/run',
        'args': <String>[],
        'sha256': 'a' * 64,
        'size': 10,
      },
    },
    'capabilities': capabilities,
    'access': {
      'workRoot': workRoot,
      'network': {'mode': 'none'},
      'subprocess': false,
      'env': <String>[],
    },
  };
  final result = validatePluginManifest(map);
  expect(result.issues, isEmpty);
  return result.manifest!;
}

List<Object?> codes(Map<String, Object?> assessment, String key) => [
      for (final item in assessment[key]! as List) (item as Map)['code'],
    ];

void main() {
  group('assessMcpMigration', () {
    test('a plugin that needs no Space files can migrate today', () {
      final a = assessMcpMigration(manifest());
      expect(a['alreadyMcp'], isFalse);
      expect(a['canMigrate'], isTrue);
      expect(a['blockers'], isEmpty);
      expect(codes(a, 'warnings'), [
        'conformance_differs',
        'tool_definitions_are_pinned',
      ]);
      final steps = (a['steps']! as List).cast<String>();
      expect(steps, hasLength(4));
      expect(steps[0], contains('runMcpWorker'));
      expect(steps[1], contains('"kind": "mcp"'));
    });

    test('reading or writing the Space blocks it until MCP gets a working dir',
        () {
      for (final root in ['read', 'write']) {
        final a = assessMcpMigration(manifest(workRoot: root));
        expect(a['canMigrate'], isFalse, reason: root);
        expect(codes(a, 'blockers'), ['working_directory_unsupported']);
        expect(
          ((a['blockers']! as List).single as Map)['message'],
          contains('workRoot "$root"'),
        );
        // The steps are still listed so the author sees the whole path.
        expect(a['steps'], isNotEmpty);
      }
    });

    test('session and model discovery capabilities add specific warnings', () {
      final native = assessMcpMigration(
        manifest(capabilities: {
          'continuity': {
            'strategy': 'native_handle',
            'formatId': 'acme-session-v1',
          },
        }),
      );
      expect(codes(native, 'warnings'), contains('session_state'));
      final resume = assessMcpMigration(
        manifest(capabilities: {'sessionResume': true}),
      );
      expect(codes(resume, 'warnings'), contains('session_state'));
      final replay = assessMcpMigration(
        manifest(capabilities: {
          'continuity': {'strategy': 'history_replay'}
        }),
      );
      expect(codes(replay, 'warnings'), isNot(contains('session_state')));
      final models = assessMcpMigration(
        manifest(capabilities: {'modelDiscovery': true}),
      );
      expect(codes(models, 'warnings'), contains('model_discovery'));
    });

    test('an MCP Worker has nothing to migrate', () {
      final a = assessMcpMigration(manifest(mcp: true));
      expect(a['alreadyMcp'], isTrue);
      expect(a['canMigrate'], isFalse);
      expect(a['steps'], isEmpty);
    });
  });

  group('WorkspacePluginService.migrateCheck', () {
    late Directory temp;
    late TestPluginService harness;
    setUp(() {
      temp = Directory.systemTemp.createTempSync('plugin-migrate');
      harness = TestPluginService(temp);
    });
    tearDown(() {
      Process.runSync('chmod', ['-R', 'u+w', temp.path]);
      temp.deleteSync(recursive: true);
    });

    test('reports on an imported plugin without running or changing it',
        () async {
      await harness.service.import(
        writePluginPackage(temp, workRoot: 'write', name: 'w'),
      );
      final before = await harness.service.list();
      final a = await harness.service.migrateCheck('acme-reviewer');
      expect(a['pluginId'], 'acme-reviewer');
      expect(a['version'], '1.4.2');
      expect(a['canMigrate'], isFalse);
      expect(codes(a, 'blockers'), ['working_directory_unsupported']);
      // Read-only: the library is unchanged and nothing was registered.
      expect(await harness.service.list(), before);
      expect(harness.cloud.calls, isEmpty);
    });

    test('a plugin that needs no Space can migrate; an MCP package is flagged',
        () async {
      await harness.service.import(
        writePluginPackage(temp, workRoot: 'none', name: 'n'),
      );
      expect(
          (await harness.service.migrateCheck('acme-reviewer'))['canMigrate'],
          isTrue);
      await harness.service.import(
        writePluginPackage(
          temp,
          id: 'echo-worker',
          name: 'm',
          edit: (m) => m['kind'] = 'mcp',
        ),
      );
      expect(
        (await harness.service.migrateCheck('echo-worker'))['alreadyMcp'],
        isTrue,
      );
    });

    test('an unknown plugin is a stable error', () async {
      await expectLater(
        harness.service.migrateCheck('nope'),
        throwsA(isA<PluginServiceException>()),
      );
    });
  });
}
