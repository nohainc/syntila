import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'package:syntila_app/src/ax/sync/ax_discussion_cache.dart';
import 'package:syntila_app/src/ax/sync/ax_work_history.dart';
import 'package:syntila_app/src/ax/sync/persistence/ax_thread_view_state_store.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'workflows_page_test.dart' show WorkflowSource;

class FolderSource extends WorkflowSource
    implements AxSpaceAdditionalFolderDataSource {
  FolderSource({this.eligible = true});
  final bool eligible;
  final attached = <String>{};
  final saves = <List<String>>[];

  AxSpaceAdditionalFolders _state() => AxSpaceAdditionalFolders(
        eligible: eligible,
        workspaceId: 'ws',
        folders: eligible
            ? [
                for (final (id, name, status) in [
                  ('folder-00000000000000a1', 'api', 'available'),
                  ('folder-00000000000000b2', 'Gone', 'missing'),
                ])
                  AxAdditionalFolder(
                      id: id,
                      displayName: name,
                      status: status,
                      attached: attached.contains(id)),
              ]
            : const [],
      );

  @override
  Future<AxSpaceAdditionalFolders> loadSpaceAdditionalFolders(
          String spaceId) async =>
      _state();

  @override
  Future<AxSpaceAdditionalFolders> saveSpaceAdditionalFolders(
      String spaceId, List<String> folderIds) async {
    saves.add(folderIds);
    attached
      ..clear()
      ..addAll(folderIds);
    return _state();
  }
}

class SpaceSettingsSource extends WorkflowSource {
  Map<String, dynamic>? savedSettings;

  @override
  Future<AxSpace> updateSpace({
    required String spaceId,
    String? name,
    String? description,
    String? instructions,
    Map<String, dynamic>? settings,
  }) async {
    savedSettings = settings;
    return ownerSpace.copyWith(settings: settings);
  }
}

const ownerSpace =
    AxSpace(id: 'S', name: 'Space', branch: '', lastActivity: 'now');
const memberSpace = AxSpace(
    id: 'S',
    name: 'Space',
    branch: '',
    lastActivity: 'now',
    role: 'collaborator');

Future<void> pumpSpace(
    WidgetTester tester, WorkflowSource source, AxSpace space) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: NewThreadPage(
    space: space,
    dataSource: source,
    discussionCache: AxDiscussionCache.forSource(source),
    workHistoryCache: AxWorkHistoryCache.forSource(source),
    threadViewStateStore: MemoryAxThreadViewStateStore(),
    createThread: (_) async => throw StateError('Not used'),
    onOpenThread: (_) {},
  ))));
  await tester.pumpAndSettle();
  // Workspace lives in the collapsed Settings area.
  await tester.tap(find.text('Settings'));
  await tester.pumpAndSettle();
}

