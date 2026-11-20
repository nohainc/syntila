import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_agent/syntila_worker_agent.dart';
import 'package:test/test.dart';

void main() {
  late Directory sandbox;
  late Directory legacy;
  late AllowedFolders folders;
  late WorkRoot workRoot;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('syntila-import-');
    await Directory('${sandbox.path}/home').create();
    await Directory('${sandbox.path}/data').create();
    legacy = await Directory('${sandbox.path}/legacy').create();
    folders = AllowedFolders(
      File('${sandbox.path}/data/allowed.json'),
      home: '${sandbox.path}/home',
      dataRoot: '${sandbox.path}/data',
    );
    workRoot = WorkRoot(File('${sandbox.path}/data/work-root.json'), folders);
  });
  tearDown(() => sandbox.delete(recursive: true));

  Future<void> writeLegacy({
    required String root,
    required List<String> folderPaths,
  }) async {
    await File('${legacy.path}/workspace-lifecycle.json').writeAsString(
      jsonEncode({'workRootPath': root}),
    );
    await File('${legacy.path}/allowed-folders.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'folders': [
          for (final path in folderPaths) {'id': 'folder-0', 'path': path},
        ],
      }),
    );
  }

  test('imports the Work Root and folders read-only, and leaves the old data',
      () async {
    final root = await Directory('${sandbox.path}/root').create();
    final extra = await Directory('${sandbox.path}/extra').create();
    await writeLegacy(
      root: root.path,
      folderPaths: [extra.path, '${sandbox.path}/gone'],
    );
    final before = await File(
      '${legacy.path}/allowed-folders.json',
    ).readAsString();

    final report = await importLegacyWorkspace(
      legacyData: legacy,
      folders: folders,
      workRoot: workRoot,
    );

    expect(await workRoot.root(), isNotNull);
    expect(report.imported, [extra.path]);
    expect(report.skipped.single, contains('gone'));
    expect(await folders.isAllowed(extra.path), isTrue);
    expect(await folders.isAllowed(extra.path, write: true), isFalse);
    expect(report.notCopied.join(' '), contains('credentials'));
    expect(
      await File('${legacy.path}/allowed-folders.json').readAsString(),
      before,
    );
  });

  test('--write keeps write access, and a dry run changes nothing', () async {
    final extra = await Directory('${sandbox.path}/extra').create();
    await writeLegacy(root: '${sandbox.path}/none', folderPaths: [extra.path]);

    final dry = await importLegacyWorkspace(
      legacyData: legacy,
      folders: folders,
      workRoot: workRoot,
      dryRun: true,
    );
    expect(dry.imported, [extra.path]);
    expect(await folders.list(), isEmpty);

    await importLegacyWorkspace(
      legacyData: legacy,
      folders: folders,
      workRoot: workRoot,
      write: true,
    );
    expect(await folders.isAllowed(extra.path, write: true), isTrue);
  });

  test('a missing directory is an error, not an empty import', () async {
    await expectLater(
      importLegacyWorkspace(
        legacyData: Directory('${sandbox.path}/nope'),
        folders: folders,
        workRoot: workRoot,
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
