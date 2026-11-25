import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/sync/ax_space_tab_queries.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'ax_fixture_data.dart';

class TabSource extends AxFixtureDataSource {
  List<AxThread> streams = [];
  final calls = <String, int>{};
  Completer<List<AxSpaceMember>>? pending;
  bool failMembers = false;
  void count(String resource) =>
      calls.update(resource, (v) => v + 1, ifAbsent: () => 1);
  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async {
    count('streams');
    return streams;
  }

  @override
  Future<List<Map<String, dynamic>>> loadSpaceWorkflowWorkspaceGrants(
      {required String spaceId}) async {
    count('grants');
    return [];
  }

  @override
  Future<List<AxSpaceMember>> loadSpaceMembers(
      {required String spaceId}) async {
    count('members');
    if (failMembers) throw StateError('Members unavailable');
    if (pending != null) return pending!.future;
    return [
      AxSpaceMember.fromJson({
        'userId': 'u',
        'displayName': 'Cached member',
        'role': 'collaborator'
      })
    ];
  }

  @override
  Future<List<AxSpaceInvitation>> loadSpaceInvitations(
      {required String spaceId}) async {
    count('invitations');
    return [];
  }

  @override
  Future<List<AxAuditEntry>> loadSpaceAudit({required String spaceId}) async {
    count('audit');
    return [];
  }
}

Widget page(TabSource source, AxSpaceTabQueries queries,
        {String role = 'owner',
        String instructions = '',
        SpacePageSection section = SpacePageSection.threads}) =>
    MaterialApp(
        home: Scaffold(
      body: SingleChildScrollView(
          child: SpacePage(
        section: section,
        space: AxSpace(
            id: 'P',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: role,
            instructions: instructions),
        dataSource: source,
        tabQueries: queries,
        spaceThreads: queries.threads,
        onOpenThread: (_) {},
        onArchive: () {},
        onDelete: () {},
      )),
    ));

