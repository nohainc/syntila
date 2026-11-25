import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_app.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/sync/ax_space_details.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/features/navigation/space_tree.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'package:syntila_app/src/navigation/ax_browser_navigation.dart';
import 'package:syntila_app/src/navigation/ax_navigation.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'ax_fixture_data.dart';
import 'ax_fixture_realtime.dart';

const a = AxSpace(id: 'a', name: 'Space A', branch: '', lastActivity: '');
const b = AxSpace(id: 'b', name: 'Space B', branch: '', lastActivity: '');
const w = AxThread(
    id: 'wb',
    spaceId: 'b',
    name: 'B conversation',
    lead: '',
    status: 'active',
    brief: '',
    queueStatus: '');

class NavigationSource extends AxFixtureDataSource {
  final details = <String, List<Completer<AxSpace>>>{};
  final collections = <String, List<Completer<List<AxThread>>>>{};
  int bootstrapCalls = 0,
      sessionCalls = 0,
      workspaceCalls = 0,
      catalogCalls = 0;
  @override
  Future<AxSpace> loadSpace({required String spaceId}) {
    final request = Completer<AxSpace>();
    details.putIfAbsent(spaceId, () => []).add(request);
    return request.future;
  }

  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) {
    final request = Completer<List<AxThread>>();
    collections.putIfAbsent(spaceId, () => []).add(request);
    return request.future;
  }

  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async {
    catalogCalls++;
    return [a, b];
  }

  @override
  Future<AxSession> loadSession() async {
    sessionCalls++;
    return super.loadSession();
  }

  @override
  Future<AxSnapshot> loadBootstrapState({String? spaceId}) async {
    bootstrapCalls++;
    final spaces = await loadSpaces();
    await loadSession();
    return AxSnapshot(
        spaces: spaces,
        tasks: const [],
        findings: const [],
        events: const [],
        artifacts: const []);
  }

  List<int> get bootstrapCounts => [bootstrapCalls, sessionCalls, catalogCalls];
}

class HistoryNavigation implements AxBrowserNavigation {
  HistoryNavigation(this.current);
  @override
  Uri current;
  final controller = StreamController<Uri>.broadcast(sync: true);
  @override
  Stream<Uri> get changes => controller.stream;
  @override
  Stream<void> get lifecycleChanges => const Stream.empty();
  void history(Uri uri) {
    current = uri;
    controller.add(uri);
  }

  @override
  void push(Uri uri) {
    current = uri;
  }

  @override
  void replace(Uri uri) {
    current = uri;
  }

  @override
  void replaceWithLogin(Uri returnTo) {
    current = Uri(path: '/login');
  }

  @override
  void startSocialLogin(String provider, Uri returnTo) {}
  @override
  void openExternal(Uri uri) {}
  @override
  bool closeCurrentWindow() => false;
  @override
  void dispose() {
    unawaited(controller.close());
  }
}

