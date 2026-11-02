import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/features/files/files_page.dart';
import 'package:syntila_app/src/features/navigation/app_menu.dart';
import 'package:syntila_app/src/features/navigation/ax_shell_context.dart';
import 'package:syntila_app/src/navigation/ax_navigation.dart';

class _FakeFiles implements AxUserFilesDataSource {
  _FakeFiles(this.files);

  final List<AxUserFile> files;
  final deleted = <String>[];
  bool failSync = false;
  int syncCount = 0;

  @override
  Future<void> syncUserFiles() async {
    syncCount++;
    if (failSync) throw Exception('offline');
    files.clear();
  }

  static const quota = 1000000000;

  /// Overrides the computed usage (for allowance and warning states).
  AxStorageUsage? usage;

  AxStorageUsage get _usage =>
      usage ??
      AxStorageUsage(
        usedBytes: files.fold(0, (sum, file) => sum + file.sizeBytes),
        fileCount: files.length,
        quotaBytes: quota,
      );

  @override
  Future<AxUserFilesPage> loadUserFiles({String? before}) async =>
      AxUserFilesPage(files: [...files], usage: _usage);

  @override
  Future<AxStorageUsage> deleteUserFile(String fileId) async {
    deleted.add(fileId);
    files.removeWhere((file) => file.fileId == fileId);
    return _usage;
  }
}

void main() {
  test('My Files has its own route', () {
    final route = AxNavigation.fromUri(Uri(path: '/files'));
    expect(route.kind, AxRouteKind.files);
    expect(route.toUri().path, '/files');
  });

  testWidgets('global application menu places My Files above My Notes',
      (tester) async {
    AxNavigation? navigation;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: GlobalAppMenu(
      shellContext:
          const AxShellContext(navigation: AxNavigation.space('S'), spaces: []),
      onNavigateTo: (value) => navigation = value,
      onOpenAbout: () {},
      onOpenExternal: (_) {},
      onLogout: () {},
    ))));
    await tester.tap(find.byTooltip('Application menu'));
    await tester.pumpAndSettle();

    final myFiles = find.byKey(const ValueKey('menu-my-files'));
    final myNotes = find.byKey(const ValueKey('menu-my-notes'));
    expect(myFiles, findsOneWidget);
    expect(myNotes, findsOneWidget);
    expect(tester.getRect(myFiles).bottom,
        lessThanOrEqualTo(tester.getRect(myNotes).top));

    await tester.tap(myFiles);
    await tester.pumpAndSettle();
    expect(navigation!.kind, AxRouteKind.files);
    expect(navigation!.toUri().path, '/files');
  });

  test('formats sizes', () {
    expect(formatFileSize(512), '512 B');
    expect(formatFileSize(1500), '1.5 kB');
    expect(formatFileSize(10000000), '10 MB');
    expect(formatFileSize(25000000000), '25 GB');
  });

  testWidgets(
      'synchronizes storage, reloads usage and allows retry after failure',
      (tester) async {
    final source = _FakeFiles([])..failSync = true;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: FilesPage(source: source))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Synchronize storage'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Synchronization could not finish'),
        findsOneWidget);
    source.failSync = false;
    await tester.tap(find.text('Synchronize storage'));
    await tester.pumpAndSettle();
    expect(source.syncCount, 2);
    expect(find.text('Files synchronized with storage.'), findsOneWidget);
    expect(
        find.textContaining('Synchronization could not finish'), findsNothing);
    expect(find.textContaining('0 files'), findsOneWidget);

    final usageText = find.byKey(const ValueKey('files-usage'));
    final syncButton = find.widgetWithText(TextButton, 'Synchronize storage');
    final progressBar = find.byType(LinearProgressIndicator);
    expect(tester.getRect(usageText).left,
        lessThan(tester.getRect(syncButton).left));
    expect(tester.getRect(syncButton).bottom,
        lessThanOrEqualTo(tester.getRect(progressBar).top));
  });

  testWidgets('lists uploads with usage and deletes a file', (tester) async {
    final source = _FakeFiles([
      const AxUserFile(
        fileId: 'wrf-a',
        name: 'plan.pdf',
        mediaType: 'application/pdf',
        sizeBytes: 2 * 1024 * 1024,
        createdAt: '2026-10-01T10:00:00.000Z',
        threadId: 'thread',
        spaceId: 'space',
        threadName: 'Plan',
        spaceName: 'Team',
        inUse: true,
      ),
      const AxUserFile(
        fileId: 'wrf-b',
        name: 'notes.txt',
        mediaType: 'text/plain',
        sizeBytes: 1024,
        createdAt: '2026-10-02T10:00:00.000Z',
      ),
    ]);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: FilesPage(source: source))));
    await tester.pumpAndSettle();

    expect(find.text('plan.pdf'), findsOneWidget);
    expect(find.textContaining('Team > Plan'), findsOneWidget);
    expect(find.textContaining('In use'), findsOneWidget);
    expect(find.textContaining('Thread no longer available'), findsOneWidget);
    expect(find.textContaining('of 1 GB used · 2 files'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('delete-file-wrf-a')));
    await tester.pumpAndSettle();
    expect(find.textContaining('can no longer be downloaded'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-delete-file')));
    await tester.pumpAndSettle();

    expect(source.deleted, ['wrf-a']);
    expect(find.text('plan.pdf'), findsNothing);
    expect(find.textContaining('1 file'), findsOneWidget);
  });

  testWidgets('warns at 80% and explains blocked uploads when storage is full',
      (tester) async {
    Future<void> pumpUsage(AxStorageUsage usage) async {
      final source = _FakeFiles([])..usage = usage;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: FilesPage(key: UniqueKey(), source: source))));
      await tester.pumpAndSettle();
    }

    await pumpUsage(const AxStorageUsage(
        usedBytes: 500000000,
        fileCount: 1,
        quotaBytes: 1000000000,
        maxFileBytes: 25000000));
    expect(find.byKey(const ValueKey('files-near-limit')), findsNothing);
    expect(find.text('Each file can be up to 25 MB.'), findsOneWidget);

    await pumpUsage(const AxStorageUsage(
        usedBytes: 800000000,
        fileCount: 1,
        quotaBytes: 1000000000,
        maxFileBytes: 25000000));
    expect(find.textContaining('used 80% of your storage'), findsOneWidget);
    expect(find.byKey(const ValueKey('files-full')), findsNothing);

    await pumpUsage(const AxStorageUsage(
        usedBytes: 1200000000,
        fileCount: 3,
        quotaBytes: 1000000000,
        maxFileBytes: 25000000));
    // Already above quota (for example after a downgrade): blocked, but kept.
    expect(find.textContaining('Storage is full. New uploads are blocked'),
        findsOneWidget);
    expect(
        find.textContaining('existing files stay available'), findsOneWidget);
    expect(find.textContaining('unlimited'), findsNothing);
  });
}