void main() {
  for (final role in ['owner', 'collaborator', 'viewer']) {
    testWidgets('$role sees only authorized Thread management actions',
        (tester) async {
      final source = TabSource()
        ..streams = [
          const AxThread(
              id: 'own',
              spaceId: 'P',
              name: 'Own stream',
              lead: 'Me',
              status: 'active',
              brief: '',
              queueStatus: '',
              canConfigureWork: true),
          const AxThread(
              id: 'other',
              spaceId: 'P',
              name: 'Other stream',
              lead: 'Other',
              status: 'active',
              brief: '',
              queueStatus: ''),
        ];
      await tester
          .pumpWidget(page(source, AxSpaceTabQueries(source), role: role));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Thread actions'), findsNWidgets(2));
    });
  }

  testWidgets(
      'shared Space omits instructions in the route-based Threads section',
      (tester) async {
    final source = TabSource();
    final queries = AxSpaceTabQueries(source);
    await tester.pumpWidget(page(source, queries, role: 'collaborator'));
    await tester.pumpAndSettle();
    expect(find.text('No instructions configured.'), findsNothing);
    await tester.pumpWidget(page(source, queries,
        role: 'collaborator', instructions: 'Use our conventions'));
    await tester.pumpAndSettle();
    expect(find.text('Use our conventions'), findsNothing);
  });

  testWidgets(
      'Space tabs fetch only visible resources and reuse them after navigation',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = TabSource();
    final queries = AxSpaceTabQueries(source);
    await tester.pumpWidget(page(source, queries));
    await tester.pumpAndSettle();
    expect(source.calls, {'streams': 1});
    expect(find.text('Workspaces'), findsNothing);
    await tester
        .pumpWidget(page(source, queries, section: SpacePageSection.members));
    await tester.pumpAndSettle();
    expect(source.calls, {'streams': 1, 'members': 1, 'invitations': 1});
    expect(queries.engine.isObserved(queries.members('P').key), isTrue);
    await tester.pumpWidget(page(source, queries));
    await tester.pumpAndSettle();
    expect(queries.engine.isObserved(queries.members('P').key), isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page(source, queries));
    await tester.pumpAndSettle();
    await tester
        .pumpWidget(page(source, queries, section: SpacePageSection.members));
    await tester.pumpAndSettle();
    expect(source.calls['members'], 1);
    expect(source.calls['invitations'], 1);
    expect(source.calls['streams'], 1);
    expect(source.calls['audit'], isNull);
    expect(source.calls['owned'], isNull);
  });

  testWidgets(
      'stale Members remain visible while background refresh is pending',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var now = DateTime.utc(2026);
    final source = TabSource();
    final queries =
        AxSpaceTabQueries(source, engine: AxSyncEngine(clock: () => now));
    await tester.pumpWidget(page(source, queries));
    await tester.pumpAndSettle();
    await tester
        .pumpWidget(page(source, queries, section: SpacePageSection.members));
    await tester.pumpAndSettle();
    expect(find.text('Cached member'), findsOneWidget);
    await tester.pumpWidget(page(source, queries));
    await tester.pumpAndSettle();
    now = now.add(const Duration(minutes: 2));
    source.pending = Completer();
    await tester
        .pumpWidget(page(source, queries, section: SpacePageSection.members));
    await tester.pumpAndSettle();
    expect(source.calls['members'], 2);
    expect(find.text('Cached member'), findsOneWidget);
    await tester.pumpWidget(page(source, queries));
    await tester.pumpAndSettle();
    source.pending!.complete([
      AxSpaceMember.fromJson(
          {'userId': 'u2', 'displayName': 'New member', 'role': 'collaborator'})
    ]);
    await tester.pumpAndSettle();
    await tester
        .pumpWidget(page(source, queries, section: SpacePageSection.members));
    await tester.pumpAndSettle();
    expect(find.text('New member'), findsOneWidget);
    expect(source.calls['members'], 2);
  });

  testWidgets('Members failure retries only that tab and keeps cached data',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = TabSource();
    final queries = AxSpaceTabQueries(source);
    await tester.pumpWidget(page(source, queries));
    await tester.pumpAndSettle();
    await tester
        .pumpWidget(page(source, queries, section: SpacePageSection.members));
    await tester.pumpAndSettle();
    source.failMembers = true;
    await expectLater(queries.refreshMembers('P'), throwsStateError);
    await tester.pumpAndSettle();
    expect(find.text('Cached member'), findsOneWidget);
    expect(find.text('Retry Members'), findsNothing);
    expect(
        find.text(
            'Members could not be loaded. Reopen this Space to try again.'),
        findsOneWidget);
    source.failMembers = false;
    await tester.pumpWidget(page(source, queries));
    await tester.pumpAndSettle();
    await tester
        .pumpWidget(page(source, queries, section: SpacePageSection.members));
    await tester.pumpAndSettle();
    expect(find.text('Retry Members'), findsNothing);
    expect(source.calls['streams'], 1);
    expect(source.calls['audit'], isNull);
  });

  test('member mutation revalidates only its affected query; audit stays lazy',
      () async {
    final source = TabSource();
    final queries = AxSpaceTabQueries(source);
    await queries.engine.ensure(queries.members('P'));
    await queries.engine.ensure(queries.invitations('P'));
    await queries.refreshMembers('P', includeMembers: false);
    expect(source.calls, {'members': 1, 'invitations': 2});
    await queries.engine.ensure(queries.audit('P'));
    expect(source.calls['audit'], 1);
  });

  test(
      'Space recovery recognizes collaboration keys without fetching unopened tabs',
      () async {
    final source = TabSource();
    final queries = AxSpaceTabQueries(source);
    await queries.engine.ensure(queries.threads.query('P'));
    const scope = AxSyncScope('space', 'P');
    expect(scope.matches(queries.members('P').key), isTrue);
    expect(scope.matches(queries.invitations('P').key), isTrue);
    expect(scope.matches(queries.audit('P').key), isTrue);
    expect(scope.matches(queries.members('Q').key), isFalse);
    await queries.engine.revalidateWhere(scope.matches);
    expect(source.calls, {'streams': 2});
  });

  test('session clear fences a pending tab request and isolates Spaces',
      () async {
    final source = TabSource()..pending = Completer();
    final queries = AxSpaceTabQueries(source);
    final flight = queries.engine.ensure(queries.members('P'));
    queries.engine.clear();
    source.pending!.complete([]);
    await flight;
    expect(queries.engine.peek(queries.members('P')).hasData, isFalse);
    source.pending = null;
    await queries.engine.ensure(queries.members('Q'));
    expect(queries.engine.peek(queries.members('P')).hasData, isFalse);
    expect(queries.engine.peek(queries.members('Q')).hasData, isTrue);
  });
}