void main() {
  folderSelectionTests();
  testWidgets('support spaces do not show an empty Settings section',
      (tester) async {
    final source = SpaceSettingsSource();
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NewThreadPage(
      space: const AxSpace(
          id: 'S',
          name: 'Support',
          branch: '',
          lastActivity: 'now',
          kind: 'direct',
          isSupport: true),
      dataSource: source,
      discussionCache: AxDiscussionCache.forSource(source),
      workHistoryCache: AxWorkHistoryCache.forSource(source),
      threadViewStateStore: MemoryAxThreadViewStateStore(),
      createThread: (_) async => throw StateError('Not used'),
      onOpenThread: (_) {},
    ))));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
    expect(find.byKey(const ValueKey('space-show-ai-history-setting')),
        findsNothing);
  });

  testWidgets('AI History is hidden by default and owners can expose it',
      (tester) async {
    final source = SpaceSettingsSource();
    await pumpSpace(tester, source, ownerSpace);
    final setting = find.byKey(const ValueKey('space-show-ai-history-setting'));
    final toggle = find.descendant(of: setting, matching: find.byType(Switch));
    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(find.text('Show execution history in this Space\'s Threads.'),
        findsNothing);
    expect(tester.getSize(setting).height, lessThanOrEqualTo(48));
    expect(tester.getSize(setting).width, 500);
    // Every Settings row shares one label column and type scale: labels
    // start at the same x, and values align at the right edge.
    final workspaceLabel = find.text('Workspace');
    final historyLabel = find.text('AI History tab');
    expect(tester.getTopLeft(historyLabel).dx,
        tester.getTopLeft(workspaceLabel).dx);
    expect(tester.widget<Text>(historyLabel).style?.fontSize,
        tester.widget<Text>(workspaceLabel).style?.fontSize);
    expect(
        (tester.getRect(toggle).right -
                tester
                    .getRect(find.byKey(const ValueKey('space-workspace')))
                    .right)
            .abs(),
        lessThanOrEqualTo(8));

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(source.savedSettings, {'showAiHistory': true});
  });

  testWidgets('settings rows have consistent spacing', (tester) async {
    final source = FolderSource();
    await pumpSpace(tester, source, ownerSpace);
    final workspace = tester.getCenter(find.text('Workspace')).dy;
    final folders = tester.getCenter(find.text('Additional folders')).dy;
    final history = tester.getCenter(find.text('AI History tab')).dy;
    // The inherited Workspace explanation occupies its own line.
    expect(folders, greaterThan(workspace));
    expect(history - folders, closeTo(40, 2));
  });

  testWidgets('a Space without a Workspace asks the owner to choose one',
      (tester) async {
    final source = WorkflowSource()..selectedSpaceWorkspaces['S'] = null;
    await pumpSpace(tester, source, ownerSpace);
    expect(find.byKey(const ValueKey('space-workspace')), findsOneWidget);
    final selector = find.byKey(const ValueKey('space-workspace'));
    expect(tester.getRect(selector).top,
        greaterThan(tester.getRect(find.text('Settings')).bottom));
    expect(tester.getRect(selector).bottom,
        lessThan(tester.getRect(find.text('Members')).top));
    expect(tester.getRect(find.text('Members')).bottom,
        lessThan(tester.getRect(find.text('Active')).top));

    expect(find.text('No Workspace'), findsOneWidget);
    expect(find.text('Choose a Workspace to run Work in this Space.'),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('space-workspace')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second Workspace').last);
    await tester.pumpAndSettle();
    expect(find.text('Change Workspace?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-space-workspace')));
    await tester.pumpAndSettle();

    expect(source.selectedSpaceWorkspaces['S'], 'other');
    expect(find.textContaining('Choose a Workspace to run Work'), findsNothing);
    expect(find.textContaining('Threads use this Workspace'), findsNothing);
  });

  testWidgets('choosing the current Workspace again saves nothing',
      (tester) async {
    final source = WorkflowSource()..selectedSpaceWorkspaces['S'] = 'ws';
    await pumpSpace(tester, source, ownerSpace);
    await tester.tap(find.byKey(const ValueKey('space-workspace')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('First Workspace').last);
    await tester.pumpAndSettle();
    expect(find.text('Change Workspace?'), findsNothing);
    expect(source.workspaceWrites, 0);
  });

  testWidgets('narrow Space shows Workspace under Settings', (tester) async {
    final source = WorkflowSource();
    await pumpSpace(tester, source, ownerSpace);
    await tester.binding.setSurfaceSize(const Size(600, 1000));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('space-workspace'))).top,
        greaterThan(tester.getRect(find.text('Settings')).bottom));
    expect(tester.getRect(find.text('Settings')).bottom,
        lessThan(tester.getRect(find.text('Members')).top));
    expect(tester.getRect(find.text('Members')).bottom,
        lessThan(tester.getRect(find.text('Active')).top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling keeps the current Workspace', (tester) async {
    final source = WorkflowSource();
    await pumpSpace(tester, source, ownerSpace);
    await tester.tap(find.byKey(const ValueKey('space-workspace')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second Workspace').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(source.selectedSpaceWorkspaces, isEmpty);
    expect(source.workspaceWrites, 0);
  });

  testWidgets('the owner can detach the Workspace after confirming',
      (tester) async {
    final source = WorkflowSource()..selectedSpaceWorkspaces['S'] = 'other';
    await pumpSpace(tester, source, ownerSpace);
    await tester.tap(find.byKey(const ValueKey('space-workspace')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No Workspace').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('no Workspace, so no Work can run'),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-space-workspace')));
    await tester.pumpAndSettle();
    expect(source.selectedSpaceWorkspaces['S'], isNull);
    expect(source.workspaceWrites, 1);
  });

  testWidgets('other members see no Workspace settings', (tester) async {
    final source = WorkflowSource()..selectedSpaceWorkspaces['S'] = 'other';
    await pumpSpace(tester, source, memberSpace);
    expect(find.byKey(const ValueKey('space-workspace')), findsNothing);
    expect(find.textContaining('Workspace'), findsNothing);
  });

  testWidgets('owner attaches Workspace folders and is warned before detaching',
      (tester) async {
    final source = FolderSource();
    await pumpSpace(tester, source, ownerSpace);
    final button = find.byKey(const ValueKey('space-additional-folders'));
    expect(button, findsOneWidget);
    final history = find.byKey(const ValueKey('space-show-ai-history-setting'));
    expect(tester.getRect(button).right,
        closeTo(tester.getRect(history).right, 8));

    await tester.tap(button);
    await tester.pumpAndSettle();
    final missing = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('space-folder-folder-00000000000000b2')));
    expect(missing.onChanged, isNull,
        reason: 'A missing folder cannot be newly attached.');
    await tester.tap(
        find.byKey(const ValueKey('space-folder-folder-00000000000000a1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-space-folders')));
    await tester.pumpAndSettle();
    expect(source.saves.single, ['folder-00000000000000a1']);
    // Label column "Additional folders", attached folder names as the value.
    expect(find.text('Additional folders'), findsOneWidget);
    expect(find.text('api'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('space-workspace')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second Workspace').last);
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Its additional folder is detached; files on '
            'your computer are not changed.'),
        findsOneWidget);
  });

  testWidgets('folders stay hidden when the owner does not own the Workspace',
      (tester) async {
    await pumpSpace(tester, FolderSource(eligible: false), ownerSpace);
    expect(find.byKey(const ValueKey('space-workspace')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('space-additional-folders')), findsNothing);
  });

  testWidgets('members never load additional folders', (tester) async {
    await pumpSpace(tester, FolderSource(), memberSpace);
    expect(
        find.byKey(const ValueKey('space-additional-folders')), findsNothing);
  });
}

