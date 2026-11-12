import 'dart:async';
import 'dart:convert';

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
  Future<List<int>> downloadUserFile(String fileId) async {
    downloads.add(fileId);
    if (pending != null) return pending!.future;
    if (failDownload) throw Exception('offline');
    return contents[fileId] ?? [];
  }

  final downloads = <String>[];
  final contents = <String, List<int>>{};
  bool failDownload = false;
  Completer<List<int>>? pending;

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
  const textFile = AxUserFile(
      fileId: 'text',
      name: 'note.txt',
      mediaType: 'text/plain',
      sizeBytes: 5,
      createdAt: '');
  const imageFile = AxUserFile(
      fileId: 'image',
      name: 'image.png',
      mediaType: 'image/png',
      sizeBytes: 1,
      createdAt: '');
  const pdfFile = AxUserFile(
      fileId: 'pdf',
      name: 'file.pdf',
      mediaType: 'application/pdf',
      sizeBytes: 1,
      createdAt: '');

  testWidgets('downloads bytes and shows per-file loading', (tester) async {
    final source = _FakeFiles([textFile, pdfFile])
      ..pending = Completer<List<int>>();
    final saved = <Object>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FilesPage(
                source: source,
                saveFile: (bytes, name) => saved.add([bytes, name])))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download-file-text')));
    await tester.pump();
    expect(source.downloads, ['text']);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('preview-file-text')),
            matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('download-file-pdf')))
            .onPressed,
        isNotNull);
    source.pending!.complete([1, 2]);
    await tester.pumpAndSettle();
    expect(saved, [
      [
        [1, 2],
        'note.txt'
      ]
    ]);
  });

  testWidgets('tapping a text file previews it and downloads from the dialog',
      (tester) async {
    final source = _FakeFiles([textFile])
      ..contents['text'] = utf8.encode('Hello preview');
    final saved = <Object>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FilesPage(
                source: source,
                saveFile: (bytes, name) => saved.add([bytes, name])))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('note.txt'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('attachment-text-viewer')), findsOneWidget);
    expect(find.text('Hello preview'), findsOneWidget);
    await tester.tap(find.byTooltip('Download file').last);
    await tester.pumpAndSettle();
    expect(saved, [
      [utf8.encode('Hello preview'), 'note.txt']
    ]);
  });

  testWidgets('previews images and opens other formats', (tester) async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';
    final source = _FakeFiles([imageFile, pdfFile])
      ..contents['image'] = base64Decode(png)
      ..contents['pdf'] = [3];
    final opened = <Object>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FilesPage(
                source: source,
                openFile: (bytes, name, type) =>
                    opened.add([bytes, name, type])))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('preview-file-image')));
    await tester.pump();
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('attachment-image-viewer')), findsOneWidget);
    await tester.tap(find.byTooltip('Close preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('preview-file-pdf')));
    await tester.pumpAndSettle();
    expect(opened, [
      [
        [3],
        'file.pdf',
        'application/pdf'
      ]
    ]);
  });

  testWidgets('reports preview and download errors', (tester) async {
    final source = _FakeFiles([textFile])..failDownload = true;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: FilesPage(source: source))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('preview-file-text')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not preview file: Exception: offline'),
        findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(FilesPage)))
        .hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download-file-text')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not download file: Exception: offline'),
        findsOneWidget);
  });

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
