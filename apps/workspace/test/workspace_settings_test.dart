import 'dart:io';

import 'package:syntila_workspace/workspace.dart';
import 'package:syntila_workspace/workspace_settings.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('workspace-settings-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  WorkspaceSettings settings() => WorkspaceSettings(
        serviceEnabled: true,
        cloudUrl: 'https://syntila.app',
        connectOnStart: true,
        workspaceName: 'GMKtec',
        workRoot: '${root.path}/work',
        folders: {
          'models': '${root.path}/models',
        },
      );

  test('round-trips strict Nano Markup configuration atomically', () async {
    final store = WorkspaceSettingsStore(Directory('${root.path}/state'));
    await store.write(settings());

    final source = await store.file.readAsString();
    expect(source, startsWith('..\n'));
    // Parallel slots are set on the web Workspaces page, never in this file.
    expect(source, isNot(contains('parallel_slots')));
    expect(source, contains('models ${root.path}/models'));
    final loaded = store.readSync()!;
    expect(loaded.workspaceName, 'GMKtec');
    expect(loaded.legacyParallelSlots, isNull);
    expect(loaded.workRoot, '${root.path}/work');
    expect(loaded.folders['models'], '${root.path}/models');
    if (!Platform.isWindows) {
      expect(store.file.statSync().mode & 0x1ff, 0x180);
    }
  });

  test('rejects invalid scalar types, paths and unknown behavior keys', () {
    final valid = settings().toNanoValue();
    expect(
      () => WorkspaceSettings.fromNanoValue({
        ...valid,
        'folders': {
          ...(valid['folders']! as Map<String, Object>),
          'work': 'relative/work',
        },
      }),
      throwsFormatException,
    );
    expect(
      () => WorkspaceSettings.fromNanoValue({
        ...valid,
        'service': {'enabled': 'true', 'mystery': 'value'},
      }),
      throwsFormatException,
    );
  });

  test(
    'resolver consumes workspace.nano once as service configuration',
    () async {
      final state = Directory('${root.path}/state');
      await WorkspaceSettingsStore(state).write(settings());

      final config = WorkspaceConfig.fromArgs(['--data-dir', state.path]);
      expect(config.serviceEnabled, isTrue);
      expect(config.connectOnStart, isTrue);
      expect(config.legacyParallelSlots, isNull);
      expect(config.workRootPath, '${root.path}/work');
      expect(config.folders['models'], '${root.path}/models');
      expect(config.cloudUri!.scheme, 'wss');
    },
  );

  test(
    'initialization creates platform defaults without legacy state',
    () async {
      final state = Directory('${root.path}/state');
      final store = WorkspaceSettingsStore(state);
      final generated = await store.ensureDefaults();

      expect(generated.cloudUrl, 'https://app.syntila.app');
      // A new file is named after this machine.
      expect(generated.workspaceName, isNotEmpty);
      expect(generated.workspaceName.length, lessThanOrEqualTo(120));
      expect(generated.legacyParallelSlots, isNull);
      expect(generated.connectOnStart, isFalse);
      expect(generated.workRoot, isNotEmpty);
      expect(store.file.existsSync(), isTrue);
    },
  );

  test('an old file\'s parallel_slots is read once for Cloud to adopt', () {
    final valid = settings().toNanoValue();
    final legacy = WorkspaceSettings.fromNanoValue({
      ...valid,
      'execution': {'parallel_slots': '7'},
    });
    expect(legacy.legacyParallelSlots, 7);
    expect(legacy.toNanoValue().containsKey('execution'), isFalse);
    // Out of range is ignored, not a startup failure.
    expect(
      WorkspaceSettings.fromNanoValue({
        ...valid,
        'execution': {'parallel_slots': '11'},
      }).legacyParallelSlots,
      isNull,
    );
  });
}