class DeviceFolderSource extends WorkflowSource
    implements AxWorkersUxFeatureSource, AxSpaceFolderDataSource {
  AxDeviceFolder? chosen;
  final removed = <String>[];
  late List<AxDeviceFolder> listed = [...folders];
  static const folders = [
    AxDeviceFolder(
        deviceId: 'dev-0000000000000001',
        deviceName: 'Mac',
        folderId: 'fld-0000000000000001',
        displayName: 'Syntila (Documents)',
        writable: true,
        online: true),
    AxDeviceFolder(
        deviceId: 'dev-0000000000000001',
        deviceName: 'Mac',
        folderId: 'fld-0000000000000002',
        displayName: 'Syntila (Projects)',
        writable: true,
        online: true),
  ];

  @override
  Future<bool> workersUxEnabled() async => true;
  @override
  Future<List<AxDeviceFolder>> loadDeviceFolders() async => [...listed];
  @override
  Future<int> removeDeviceFolders(String deviceId,
      {String? folderId, bool dryRun = false}) async {
    final hit = listed.where((f) =>
        f.deviceId == deviceId && (folderId == null || f.folderId == folderId));
    final used = hit.where((f) => f.folderId == chosen?.folderId).length;
    if (!dryRun) {
      removed.add(folderId ?? deviceId);
      listed = [
        for (final f in listed)
          if (!hit.contains(f)) f
      ];
      if (used > 0) chosen = null;
    }
    return used;
  }

  @override
  Future<AxSpaceFolder> loadSpaceFolder(String spaceId) async =>
      AxSpaceFolder(eligible: true, folder: chosen);
  @override
  Future<AxSpaceFolder> setSpaceFolder(String spaceId,
      {required String deviceId, required String folderId}) async {
    chosen = folders.firstWhere((f) => f.folderId == folderId);
    return loadSpaceFolder(spaceId);
  }

  @override
  Future<void> clearSpaceFolder(String spaceId) async => chosen = null;
}

void folderSelectionTests() {
  testWidgets('the Space settings let the owner select a folder',
      (tester) async {
    final source = DeviceFolderSource();
    await pumpSpace(tester, source, ownerSpace);
    expect(find.text('Select folder'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('space-folder')));
    await tester.pumpAndSettle();
    expect(find.text('Syntila (Documents)'), findsOneWidget);
    expect(find.text('Syntila (Projects)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey(
        'space-folder-choice-dev-0000000000000001-fld-0000000000000002')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('space-folder-save')));
    await tester.pumpAndSettle();
    expect(source.chosen?.folderId, 'fld-0000000000000002');
    expect(find.textContaining('Syntila (Projects) · Mac'), findsOneWidget);
  });

  testWidgets('an offline computer can be removed after a warning',
      (tester) async {
    final source = DeviceFolderSource();
    source.listed = [
      const AxDeviceFolder(
          deviceId: 'dev-0000000000000009',
          deviceName: 'Old Mac',
          folderId: 'fld-0000000000000009',
          displayName: 'Old',
          writable: true,
          online: false),
      ...DeviceFolderSource.folders,
    ];
    source.chosen = source.listed.first;
    await pumpSpace(tester, source, ownerSpace);
    await tester.tap(find.byKey(const ValueKey('space-folder')));
    await tester.pumpAndSettle();
    // Online folders cannot be removed here.
    expect(
        find.byKey(const ValueKey(
            'space-folder-remove-dev-0000000000000001-fld-0000000000000001')),
        findsNothing);
    await tester.tap(find.byKey(
        const ValueKey('space-folder-remove-device-dev-0000000000000009')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Used by 1 Space.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('space-folder-remove-confirm')));
    await tester.pumpAndSettle();
    expect(source.removed, ['dev-0000000000000009']);
    expect(find.text('Old'), findsNothing);
    expect(find.text('Syntila (Projects)'), findsOneWidget);
  });

  testWidgets('other members see no folder setting', (tester) async {
    await pumpSpace(tester, DeviceFolderSource(), memberSpace);
    expect(find.byKey(const ValueKey('space-folder')), findsNothing);
  });
}
