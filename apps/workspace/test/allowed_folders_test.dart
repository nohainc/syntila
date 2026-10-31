import 'dart:convert';
import 'dart:io';

import 'package:syntila_workspace/allowed_folders.dart';
import 'package:test/test.dart';

void main() {
  late Directory sandbox;
  late Directory home;
  late Directory workRoot;
  late Directory appData;
  late Directory registryDirectory;

  AllowedFolderRegistry registry() => AllowedFolderRegistry(
        registryDirectory: registryDirectory,
        workRoot: workRoot,
        applicationDataRoot: appData,
        homeDirectory: home.path,
        clock: () => DateTime.utc(2026, 10, 25),
      );

  Future<Directory> folder(String name) =>
      Directory('${home.path}/$name').create(recursive: true);

  setUp(() async {
    sandbox = Directory(
        (await Directory.systemTemp.createTemp('allowed-folders-'))
            .resolveSymbolicLinksSync());
    home = await Directory('${sandbox.path}/home').create();
    workRoot = await Directory('${home.path}/Documents/Syntila')
        .create(recursive: true);
    appData = await Directory('${home.path}/Library/Application Support')
        .create(recursive: true);
    registryDirectory = Directory('${appData.path}/Syntila/Registry');
  });

  tearDown(() async {
    if (!Platform.isWindows) {
      await Process.run('chmod', ['-R', 'u+rwx', sandbox.path]);
    }
    await sandbox.delete(recursive: true);
  });

  test('adds a writable folder with a generated ID and folder name', () async {
    final projects = await folder('Projects/api');
    final added = await registry().add(projects.path);

    expect(added.id, matches(RegExp(r'^folder-[a-f0-9]{16}$')));
    expect(added.displayName, 'api');
    expect(added.path, projects.path);
    expect(added.status, AllowedFolderStatus.available);
    expect(projects.listSync(), isEmpty, reason: 'write probe is removed');
    expect((await registry().list()).single.id, added.id);
  });

  test('canonicalizes symlinks and trailing separators', () async {
    final target = await folder('Real');
    final link = Link('${home.path}/Alias')..createSync(target.path);
    final added = await registry().add('${link.path}/', displayName: ' Docs ');

    expect(added.path, target.path);
    expect(added.displayName, 'Docs');
  });

  test('rejects protected, relative, missing, and duplicate paths', () async {
    final subject = registry();
    Future<void> rejects(String path, String code) => expectLater(
        subject.add(path),
        throwsA(isA<AllowedFolderViolation>()
            .having((error) => error.code, 'code', code)));

    await rejects('relative/path', 'invalid_path');
    await rejects('${home.path}/missing', 'not_a_directory');
    await rejects('/', 'protected');
    await rejects(home.path, 'protected');
    await rejects(sandbox.path, 'protected');
    await rejects(workRoot.path, 'protected');
    await rejects(
        (await Directory('${workRoot.path}/abc').create()).path, 'protected');
    await rejects(appData.path, 'protected');
    await rejects(
        (await Directory('${appData.path}/Other').create()).path, 'protected');
    // Documents contains Work Root, so allowing it would expose Space folders.
    await rejects('${home.path}/Documents', 'protected');

    final shared = await folder('Shared');
    await subject.add(shared.path);
    await rejects(shared.path, 'duplicate');
    await rejects((await folder('Shared/inner')).path, 'overlapping');
    expect(await subject.list(), hasLength(1));
  });

  test('reports read-only, denied, and missing folders on recheck', () async {
    final subject = registry();
    final readOnly = await subject.add((await folder('ReadOnly')).path);
    final denied = await subject.add((await folder('Denied')).path);
    final missing = await subject.add((await folder('Gone')).path);

    await Process.run('chmod', ['555', readOnly.path]);
    await Process.run('chmod', ['000', denied.path]);
    await Directory(missing.path).delete();

    final statuses = {
      for (final entry in await subject.recheck()) entry.id: entry.status
    };
    expect(statuses[readOnly.id], AllowedFolderStatus.readOnly);
    expect(statuses[denied.id], AllowedFolderStatus.denied);
    expect(statuses[missing.id], AllowedFolderStatus.missing);
    expect((await registry().find(missing.id))!.status,
        AllowedFolderStatus.missing,
        reason: 'recheck results are persisted');
  }, testOn: 'mac-os || linux');

  test('refuses to add a folder without write access', () async {
    final subject = registry();
    Future<void> rejects(String path, String code) => expectLater(
        subject.add(path),
        throwsA(isA<AllowedFolderViolation>()
            .having((error) => error.code, 'code', code)));

    final readOnly = await folder('Locked');
    await Process.run('chmod', ['555', readOnly.path]);
    final denied = await folder('Hidden');
    await Process.run('chmod', ['000', denied.path]);
    await rejects(readOnly.path, 'not_writable');
    await rejects(denied.path, 'denied');
    expect(await subject.list(), isEmpty);
  }, testOn: 'mac-os || linux');

  test('remove and rename leave the folder on disk', () async {
    final subject = registry();
    final docs = await folder('Docs');
    File('${docs.path}/keep.txt').writeAsStringSync('user data');
    final added = await subject.add(docs.path);

    expect((await subject.rename(added.id, 'Reference'))!.displayName,
        'Reference');
    expect(await subject.remove(added.id), isTrue);
    expect(await subject.remove(added.id), isFalse);
    expect(await subject.list(), isEmpty);
    expect(File('${docs.path}/keep.txt').readAsStringSync(), 'user data');
  });

  test('cloud summary never includes the local path', () async {
    final added = await registry().add((await folder('Private')).path);
    final summary = jsonEncode(added.toCloudSummary());

    expect(summary, isNot(contains(home.path)));
    expect(added.toCloudSummary().keys,
        unorderedEquals(['id', 'displayName', 'status', 'checkedAt']));
  });

  test('fails closed on an unreadable registry file', () async {
    await registryDirectory.create(recursive: true);
    File('${registryDirectory.path}/${AllowedFolderRegistry.fileName}')
        .writeAsStringSync('{"schemaVersion": 99}');

    await expectLater(registry().list(), throwsStateError);
  });

  test('resolves attached folder IDs to fresh local paths before launch',
      () async {
    final subject = registry();
    final api = await subject.add((await folder('api')).path);
    final gone = await subject.add((await folder('gone')).path);

    expect(await subject.resolveForExecution([api.id]), [api.path]);
    expect(await subject.resolveForExecution(const []), isEmpty);

    await Directory(gone.path).delete();
    await expectLater(
        subject.resolveForExecution([api.id, gone.id]),
        throwsA(isA<AllowedFolderViolation>()
            .having((error) => error.message, 'message', contains('"gone"'))));
    await expectLater(subject.resolveForExecution(['folder-ffffffffffffffff']),
        throwsA(isA<AllowedFolderViolation>()));
    await expectLater(subject.resolveForExecution([api.id, api.id]),
        throwsA(isA<AllowedFolderViolation>()));
  });

  test('reads folder IDs from assignment input and fails closed', () {
    expect(assignmentAdditionalFolderIds(const {}), isEmpty);
    expect(
        assignmentAdditionalFolderIds(const {
          'input': {
            'additionalFolderIds': ['folder-0123456789abcdef']
          }
        }),
        ['folder-0123456789abcdef']);
    for (final invalid in [
      'folder-0123456789abcdef',
      ['/Users/me/api'],
      [42],
    ]) {
      expect(
          () => assignmentAdditionalFolderIds({
                'input': {'additionalFolderIds': invalid}
              }),
          throwsA(isA<AllowedFolderViolation>()));
    }
  });

  test('requires the folder slot in every selectable argument vector', () {
    const slot = {
      'forEachAdditionalDirectory': ['--add-dir', '{{additionalDirectory}}']
    };
    expect(
        profileSupportsAdditionalDirectories({
          'execution': {
            'arguments': ['run', slot]
          },
          'compatibilityOverrides': const [],
        }),
        isTrue);
    expect(
        profileSupportsAdditionalDirectories({
          'execution': {
            'arguments': ['run']
          },
        }),
        isFalse);
    expect(
        profileSupportsAdditionalDirectories({
          'execution': {
            'arguments': ['run', slot]
          },
          'compatibilityOverrides': [
            {
              'executionArguments': ['old-run']
            }
          ],
        }),
        isFalse,
        reason: 'An override without the slot could drop the folders.');
  });
}
