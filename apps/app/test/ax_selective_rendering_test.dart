import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_app.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/ax_stores.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'ax_fixture_data.dart';
import 'ax_fixture_snapshot.dart';

class SelectiveSource extends AxFixtureDataSource {
  List<AxWorker> workers = [];

  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async => [
        for (final space
            in await super.loadSpaces(includeArchived: includeArchived))
          space.copyWith(settings: {...space.settings, 'showAiHistory': true}),
      ];

  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async => workers;
}

void main() {
  test('coalesced view listenables defer and merge synchronous changes',
      () async {
    final first = ValueNotifier<int>(0);
    final second = ValueNotifier<int>(0);
    final merged = AxCoalescedListenable([first, second]);
    addTearDown(() {
      merged.dispose();
      first.dispose();
      second.dispose();
    });
    var notifications = 0;
    merged.addListener(() => notifications++);

    first.value = 1;
    second.value = 1;
    expect(notifications, 0);

    await Future<void>.delayed(Duration.zero);
    expect(notifications, 1);
  });

  testWidgets('defers coalesced notifications triggered during a build',
      (tester) async {
    final source = ValueNotifier<int>(0);
    final merged = AxCoalescedListenable([source]);
    addTearDown(() {
      merged.dispose();
      source.dispose();
    });
    var builds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: merged,
          builder: (context, child) {
            builds++;
            if (builds == 1) source.value = 1;
            return Text('build-$builds');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(builds, greaterThanOrEqualTo(2));
    expect(find.text('build-$builds'), findsOneWidget);
  });

  testWidgets(
      'defers coalesced notifications raised while a layout pass mounts a listener',
      (tester) async {
    final source = ValueNotifier<int>(0);
    final merged = AxCoalescedListenable([source]);
    addTearDown(() {
      merged.dispose();
      source.dispose();
    });
    var builds = 0;
    var notified = false;

    await tester.pumpWidget(
      MaterialApp(
        home: LayoutBuilder(
          builder: (context, constraints) {
            // Runs during layout. The notification must not reach the
            // ListenableBuilder that is being mounted in this same pass.
            if (!notified) {
              notified = true;
              source.value = 1;
            }
            return ListenableBuilder(
              listenable: merged,
              builder: (context, child) {
                builds++;
                return Text('layout-$builds');
              },
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(builds, greaterThanOrEqualTo(2));
    expect(find.text('layout-$builds'), findsOneWidget);
  });

  testWidgets('home route tolerates initial cache notifications',
      (tester) async {
    tester.view.physicalSize = const Size(1800, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: SelectiveSource(),
        initialUri: Uri.parse('/')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('deferred listener crosses the post-frame event boundary',
      (tester) async {
    final source = ValueNotifier<int>(0);
    addTearDown(source.dispose);
    var builds = 0;

    await tester.pumpWidget(MaterialApp(
      home: AxDeferredListenableBuilder(
        listenable: source,
        builder: (context, child) {
          builds++;
          if (builds == 1) source.value = 1;
          return Text('deferred-$builds');
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(builds, greaterThanOrEqualTo(2));

    source.value = 2;
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(builds, greaterThanOrEqualTo(3));
  });

  final builds = <String, int>{};
  void observe() {
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      final type = element.widget.runtimeType.toString();
      builds.update(type, (count) => count + 1, ifAbsent: () => 1);
      final key = element.widget.key;
      if (key is ValueKey<String>) {
        builds.update(key.value, (count) => count + 1, ifAbsent: () => 1);
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
  }

  Future<AxStore> shell(WidgetTester tester, String route) async {
    tester.view.physicalSize = const Size(1800, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: SelectiveSource(),
        initialUri: Uri.parse(route)));
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(SyntilaAppShell));
    return state.store as AxStore;
  }

  for (final spacePage in [true, false]) {
    testWidgets(
        'Worker update leaves shell, sidebar, ${spacePage ? 'Space' : 'Chat and Work history'} untouched',
        (tester) async {
      final space = axFixtureSnapshot().spaces.first;
      final route = spacePage
          ? '/spaces/${space.id}'
          : '/spaces/${space.id}/threads/${space.threads.first.id}';
      final store = await shell(tester, route);
      if (!spacePage) {
        // Composer choices are mounted in Ask AI mode.
        await tester.tap(find.byKey(const ValueKey('composer-mode-ai')));
        await tester.pumpAndSettle();
      }
      observe();
      builds.clear();
      store.syncEngine.update(
          store.catalogs.workers,
          (_) => [
                AxWorker.fromJson({
                  'id': 'new-worker',
                  'workspaceId': 'workspace-fixture',
                  'displayName': 'Fresh Worker',
                  'readinessState': 'ready'
                })
              ]);
      await tester.pumpAndSettle();
      for (final type in [
        'SyntilaAppShell',
        'MaterialApp',
        'AxSidebar',
        'SpaceTree',
        'SpacePage',
        'ThreadPage',
        'AxDiscussionBuilder',
        'work-history-scroll'
      ]) {
        expect(builds[type] ?? 0, 0,
            reason: '$type must not rebuild for Worker inventory');
      }
      if (!spacePage) {
        expect(
            builds['ValueListenableBuilder<ThreadComposerPresentationSnapshot>'] ??
                0,
            greaterThan(0));
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'Work history and Discussion update their own panes independently',
      (tester) async {
    final space = axFixtureSnapshot().spaces.first;
    final id = space.threads.first.id;
    final store = await shell(tester, '/spaces/${space.id}/threads/$id');
    await tester.tap(find.byKey(const ValueKey('ai-history-toggle')));
    await tester.pumpAndSettle();
    observe();
    builds.clear();
    store.workHistory.replace(id, [
      const AxWorkRequest(
        id: 'request-1',
        requestedByName: 'You',
        prompt: 'A Work request',
        workflowId: 'direct',
        workflowVersion: 1,
        status: 'completed',
        createdAt: '2026-10-14T12:00:00Z',
        steps: [],
      )
    ]);
    await tester.pumpAndSettle();
    expect(
        builds['ValueListenableBuilder<ThreadWorkPresentationSnapshot?>'] ?? 0,
        greaterThan(0));
    expect(builds['ThreadPage'] ?? 0, 0);
    expect(builds['SyntilaAppShell'] ?? 0, 0);
    // The Thread shows one pane at a time; return to the Conversation.
    await tester.tap(find.byKey(const ValueKey('ai-history-conversation')));
    await tester.pumpAndSettle();
    builds.clear();
    await store.discussion.synchronize(id, reconcileNewest: true);
    await tester.pumpAndSettle();
    expect(builds['conversation-timeline'] ?? 0, greaterThan(0));
    expect(
        builds['ValueListenableBuilder<ThreadWorkPresentationSnapshot?>'] ?? 0,
        0);
    expect(builds['ThreadPage'] ?? 0, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'Space list updates only its consumers and remains current in sidebar',
      (tester) async {
    final space = axFixtureSnapshot().spaces.first;
    final store = await shell(tester, '/spaces/${space.id}');
    observe();
    builds.clear();
    store.spaces.replace([space.copyWith(name: 'Updated in background')]);
    await tester.pumpAndSettle();
    expect(
        find.byKey(ValueKey('sidebar-space-row-${space.id}')), findsOneWidget);
    expect(builds['SyntilaAppShell'] ?? 0, 0);
    expect(builds['AxSidebar'] ?? 0, 0);
    expect(builds['SpacePage'] ?? 0, 0);
    expect(
        builds['ValueListenableBuilder<List<AxSpace>>'] ?? 0, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'Workflow publication updates controls without rebuilding Chat or history',
      (tester) async {
    final space = axFixtureSnapshot().spaces.first;
    final id = space.threads.first.id;
    final store = await shell(tester, '/spaces/${space.id}/threads/$id');
    await tester.tap(find.byKey(const ValueKey('composer-mode-ai')));
    await tester.pumpAndSettle();
    observe();
    builds.clear();
    store.syncEngine.update(
        store.catalogs.workflows,
        (_) => [
              AxBuiltinWorkflow.fromJson(
                  {'id': 'direct', 'version': 2, 'name': 'Published workflow'})
            ]);
    await tester.pumpAndSettle();
    expect(
        builds['ValueListenableBuilder<ThreadComposerPresentationSnapshot>'] ??
            0,
        greaterThan(0));
    for (final type in [
      'SyntilaAppShell',
      'AxSidebar',
      'conversation-timeline',
      'ThreadPage',
      'work-history-scroll'
    ]) {
      expect(builds[type] ?? 0, 0, reason: type);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reconnect status and notification count update locally',
      (tester) async {
    final space = axFixtureSnapshot().spaces.first;
    final store = await shell(tester, '/spaces/${space.id}');
    observe();
    builds.clear();
    store.realtimeStatus.value = (true, 'Reconnecting selected resources');
    store.unreadNotifications.value = 3;
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Reconnecting selected resources'), findsOneWidget);
    for (final type in [
      'SyntilaAppShell',
      'AxSidebar',
      'SpaceTree',
      'SpacePage'
    ]) {
      expect(builds[type] ?? 0, 0, reason: type);
    }
    store.realtimeStatus.value = (false, null);
    await tester.pumpWidget(const SizedBox());
  });

  test('Space list writes do not notify the execution projection', () {
    final store = AxStore(SelectiveSource());
    var executionUpdates = 0;
    store.executionChanges.addListener(() => executionUpdates++);
    final fixture = axFixtureSnapshot();
    store.spaces.replace(fixture.spaces);
    store.replaceExecution(fixture);
    final previous = executionUpdates;
    store.spaces.replace([store.spaces.items.first.copyWith(name: 'Renamed')]);
    expect(executionUpdates, previous);
    expect(store.spaces.items.first.name, 'Renamed');
    store.dispose();
  });

  test('execution replacement cannot overwrite collaboration or session state',
      () {
    final store = AxStore(SelectiveSource());
    final fixture = axFixtureSnapshot();
    final renamed = fixture.spaces.first.copyWith(name: 'Cached space');
    store.spaces.replace([renamed]);
    store.auth.replace(fixture.viewer);
    store.replaceExecution(fixture);
    expect(store.spaces.items.single.name, 'Cached space');
    expect(store.auth.viewer, fixture.viewer);
    expect(store.execution.spaces, isEmpty);
    expect(store.execution.viewer, isNull);
    expect(() => store.execution.tasks.clear(), throwsUnsupportedError);
    store.dispose();
  });

  test('bootstrap populates independent stores without nested Threads',
      () async {
    final store = AxStore(SelectiveSource());
    final loaded = await store.loadBootstrapState();
    expect(store.spaces.items.map((space) => space.id),
        loaded.spaces.map((space) => space.id));
    expect(store.auth.viewer, loaded.viewer);
    expect(store.spaces.items.every((space) => space.threads.isEmpty), isTrue);
    expect(store.execution.spaces, isEmpty);
    store.dispose();
  });

  test('cleared/disposed lists reject late reads', () async {
    final source = PendingLists();
    final store = AxStore(source);
    final spaces = store.spaces.refresh();
    store.clearServerState();
    source.spaces.complete(axFixtureSnapshot().spaces);
    await spaces;
    expect(store.spaces.items, isEmpty);
    store.dispose();
  });
}

class PendingLists extends AxFixtureDataSource {
  final spaces = Completer<List<AxSpace>>();
  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) =>
      spaces.future;
}