void main() {
  Future<void> mount(WidgetTester tester, NavigationSource source,
      HistoryNavigation browser) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: SyntilaAppShell(
            dataSource: source,
            services: const DefaultPlatformServices(),
            browserNavigation: browser,
            realtimeClient: TestRealtime())));
    await tester.pumpAndSettle();
  }

  void navigate(WidgetTester tester, AxNavigation route) =>
      tester.widget<SpaceTree>(find.byType(SpaceTree)).onNavigateTo(route);

  testWidgets(
      'navigation changes route immediately and starts independent focused requests',
      (tester) async {
    final source = NavigationSource();
    final browser = HistoryNavigation(Uri.parse('/'));
    await mount(tester, source, browser);
    final counts = source.bootstrapCounts;
    navigate(tester, const AxNavigation.space('b'));
    expect(browser.current.path, '/spaces/b');
    expect(source.details['b'], hasLength(1));
    expect(source.collections['b'], hasLength(1));
    // A matching history notification must not schedule another navigation load.
    browser.history(browser.current);
    await tester.pump();
    expect(
        tester.widget<NewThreadPage>(find.byType(NewThreadPage)).space.id, 'b');
    expect(source.bootstrapCounts, counts);
    expect(source.details['b'], hasLength(1));
    expect(source.collections['b'], hasLength(1));
    source.details['b']!.single
        .complete(b.copyWith(description: 'B server details'));
    source.collections['b']!.single.complete([w]);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<NewThreadPage>(find.byType(NewThreadPage))
            .space
            .description,
        'B server details');
    expect(source.bootstrapCounts, counts);
  });

  testWidgets(
      'back/forward uses cached details and late A cannot replace active B',
      (tester) async {
    final source = NavigationSource();
    final browser = HistoryNavigation(Uri.parse('/'));
    await mount(tester, source, browser);
    final counts = source.bootstrapCounts;
    browser.history(Uri.parse('/spaces/a'));
    await tester.pump();
    browser.history(Uri.parse('/spaces/b'));
    await tester.pump();
    expect(
        tester.widget<NewThreadPage>(find.byType(NewThreadPage)).space.id, 'b');
    source.details['a']!.single
        .complete(a.copyWith(description: 'A server details'));
    source.collections['a']!.single.complete([]);
    await tester.pump();
    await tester.pump();
    expect(browser.current.path, '/spaces/b');
    expect(
        tester.widget<NewThreadPage>(find.byType(NewThreadPage)).space.id, 'b');
    source.details['b']!.single
        .complete(b.copyWith(description: 'B server details'));
    source.collections['b']!.single.complete([w]);
    await tester.pumpAndSettle();
    browser.history(Uri.parse('/spaces/a'));
    await tester.pump();
    expect(
        tester
            .widget<NewThreadPage>(find.byType(NewThreadPage))
            .space
            .description,
        'A server details');
    browser.history(Uri.parse('/spaces/b'));
    await tester.pump();
    expect(
        tester
            .widget<NewThreadPage>(find.byType(NewThreadPage))
            .space
            .description,
        'B server details');
    expect(source.details['a'], hasLength(1));
    expect(source.details['b'], hasLength(1));
    expect(source.collections['a'], hasLength(1));
    expect(source.collections['b'], hasLength(1));
    expect(source.bootstrapCounts, counts);
  });

  testWidgets(
      'opening Thread from Space page never performs a second bootstrap',
      (tester) async {
    final source = NavigationSource();
    final browser = HistoryNavigation(Uri.parse('/'));
    await mount(tester, source, browser);
    navigate(tester, const AxNavigation.space('b'));
    source.details['b']!.single.complete(b);
    source.collections['b']!.single.complete([w]);
    await tester.pumpAndSettle();
    final counts = source.bootstrapCounts;
    tester.widget<NewThreadPage>(find.byType(NewThreadPage)).onOpenThread(w);
    expect(browser.current.path, '/spaces/b/threads/wb');
    await tester.pumpAndSettle();
    expect(find.byType(ThreadPage), findsOneWidget);
    expect(source.details['b'], hasLength(1));
    expect(source.collections['b'], hasLength(1));
    expect(source.bootstrapCounts, counts);
  });

  testWidgets('deep link absent from catalog resolves locally with retry',
      (tester) async {
    final source = NavigationSource();
    final browser = HistoryNavigation(Uri.parse('/spaces/missing'));
    await mount(tester, source, browser);
    final counts = source.bootstrapCounts;
    expect(find.text('Loading Space…'), findsOneWidget);
    source.details['missing']!.single.completeError(StateError('offline'));
    source.collections['missing']!.single.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('Retry Space'), findsOneWidget);
    await tester.tap(find.text('Retry Space'));
    await tester.pump();
    source.details['missing']!.last.complete(const AxSpace(
        id: 'missing', name: 'Recovered Space', branch: '', lastActivity: ''));
    await tester.pumpAndSettle();
    expect(tester.widget<NewThreadPage>(find.byType(NewThreadPage)).space.id,
        'missing');
    expect(source.details['missing'], hasLength(2));
    expect(source.collections['missing'], hasLength(1));
    expect(source.bootstrapCounts, counts);
  });

  test(
      'focused details deduplicate, stale refresh retains data and record fences old reads',
      () async {
    final source = NavigationSource();
    var now = DateTime.utc(2026);
    final engine = AxSyncEngine(clock: () => now);
    final details = AxSpaceDetails(source, engine: engine);
    final old = details.ensure('a');
    final same = details.ensure('a');
    expect(identical(old, same), isTrue);
    source.details['a']!.single.complete(a);
    await old;
    now = now.add(const Duration(minutes: 2));
    expect((await details.ensure('a')).id, a.id);
    expect(engine.peek(details.query('a')).isFetching, isTrue);
    final pending = engine.refresh(details.query('a'));
    await details.record(a.copyWith(name: 'Authoritative write', threads: [w]));
    source.details['a']!.last.complete(a.copyWith(name: 'Old response'));
    await pending;
    expect(details.peek('a')!.name, 'Authoritative write');
    expect(details.peek('a')!.threads, isEmpty);
    engine.clear();
    expect(details.peek('a'), isNull);
  });
}
