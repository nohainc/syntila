import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_app.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/ax_stores.dart';
import 'package:syntila_app/src/ax/sync/ax_space_threads.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/features/navigation/ax_shell_context.dart';
import 'package:syntila_app/src/features/navigation/space_tree.dart';
import 'package:syntila_app/src/features/common/space_color.dart';
import 'package:syntila_design/syntila_design.dart';
import 'package:syntila_app/src/navigation/ax_navigation.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'ax_fixture_data.dart';
import 'ax_fixture_realtime.dart';
import 'ax_space_navigation_test.dart' show HistoryNavigation;
import 'package:syntila_app/src/ax/sync/ax_realtime_cache_router.dart';
import 'ax_fixture_snapshot.dart';

const a = AxSpace(
    id: 'space-auth',
    name: 'Space A',
    branch: '',
    lastActivity: '',
    settings: {'color': 'Blue'});
const b = AxSpace(
    id: 'atlas',
    name: 'Space B',
    branch: '',
    lastActivity: '',
    settings: {'color': 'Rose'});
AxThread stream(String space, String name,
        {String updatedAt = '', String? id}) =>
    AxThread(
        id: id ?? '$space-stream',
        spaceId: space,
        name: name,
        lead: '',
        status: 'active',
        brief: '',
        primaryWorkspace: '',
        queueStatus: '',
        updatedAt: updatedAt);

class ControlledSource extends AxFixtureDataSource {
  final requests = <String, List<Completer<List<AxThread>>>>{};
  int snapshots = 0;

  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async =>
      [a, b];

  @override
  Future<AxSpace> loadSpace({required String spaceId}) async =>
      (await loadSpaces()).firstWhere((s) => s.id == spaceId);

  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) {
    final request = Completer<List<AxThread>>();
    requests.putIfAbsent(spaceId, () => []).add(request);
    return request.future;
  }

  @override
  Future<AxSnapshot> loadBootstrapState(
      {String? spaceId, String? workspaceId}) async {
    snapshots++;
    final fixture = axFixtureSnapshot();
    return AxSnapshot(
        spaces: [a, b],
        workspaces: fixture.workspaces,
        tasks: const [],
        findings: const [],
        events: const [],
        artifacts: const []);
  }
}

class UnsortedRecentSource extends AxFixtureDataSource {
  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async => [
        const AxSpace(
          id: 'older-space',
          name: 'Older Space',
          branch: '',
          lastActivity: '2026-10-01T00:00:00Z',
        ),
        const AxSpace(
          id: 'newer-space',
          name: 'Newer Space',
          branch: '',
          lastActivity: '2026-10-03T00:00:00Z',
        ),
      ];

  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async => [
        AxThread(
          id: 'older-thread',
          spaceId: spaceId,
          name: 'Older Thread',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: '',
          updatedAt: '2026-10-01T00:00:00Z',
        ),
        AxThread(
          id: 'newer-thread',
          spaceId: spaceId,
          name: 'Newer Thread',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: '',
          updatedAt: '2026-10-03T00:00:00Z',
        ),
      ];
}

class MessageActivitySource extends AxFixtureDataSource {
  bool secondThreadHasNewMessage = false;

  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async => [
        stream(spaceId, 'Initially recent',
            id: 'initially-recent', updatedAt: '2026-10-29T10:00:00Z'),
        stream(spaceId, 'New message target',
            id: 'message-target',
            updatedAt: secondThreadHasNewMessage
                ? '2026-10-29T12:00:00Z'
                : '2026-10-29T09:00:00Z'),
      ];
}

void main() {
  testWidgets(
      'recent Threads load globally, reorder by activity, and cap at the limit',
      (tester) async {
    final source = ControlledSource();
    final cache = AxSpaceThreads(source);
    AxNavigation? selected;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SpaceTree(
      shellContext: AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: const [a, b],
        spaceThreads: cache,
        expandedSpaceIds: const {'atlas'},
      ),
      showRecentThreads: true,
      recentThreadsCount: 8,
      onNavigateTo: (navigation) => selected = navigation,
    ))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(source.requests[a.id], hasLength(1));
    expect(source.requests[b.id], hasLength(1));
    source.requests[a.id]!.single.complete([
      for (var index = 0; index < 5; index++)
        stream(a.id, 'A $index',
            id: 'a-$index', updatedAt: '2026-10-29T10:0$index:00Z'),
    ]);
    source.requests[b.id]!.single.complete([
      for (var index = 0; index < 5; index++)
        stream(b.id, 'B $index',
            id: 'b-$index', updatedAt: '2026-10-29T11:0$index:00Z'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('RECENT THREADS'), findsOneWidget);
    expect(
        tester.getTopLeft(find.text('RECENT THREADS')).dy,
        lessThan(tester
            .getTopLeft(find.byKey(ValueKey('sidebar-space-row-${a.id}')))
            .dy));
    expect(find.byKey(const ValueKey('recent-thread-row-atlas-b-4')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('recent-thread-row-space-auth-a-2')),
        findsOneWidget);
    expect(find.text('A 0'), findsNothing);
    expect(find.text('A 1'), findsNothing);
    Finder recentTitle(String id, String name) => find.descendant(
        of: find.byKey(ValueKey('recent-thread-row-${b.id}-$id')),
        matching: find.text(name));
    final recentB4 = recentTitle('b-4', 'B 4');
    final originalB4 = find.descendant(
        of: find.byKey(const ValueKey('sidebar-thread-row-b-4')),
        matching: find.text('B 4'));
    expect(tester.getTopLeft(recentB4).dy,
        lessThan(tester.getTopLeft(recentTitle('b-3', 'B 3')).dy));
    expect(tester.getTopLeft(recentB4).dx, tester.getTopLeft(originalB4).dx);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('recent-thread-row-atlas-b-4')),
            matching: find.text(b.name)),
        findsNothing);

    final marker =
        find.byKey(const ValueKey('recent-thread-space-marker-atlas-b-4'));
    expect(marker, findsNothing);
    expect(find.byTooltip(b.name), findsWidgets);
    final folder = tester.widget<SyntilaFolderIcon>(find.descendant(
        of: find.byKey(ValueKey('sidebar-space-row-${b.id}')),
        matching: find.byType(SyntilaFolderIcon)));
    expect(
        folder.color, spaceIdentityColor(b.settings['color'], isDark: false));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(recentB4));
    await tester.pumpAndSettle();
    expect(marker, findsOneWidget);
    final markerDecoration =
        tester.widget<Container>(marker).decoration! as BoxDecoration;
    expect(markerDecoration.color, folder.color);
    final recentMenu = find.descendant(
        of: find.byKey(const ValueKey('recent-thread-row-atlas-b-4')),
        matching: find.byTooltip('Thread menu'));
    expect(recentMenu, findsOneWidget);
    await tester.tap(recentMenu);
    await tester.pumpAndSettle();
    expect(find.text('Archive Thread'), findsOneWidget);
    await tester.tapAt(const Offset(790, 590));
    await tester.pumpAndSettle();

    cache.engine.update(
        cache.query(a.id),
        (_) => [
              stream(a.id, 'A newest',
                  id: 'a-newest', updatedAt: '2026-10-29T12:00:00Z'),
              for (var index = 0; index < 4; index++)
                stream(a.id, 'A $index',
                    id: 'a-$index', updatedAt: '2026-10-29T10:0$index:00Z'),
            ]);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('A newest')).dy,
        lessThan(tester.getTopLeft(recentB4).dy));

    await tester.tap(find.text('A newest'));
    expect(selected?.spaceId, a.id);
    expect(selected?.threadId, 'a-newest');
  });

  testWidgets('uncolored Space has a neutral icon and no recent marker',
      (tester) async {
    final neutral = a.copyWith(settings: const {});
    final thread = stream(a.id, 'Neutral thread', id: 'neutral');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SizedBox(
              width: 260,
              child: SpaceTree(
                shellContext: AxShellContext(
                  navigation: const AxNavigation.home(),
                  spaces: [neutral],
                  threadsBySpace: {
                    a.id: [thread]
                  },
                ),
                showRecentThreads: true,
                onNavigateTo: (_) {},
              ))),
    ));
    await tester.pump();
    final folder =
        tester.widget<SyntilaFolderIcon>(find.byType(SyntilaFolderIcon));
    expect(folder.color, SyntilaColors.navigationTextMuted(false));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(
        find.byKey(const ValueKey('recent-thread-row-space-auth-neutral'))));
    await tester.pump();
    expect(
        find.byKey(
            const ValueKey('recent-thread-space-marker-space-auth-neutral')),
        findsNothing);
  });

  testWidgets('recent Space marker stays at the left without moving activity',
      (tester) async {
    final thread =
        stream(a.id, 'Unread thread', id: 'unread').copyWith(hasUnread: true);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SizedBox(
              width: 260,
              child: SpaceTree(
                shellContext: AxShellContext(
                  navigation: const AxNavigation.home(),
                  spaces: const [a],
                  threadsBySpace: {
                    a.id: [thread]
                  },
                ),
                showRecentThreads: true,
                onNavigateTo: (_) {},
              ))),
    ));
    await tester.pump();
    final row =
        find.byKey(const ValueKey('recent-thread-row-space-auth-unread'));
    final indicator = find.descendant(
        of: row,
        matching: find.byKey(const ValueKey('sidebar-unread-indicator')));
    final originalPosition = tester.getTopLeft(indicator);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(row));
    await tester.pump();
    final marker = find
        .byKey(const ValueKey('recent-thread-space-marker-space-auth-unread'));
    expect(tester.getTopLeft(marker).dx, tester.getTopLeft(row).dx);
    expect(tester.getTopLeft(indicator), originalPosition);
    expect(tester.getTopRight(marker).dx, lessThan(originalPosition.dx));
  });

  testWidgets('active highlight follows the selected Thread row source',
      (tester) async {
    var navigation = const AxNavigation.home();
    final thread = stream(a.id, 'Shared row',
        id: 'shared-row', updatedAt: '2026-10-29T12:00:00Z');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SpaceTree(
            shellContext: AxShellContext(
              navigation: navigation,
              spaces: const [a],
              threadsBySpace: {
                a.id: [thread],
              },
              expandedSpaceIds: const {'space-auth'},
            ),
            showRecentThreads: true,
            onNavigateTo: (value) => setState(() => navigation = value),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    const recentKey = ValueKey('recent-thread-row-space-auth-shared-row');
    const originalKey = ValueKey('sidebar-thread-row-shared-row');
    BoxDecoration rowDecoration(Key key) => tester
        .widgetList<Container>(find.descendant(
            of: find.byKey(key), matching: find.byType(Container)))
        .map((container) => container.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((decoration) => decoration.borderRadius != null);

    await tester.tap(find.byKey(recentKey));
    await tester.pumpAndSettle();
    expect(rowDecoration(recentKey).color, isNot(Colors.transparent));
    expect(
        find.byKey(
            const ValueKey('recent-thread-space-marker-space-auth-shared-row')),
        findsOneWidget);
    expect(rowDecoration(originalKey).color, Colors.transparent);

    await tester.tap(find.byKey(originalKey));
    await tester.pumpAndSettle();
    expect(rowDecoration(recentKey).color, Colors.transparent);
    expect(rowDecoration(originalKey).color, isNot(Colors.transparent));
  });

  testWidgets('a new user message reorders Recent Threads', (tester) async {
    final source = MessageActivitySource();
    final cache = AxSpaceThreads(source);
    final router = AxRealtimeCacheRouter(cache.engine,
        activityDebounce: const Duration(milliseconds: 1));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpaceTree(
          shellContext: AxShellContext(
            navigation: const AxNavigation.home(),
            spaces: const [a],
            spaceThreads: cache,
          ),
          showRecentThreads: true,
          onNavigateTo: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    Finder recentTitle(String threadId, String title) => find.descendant(
        of: find.byKey(ValueKey('recent-thread-row-${a.id}-$threadId')),
        matching: find.text(title));
    final initiallyRecent = recentTitle('initially-recent', 'Initially recent');
    final messageTarget = recentTitle('message-target', 'New message target');
    expect(tester.getTopLeft(initiallyRecent).dy,
        lessThan(tester.getTopLeft(messageTarget).dy));

    source.secondThreadHasNewMessage = true;
    await router.handle({
      'type': 'discussion.created',
      'spaceId': a.id,
      'threadId': 'message-target',
      'payload': {
        'entityId': 'message-1',
        'threadId': 'message-target',
      },
    });
    await tester.pumpAndSettle(const Duration(milliseconds: 10));

    expect(tester.getTopLeft(messageTarget).dy,
        lessThan(tester.getTopLeft(initiallyRecent).dy));
  });

  test('sorts Spaces and Threads by their most recent update', () async {
    final source = UnsortedRecentSource();
    final store = AxStore(source);

    await store.spaces.refresh();
    await store.spaceThreads.ensure('newer-space');

    expect(store.spaces.items.map((space) => space.id),
        ['newer-space', 'older-space']);
    expect(store.spaceThreads.peek('newer-space').map((thread) => thread.id),
        ['newer-thread', 'older-thread']);
    store.dispose();
  });

  test('bootstrap and SpaceStore never own nested Threads', () async {
    final store = AxStore(const AxFixtureDataSource());
    await store.spaceThreads.ensure(a.id);
    final snapshot = await store.loadBootstrapState(spaceId: b.id);
    expect(snapshot.spaces.every((p) => p.threads.isEmpty), isTrue);
    expect(store.spaces.items.every((p) => p.threads.isEmpty), isTrue);
    expect(
        store.spaceThreads.peek(a.id).single.name, 'Authentication hardening');
    expect(store.spaceThreads.peek(b.id), isEmpty);
  });

  test('five Space collection callers deduplicate and old generation loses',
      () async {
    final source = ControlledSource();
    final cache = AxSpaceThreads(source);
    final callers = List.generate(5, (_) => cache.ensure(a.id));
    expect(source.requests[a.id], hasLength(1));
    expect(callers.every((future) => identical(future, callers.first)), isTrue);
    cache.engine.invalidate(cache.query(a.id).key);
    final replacement = cache.ensure(a.id);
    expect(source.requests[a.id], hasLength(2));
    source.requests[a.id]!.last.complete([stream(a.id, 'New result')]);
    await replacement;
    source.requests[a.id]!.first.complete([stream(a.id, 'Old result')]);
    await Future.wait(callers);
    expect(cache.peek(a.id).single.name, 'New result');
    await cache.ensure(a.id);
    expect(source.requests[a.id], hasLength(2));
  });

  testWidgets('selected thread menu uses the application menu surface',
      (tester) async {
    final source = ControlledSource();
    final cache = AxSpaceThreads(source);
    final load = cache.ensure(a.id);

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SpaceTree(
      shellContext: AxShellContext(
        navigation: AxNavigation.thread(a.id, '${a.id}-stream'),
        spaces: const [a],
        spaceThreads: cache,
        expandedSpaceIds: {a.id},
      ),
      onCreateSpace: () {},
      onNavigateTo: (_) {},
      onToggleSpaceExpanded: (_) {},
    ))));
    source.requests[a.id]!.single.complete([stream(a.id, 'A thread')]);
    await load;
    await tester.pumpAndSettle();

    expect(find.byTooltip('Thread menu'), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(find.byType(MenuAnchor), findsOneWidget);

    await tester.tap(find.byTooltip('Thread menu'));
    await tester.pumpAndSettle();

    // Rename, Archive, Delete; clearing history lives in the Thread header.
    expect(find.byType(MenuItemButton), findsNWidgets(3));
    expect(find.text('Clear Chat History'), findsNothing);
    expect(find.text('Clear Work History'), findsNothing);
    expect(find.text('Rename Thread'), findsOneWidget);
    expect(find.text('Delete Thread'), findsOneWidget);

    await tester.tap(find.text('Rename Thread'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('selected thread menu dispatches thread actions', (tester) async {
    final source = ControlledSource();
    final cache = AxSpaceThreads(source);
    final load = cache.ensure(a.id);
    String? renamed;
    bool? archived;
    var deleted = false;

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SpaceTree(
      shellContext: AxShellContext(
        navigation: AxNavigation.thread(a.id, '${a.id}-stream'),
        spaces: const [a],
        spaceThreads: cache,
        expandedSpaceIds: {a.id},
      ),
      onCreateSpace: () {},
      onNavigateTo: (_) {},
      onToggleSpaceExpanded: (_) {},
      onRenameThread: (_, name) async => renamed = name,
      onSetThreadArchived: (_, value) async => archived = value,
      onDeleteThread: (_) async => deleted = true,
    ))));
    source.requests[a.id]!.single.complete([stream(a.id, 'A thread')]);
    await load;
    await tester.pumpAndSettle();

    Future<void> openMenu() async {
      await tester.tap(find.byTooltip('Thread menu'));
      await tester.pumpAndSettle();
    }

    await openMenu();
    await tester.tap(find.text('Rename Thread'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Renamed thread');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(renamed, 'Renamed thread');

    await openMenu();
    await tester.tap(find.text('Archive Thread'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
    await tester.pumpAndSettle();
    expect(archived, isTrue);

    await openMenu();
    await tester.tap(find.text('Delete Thread'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
  });

  testWidgets(
      'A B A: fresh return makes zero reads; stale return stays visible with one read',
      (tester) async {
    final source = ControlledSource();
    var now = DateTime.utc(2026);
    final cache =
        AxSpaceThreads(source, engine: AxSyncEngine(clock: () => now));
    var nav = const AxNavigation.space('space-auth');
    final expanded = <String>{a.id};
    late StateSetter navigate;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: StatefulBuilder(builder: (context, update) {
      navigate = update;
      return SpaceTree(
        shellContext: AxShellContext(
            navigation: nav,
            spaces: const [a, b],
            spaceThreads: cache,
            expandedSpaceIds: expanded),
        onCreateSpace: () {},
        onNavigateTo: (value) {
          update(() {
            nav = value;
            expanded.add(value.spaceId!);
          });
          // Match the shell's navigation contract: ensure the selected resource.
          unawaited(cache.ensure(value.spaceId!));
        },
        onToggleSpaceExpanded: (id) => update(() {
          if (!expanded.remove(id)) expanded.add(id);
        }),
      );
    }))));
    source.requests[a.id]!.single.complete([stream(a.id, 'A cached')]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Space B'));
    await tester.pump();
    expect(find.text('A cached'), findsOneWidget);
    source.requests[b.id]!.single.complete([stream(b.id, 'B cached')]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Space A'));
    await tester.pump(); // First frame, without waiting for network completion.
    expect(find.text('A cached'), findsOneWidget);
    expect(find.text('B cached'), findsOneWidget);
    expect(expanded, {a.id, b.id});
    expect(source.requests.values.map((calls) => calls.length), [1, 1]);
    navigate(() => nav = const AxNavigation.space('atlas'));
    await tester.pump();
    now = now.add(const Duration(minutes: 2));
    await tester.tap(find.text('Space A'));
    await tester.pump();
    expect(find.text('A cached'), findsOneWidget);
    expect(find.text('B cached'), findsOneWidget);
    expect(find.text('Loading Threads…'), findsNothing);
    expect(source.requests[a.id], hasLength(2));
    await tester.pump();
    expect(source.requests[a.id], hasLength(2));
    source.requests[a.id]!.last.complete([stream(a.id, 'A refreshed')]);
    expect(source.requests[b.id], hasLength(1));
    await tester.pumpAndSettle();
    expect(find.text('A refreshed'), findsOneWidget);
    expect(expanded, {a.id, b.id});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'background Space realtime and reconnect keep both expanded collections visible',
      (tester) async {
    final source = ControlledSource();
    final cache = AxSpaceThreads(source);
    final router = AxRealtimeCacheRouter(cache.engine);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SpaceTree(
      shellContext: AxShellContext(
          navigation: const AxNavigation.space('atlas'),
          spaces: const [a, b],
          spaceThreads: cache,
          expandedSpaceIds: {a.id, b.id}),
      onCreateSpace: () {},
      onNavigateTo: (_) {},
      onToggleSpaceExpanded: (_) {},
    ))));
    source.requests[a.id]!.single.complete([stream(a.id, 'A cached')]);
    source.requests[b.id]!.single.complete([stream(b.id, 'B cached')]);
    await tester.pumpAndSettle();
    final event = router.handle({
      'type': 'thread.updated',
      'spaceId': a.id,
      'threadId': '${a.id}-stream'
    });
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('A cached'), findsOneWidget);
    expect(find.text('B cached'), findsOneWidget);
    expect(source.requests[b.id], hasLength(1));
    source.requests[a.id]!.last.complete([stream(a.id, 'A remote edit')]);
    await event;
    await tester.pumpAndSettle();
    expect(find.text('A remote edit'), findsOneWidget);
    final recovery = router.handle({
      'type': 'reconnect.required',
      'scope': {'kind': 'space', 'spaceId': a.id}
    });
    await tester.pump();
    expect(find.text('A remote edit'), findsOneWidget);
    expect(find.text('B cached'), findsOneWidget);
    expect(find.text('Loading Threads…'), findsNothing);
    expect(source.requests[a.id], hasLength(3));
    expect(source.requests[b.id], hasLength(1));
    source.requests[a.id]!.last.complete([stream(a.id, 'A recovered')]);
    await recovery;
    await tester.pumpAndSettle();
    expect(find.text('A recovered'), findsOneWidget);
    expect(find.text('B cached'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'A survives slow B navigation and returning uses the same collection',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = ControlledSource();
    await tester.pumpWidget(MaterialApp(
        home: SyntilaAppShell(
            services: const DefaultPlatformServices(),
            dataSource: source,
            realtimeClient: TestRealtime(),
            browserNavigation: HistoryNavigation(Uri.parse('/')))));
    await tester.pumpAndSettle();
    final tree = find.byType(SpaceTree);
    Finder text(String name) =>
        find.descendant(of: tree, matching: find.text(name));
    Finder spaceName(String spaceId, String name) => find.descendant(
        of: find.byKey(ValueKey('sidebar-space-row-$spaceId')),
        matching: find.text(name));
    Finder spaceThread(String spaceId, String name) => find.descendant(
        of: find.byKey(ValueKey('sidebar-thread-row-$spaceId-stream')),
        matching: find.text(name));
    await tester.tap(spaceName(a.id, 'Space A'));
    await tester.pump();
    expect(source.requests[a.id], hasLength(1));
    source.requests[a.id]!.single.complete([stream(a.id, 'A cached')]);
    await tester.pumpAndSettle();
    await tester.tap(spaceName(b.id, 'Space B'));
    await tester.pump();
    expect(spaceThread(a.id, 'A cached'), findsOneWidget);
    expect(text('Loading Threads…'), findsOneWidget);
    expect(source.requests[b.id], hasLength(1));
    expect(source.snapshots, 1);
    source.requests[b.id]!.single.complete([stream(b.id, 'B cached')]);
    await tester.pumpAndSettle();
    expect(spaceThread(a.id, 'A cached'), findsOneWidget);
    expect(spaceThread(b.id, 'B cached'), findsOneWidget);
    await tester.tap(spaceName(a.id, 'Space A'));
    await tester.pump();
    expect(spaceThread(a.id, 'A cached'), findsOneWidget);
    expect(spaceThread(b.id, 'B cached'), findsOneWidget);
    expect(source.requests[a.id], hasLength(1));
    expect(source.snapshots, 1);
    // Only clicking the already-focused Space is an explicit collapse.
    await tester.tap(spaceName(a.id, 'Space A'));
    await tester.pumpAndSettle();
    expect(spaceThread(a.id, 'A cached'), findsNothing);
    expect(spaceThread(b.id, 'B cached'), findsOneWidget);
    await tester.tap(spaceName(a.id, 'Space A'));
    await tester.pump();
    expect(spaceThread(a.id, 'A cached'), findsOneWidget);
    expect(source.requests[a.id], hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'stale row retains data, scopes updates and preserves collapse during completion',
      (tester) async {
    final source = ControlledSource();
    var now = DateTime.utc(2026);
    final cache =
        AxSpaceThreads(source, engine: AxSyncEngine(clock: () => now));
    final first = cache.ensure(a.id);
    source.requests[a.id]!.single.complete([stream(a.id, 'A cached')]);
    await first;
    now = now.add(const Duration(minutes: 2));
    final expanded = <String>{a.id, b.id};
    var nav = const AxNavigation.home();
    var rootBuilds = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: StatefulBuilder(builder: (context, update) {
      rootBuilds++;
      return SpaceTree(
          shellContext: AxShellContext(
              navigation: nav,
              spaces: const [a, b],
              spaceThreads: cache,
              expandedSpaceIds: expanded),
          onCreateSpace: () {},
          onNavigateTo: (value) => update(() => nav = value),
          onToggleSpaceExpanded: (id) => update(() {
                if (!expanded.remove(id)) expanded.add(id);
              }));
    }))));
    await tester.pump();
    expect(find.text('A cached'), findsOneWidget);
    expect(source.requests[a.id], hasLength(2));
    final builds = rootBuilds;
    source.requests[b.id]!.single.complete([stream(b.id, 'B cached')]);
    await tester.pumpAndSettle();
    expect(
        rootBuilds, builds); // Query updates do not rebuild the owning shell.
    tester
        .widget<SpaceTree>(find.byType(SpaceTree))
        .onToggleSpaceExpanded!(a.id);
    await tester.pump();
    source.requests[a.id]!.last.complete([stream(a.id, 'A refreshed')]);
    await tester.pumpAndSettle();
    expect(find.text('A refreshed'), findsNothing);
    expect(expanded, {b.id});
    await tester.tap(find.text('Space A'));
    await tester.pump();
    expect(find.text('A refreshed'), findsOneWidget);
    expect(find.text('B cached'), findsOneWidget);
    expect(source.requests[a.id], hasLength(2));
  });

  testWidgets('cold failure is local and retry works', (tester) async {
    final source = ControlledSource();
    final cache = AxSpaceThreads(source);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SpaceTree(
                shellContext: AxShellContext(
                    navigation: const AxNavigation.home(),
                    spaces: const [a],
                    spaceThreads: cache,
                    expandedSpaceIds: {a.id}),
                onCreateSpace: () {},
                onNavigateTo: (_) {},
                onToggleSpaceExpanded: (_) {}))));
    source.requests[a.id]!.last.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Retry Threads'), findsOneWidget);
    await tester.tap(find.text('Retry Threads'));
    await tester.pump();
    source.requests[a.id]!.last.complete([stream(a.id, 'Recovered')]);
    await tester.pumpAndSettle();
    expect(find.text('Recovered'), findsOneWidget);
    expect(find.text('Retry Threads'), findsNothing);
  });

  testWidgets('stale refresh failure keeps cached rows', (tester) async {
    final source = ControlledSource();
    final cache = AxSpaceThreads(source);
    final first = cache.ensure(a.id);
    source.requests[a.id]!.single.complete([stream(a.id, 'A cached')]);
    await first;
    cache.engine.invalidate(cache.query(a.id).key);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SpaceTree(
                shellContext: AxShellContext(
                    navigation: const AxNavigation.home(),
                    spaces: const [a],
                    spaceThreads: cache,
                    expandedSpaceIds: {a.id}),
                onCreateSpace: () {},
                onNavigateTo: (_) {},
                onToggleSpaceExpanded: (_) {}))));
    source.requests[a.id]!.last.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('A cached'), findsOneWidget);
    expect(find.text('Loading Threads…'), findsNothing);
    expect(cache.engine.peek(cache.query(a.id)).error, isStateError);
  });
}
