import 'dart:async';
import 'package:syntila_app/src/features/invitations/space_invitation_dialog.dart';
import 'package:syntila_app/src/ax/sync/ax_space_invitations.dart';
import 'package:syntila_app/src/features/navigation/app_menu.dart';
import 'package:syntila_app/src/features/navigation/app_sidebar.dart';
import 'package:syntila_app/src/features/navigation/ax_shell_context.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_people.dart';
import 'package:syntila_app/src/ax/sync/ax_people.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/ax/sync/ax_realtime_cache_router.dart';
import 'package:syntila_app/src/features/people/people_page.dart';
import 'package:syntila_app/src/navigation/ax_navigation.dart';
import 'ax_fixture_data.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'package:syntila_app/src/ax/ax_models.dart';

class PeopleSource extends AxFixtureDataSource {
  int loads = 0;
  bool failRead = false;
  List<AxPerson> rows = [];
  Completer<List<AxPerson>>? pending;
  String? invitedUserId;
  String? invitedSpaceId;
  AxSpacePermissions? invitedPermissions;
  bool failInvite = false;
  String? failUserId;
  String? invitedEmail;
  List<AxSpaceInvitation> invitationRows = [];
  final expiredIds = <String>[];
  final sentUserIds = <String>[];
  Completer<void>? pendingInvite;
  void Function()? afterInvite;
  @override
  Future<void> invitePersonToSpace(
      {required String spaceId,
      required String userId,
      required String role,
      required AxSpacePermissions permissions}) async {
    await pendingInvite?.future;
    if (failInvite || userId == failUserId) {
      throw StateError('permission changed');
    }
    sentUserIds.add(userId);
    invitedUserId = userId;
    invitedSpaceId = spaceId;
    invitedPermissions = permissions;
    afterInvite?.call();
  }

  @override
  Future<void> inviteSpaceMemberWithPermissions(
      {required String spaceId,
      required String email,
      required String role,
      required AxSpacePermissions permissions}) async {
    invitedEmail = email;
    invitedSpaceId = spaceId;
    invitedPermissions = permissions;
  }

  @override
  Future<List<AxSpaceInvitation>> loadSpaceInvitations(
          {required String spaceId}) async =>
      invitationRows;
  @override
  Future<void> expireSpaceInvitation(
      {required String spaceId, required String invitationId}) async {
    expiredIds.add(invitationId);
    invitationRows = [];
  }

  @override
  Future<List<AxPerson>> loadPeople() async {
    loads++;
    if (failRead) throw StateError('offline');
    return pending?.future ?? rows;
  }
}

const bob = AxPerson(
    userId: 'b',
    displayName: 'Bob',
    email: 'b@test',
    establishedAt: 'now',
    sharedSpaceCount: 1);
void main() {
  test('People navigation preserves global identity', () {
    expect(AxNavigation.fromUri(Uri.parse('/people')).toUri().path, '/people');
  });
  test('one session query deduplicates consumers and navigation reads',
      () async {
    final source = PeopleSource()..pending = Completer();
    final engine = AxSyncEngine();
    final people = AxPeople(source, engine: engine);
    final first = people.ensure();
    final second = people.ensure();
    source.pending!.complete([bob]);
    expect(await first, [bob]);
    expect(await second, [bob]);
    await AxPeople(source, engine: engine).ensure();
    expect(source.loads, 1);
    expect(
        () => engine.peek(people.query).data!.add(bob), throwsUnsupportedError);
  });
  test(
      'People and reconnect signals refresh without a page; Space events do not',
      () async {
    final source = PeopleSource();
    final engine = AxSyncEngine();
    final people = AxPeople(source, engine: engine);
    final router = AxRealtimeCacheRouter(engine);
    await people.ensure();
    source.rows = [bob];
    await router.handle({'type': 'space.updated', 'spaceId': 'A'});
    expect(engine.peek(people.query).data, isEmpty);
    await router.handle({
      'type': 'people.updated',
      'payload': {'entityId': 'b'}
    });
    await router.handle({
      'type': 'reconnect.required',
      'scope': {'kind': 'user'}
    });
    await router.handle({
      'type': 'reconnect.required',
      'scope': {'kind': 'space', 'spaceId': 'A'}
    });
    expect(source.loads, 4);
    source.rows = [];
    await router.handle({'type': 'space.deleted', 'spaceId': 'A'});
    expect(engine.peek(people.query).data, [bob]);
    expect(source.loads, 4);
  });
  test('Space reconciliation does not attempt a failing People read', () async {
    final source = PeopleSource();
    final engine = AxSyncEngine();
    final people = AxPeople(source, engine: engine);
    final router = AxRealtimeCacheRouter(engine);
    var spaceLoads = 0;
    final space = AxQuery<int>(
        key: AxQueryKey(['space', 'A', 'members']),
        load: () async => ++spaceLoads);
    await people.ensure();
    await engine.ensure(space);
    source.failRead = true;
    await router.handle({'type': 'space.updated', 'spaceId': 'A'});
    expect(engine.peek(people.query).error, isNull);
    expect(source.loads, 1);
    expect(spaceLoads, 2);
  });
  test('session clearing fences a late People response', () async {
    final source = PeopleSource()..pending = Completer();
    final engine = AxSyncEngine();
    final people = AxPeople(source, engine: engine);
    final read = people.ensure();
    people.clear();
    source.pending!.complete([bob]);
    await read;
    expect(engine.peek(people.query).hasData, isFalse);
  });
  testWidgets(
      'People page reuses cache and reacts to profile and membership changes',
      (tester) async {
    final source = PeopleSource()..rows = [bob];
    final engine = AxSyncEngine();
    final people = AxPeople(source, engine: engine);
    final router = AxRealtimeCacheRouter(engine);
    await people.ensure();
    Widget page() => MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(child: PeoplePage(people: people))));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsOneWidget);
    expect(source.loads, 1);
    source.rows = [
      const AxPerson(
          userId: 'b',
          displayName: 'Robert',
          email: 'new@test',
          establishedAt: 'now',
          sharedSpaceCount: 0)
    ];
    await router.handle({
      'type': 'people.updated',
      'payload': {'entityId': 'b'}
    });
    await tester.pumpAndSettle();
    expect(find.text('Robert'), findsOneWidget);
    expect(find.text('0 shared Spaces'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(source.loads, 2);
  });
  testWidgets('Space invitation reuses People and submits the stable user ID',
      (tester) async {
    final source = PeopleSource()
      ..rows = [
        const AxPerson(
            userId: 'b',
            displayName: 'Bob',
            email: 'b@test',
            establishedAt: 'now',
            sharedSpaceCount: 0,
            invitableSpaces: [
              AxPeopleSpace(
                  id: 'S',
                  name: 'Space',
                  permissions: AxSpacePermissions(chat: true),
                  canInvite: true)
            ])
      ];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SpacePage(
      section: SpacePageSection.members,
      space: const AxSpace(
          id: 'S', name: 'Space', branch: '', lastActivity: 'now'),
      dataSource: source,
      onOpenThread: (_) {},
      onArchive: () {},
      onDelete: () {},
    ))));
    await tester.pumpAndSettle();
    final loads = source.loads;
    await tester.tap(find.widgetWithText(TextButton, 'Invite'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('invite-person-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send invitation'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    expect(source.invitedUserId, 'b');
    expect(source.loads, loads + 1);
  });
  testWidgets('People cards show email and use one column', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = PeopleSource()
      ..rows = [
        bob,
        const AxPerson(
            userId: 'x',
            displayName: 'Julia',
            email: 'julia@test',
            establishedAt: 'now',
            sharedSpaceCount: 0)
      ];
    final people = AxPeople(source, engine: AxSyncEngine());
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PeoplePage(people: people))));
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('b@test'), findsOneWidget);
    expect(find.text('Julia'), findsOneWidget);
    expect(find.byKey(const ValueKey('people-search')), findsNothing);
    expect(find.byType(Card), findsNWidgets(2));
    final firstCard = tester.getRect(find.byKey(const ValueKey('person-b')));
    final secondCard = tester.getRect(find.byKey(const ValueKey('person-x')));
    expect(secondCard.left, firstCard.left);
    expect(secondCard.width, firstCard.width);
    expect(secondCard.top - firstCard.bottom, 12);
    expect(source.loads, 1);
  });
  testWidgets(
      'details and Add to Space share live state and submit scoped permissions',
      (tester) async {
    const person = AxPerson(
        userId: 'b',
        displayName: 'Bob',
        email: 'b@test',
        establishedAt: 'now',
        sharedSpaceCount: 1,
        sharedSpaces: [
          AxPeopleSpace(id: 'A', name: 'Holiday planning')
        ],
        invitableSpaces: [
          AxPeopleSpace(
              id: 'C',
              name: 'Syntila',
              permissions: AxSpacePermissions(chat: true),
              canInvite: true)
        ]);
    final source = PeopleSource()..rows = [person];
    final engine = AxSyncEngine();
    final people = AxPeople(source, engine: engine);
    final router = AxRealtimeCacheRouter(engine);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PeoplePage(people: people))));
    await tester.pumpAndSettle();
    expect(find.textContaining('Holiday planning'), findsOneWidget);
    expect(find.text('b@test'), findsOneWidget);
    expect(find.text('Holiday planning'), findsOneWidget);
    expect(source.loads, 1);
    await tester.tap(find.byKey(const ValueKey('add-to-space-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Syntila').last);
    await tester.pumpAndSettle();
    source.afterInvite = () => source.rows = [
          const AxPerson(
              userId: 'b',
              displayName: 'Robert',
              email: 'new@test',
              establishedAt: 'now',
              sharedSpaceCount: 1,
              sharedSpaces: [AxPeopleSpace(id: 'A', name: 'Renamed')])
        ];
    await tester.tap(find.text('Send invitation'));
    await tester.pumpAndSettle();
    expect(source.invitedUserId, 'b');
    expect(source.invitedSpaceId, 'C');
    expect(source.invitedPermissions!.chat, isFalse);
    expect(source.invitedPermissions!.work, isFalse);
    expect(find.text('Renamed'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('add-to-space-b')))
            .onPressed,
        isNotNull);
    source.rows = [person];
    await router.handle({'type': 'people.updated'});
    await tester.pumpAndSettle();
    expect(find.text('Holiday planning'), findsOneWidget);
    expect(source.loads, 3);
  });
  testWidgets('candidate changes disable sending an already pending invitation',
      (tester) async {
    final source = PeopleSource()
      ..rows = [
        const AxPerson(
            userId: 'b',
            displayName: 'Bob',
            email: 'b@test',
            establishedAt: 'now',
            sharedSpaceCount: 0,
            invitableSpaces: [
              AxPeopleSpace(id: 'C', name: 'Candidate', canInvite: true)
            ])
      ];
    final engine = AxSyncEngine();
    final people = AxPeople(source, engine: engine);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PeoplePage(people: people))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-to-space-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Candidate').last);
    await tester.pumpAndSettle();
    source.rows = [bob];
    await AxRealtimeCacheRouter(engine).handle({'type': 'people.updated'});
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Send invitation'))
            .onPressed,
        isNull);
    expect(find.textContaining('No eligible Spaces.'), findsOneWidget);
    expect(source.invitedUserId, isNull);
  });
  testWidgets(
      'cold loading, empty account, and offline cached data have clear states',
      (tester) async {
    final source = PeopleSource()..pending = Completer();
    final people = AxPeople(source, engine: AxSyncEngine());
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PeoplePage(people: people))));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    source.pending!.complete([]);
    await tester.pumpAndSettle();
    expect(find.textContaining('after they accept a Space invitation.'),
        findsOneWidget);
    source.pending = null;
    source.rows = [bob];
    await people.refresh();
    await tester.pumpAndSettle();
    source.failRead = true;
    await expectLater(people.refresh(), throwsStateError);
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsOneWidget);
    expect(find.textContaining('Check your connection.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
  testWidgets('existing application popup navigates to global People',
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
    expect(find.text('People'), findsNothing);
    await tester.tap(find.byTooltip('Application menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('People'));
    await tester.pumpAndSettle();
    expect(navigation!.kind, AxRouteKind.people);
    expect(navigation!.spaceId, isNull);
    expect(navigation!.toUri().path, '/people');
  });
  test('an invitation completing after logout cannot rehydrate People',
      () async {
    final source = PeopleSource()
      ..rows = [bob]
      ..pendingInvite = Completer();
    final engine = AxSyncEngine();
    final people = AxPeople(source, engine: engine);
    await people.ensure();
    final write = AxSpaceInvitations(people).send(
        userId: 'b',
        space: const AxPeopleSpace(id: 'C', name: 'Candidate', canInvite: true),
        permissions: const AxSpacePermissions());
    final assertion = expectLater(write, throwsA(isA<AxMutationSuperseded>()));
    engine.clear();
    source.pendingInvite!.complete();
    await assertion;
    expect(source.loads, 1);
    expect(engine.relevantKeys, isEmpty);
  });
  testWidgets(
      'rejected invitations show an error and reconcile changed eligibility',
      (tester) async {
    final source = PeopleSource()
      ..rows = [
        const AxPerson(
            userId: 'b',
            displayName: 'Bob',
            email: 'b@test',
            establishedAt: 'now',
            sharedSpaceCount: 0,
            invitableSpaces: [
              AxPeopleSpace(id: 'C', name: 'Candidate', canInvite: true)
            ])
      ];
    final people = AxPeople(source, engine: AxSyncEngine());
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PeoplePage(people: people))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-to-space-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Candidate').last);
    await tester.pumpAndSettle();
    source.failInvite = true;
    source.rows = [bob];
    await tester.tap(find.text('Send invitation'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Invitation could not be sent.'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Send invitation'))
            .onPressed,
        isNull);
    expect(source.invitedUserId, isNull);
    expect(source.loads, 2);
  });
  testWidgets('People has no main sidebar entry', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 280,
                child: AppSidebar(
                  shellContext: const AxShellContext(
                      navigation: AxNavigation.people(), spaces: []),
                  onNavigateTo: (_) {},
                  onLogout: () {},
                  onOpenAbout: () {},
                  onOpenExternal: (_) {},
                )))));
    await tester.pumpAndSettle();
    expect(find.text('People'), findsNothing);
    await tester.tap(find.byTooltip('Application menu'));
    await tester.pumpAndSettle();
    expect(find.text('People'), findsOneWidget);
  });
  test('a rejected invitation after logout cannot refresh the prior session',
      () async {
    final source = PeopleSource()
      ..rows = [bob]
      ..pendingInvite = Completer();
    final engine = AxSyncEngine();
    final people = AxPeople(source, engine: engine);
    await people.ensure();
    final write = AxSpaceInvitations(people).send(
        userId: 'b',
        space: const AxPeopleSpace(id: 'C', name: 'Candidate', canInvite: true),
        permissions: const AxSpacePermissions());
    final assertion = expectLater(write, throwsA(isA<AxMutationSuperseded>()));
    engine.clear();
    source.failInvite = true;
    source.pendingInvite!.complete();
    await assertion;
    expect(engine.relevantKeys, isEmpty);
    expect(source.loads, 1);
  });
  Future<void> openInvite(WidgetTester tester, AxPeople people) async {
    await people.ensure();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showDialog<bool>(
                        context: context,
                        builder: (_) => SpaceInvitationDialog(
                            people: people,
                            space: const AxPeopleSpace(
                                id: 'S',
                                name: 'Space',
                                permissions: AxSpacePermissions(chat: true),
                                canInvite: true))),
                    child: const Text('Open invitation'))))));
    await tester.tap(find.text('Open invitation'));
    await tester.pumpAndSettle();
  }

  const candidate = AxPeopleSpace(
      id: 'S',
      name: 'Space',
      permissions: AxSpacePermissions(chat: true),
      canInvite: true);
  const available = AxPerson(
      userId: 'alex',
      displayName: 'Alex',
      email: 'alex@test',
      establishedAt: '2026-02-01',
      sharedSpaceCount: 0,
      invitableSpaces: [candidate]);
  testWidgets(
      'Space picker searches People locally and explains member/pending status by ID',
      (tester) async {
    final source = PeopleSource()
      ..rows = [
        available,
        const AxPerson(
            userId: 'member',
            displayName: 'Member',
            email: 'new-member@test',
            establishedAt: '2026-01-01',
            sharedSpaceCount: 1,
            sharedSpaces: [candidate]),
        const AxPerson(
            userId: 'pending',
            displayName: 'Pending',
            email: 'new-pending@test',
            establishedAt: '2026-01-01',
            sharedSpaceCount: 0,
            pendingInvitationSpaceIds: ['S'])
      ];
    final people = AxPeople(source, engine: AxSyncEngine());
    await openInvite(tester, people);
    expect(find.text('Available to invite'), findsOneWidget);
    expect(find.text('Already a member'), findsOneWidget);
    expect(find.text('Pending invitation'), findsOneWidget);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('invite-person-member')))
            .onChanged,
        isNull);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('invite-person-pending')))
            .onChanged,
        isNull);
    await tester.enterText(
        find.byKey(const ValueKey('invite-people-search')), 'ALEX@TEST');
    await tester.pumpAndSettle();
    expect(find.text('Alex'), findsOneWidget);
    expect(find.text('Member'), findsNothing);
    expect(source.loads, 1);
    await tester.tap(find.byKey(const ValueKey('invite-person-alex')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('invite-new-email')))
            .enabled,
        isFalse);
    await tester.tap(find.text('Send invitation'));
    await tester.pumpAndSettle();
    expect(source.sentUserIds, ['alex']);
    expect(source.invitedEmail, isNull);
    expect(source.invitedPermissions!.chat, isFalse);
    expect(source.invitedPermissions!.work, isFalse);
  });
  testWidgets(
      'the email entry uses the same permission-aware invitation writer',
      (tester) async {
    final source = PeopleSource();
    final people = AxPeople(source, engine: AxSyncEngine());
    await openInvite(tester, people);
    expect(find.text('Read Space'), findsNothing);
    expect(find.text('Use Space AI for work'), findsOneWidget);
    expect(find.text('Use Work workflows'), findsNothing);
    expect(find.text('Create threads'), findsOneWidget);
    expect(find.text('Create and manage own threads'), findsNothing);
    await tester.enterText(
        find.byKey(const ValueKey('invite-new-email')), 'john@test');
    await tester.tap(find.byKey(const ValueKey('invite-permission-chat')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send invitation'));
    await tester.pumpAndSettle();
    expect(source.invitedEmail, 'john@test');
    expect(source.invitedUserId, isNull);
    expect(source.invitedPermissions!.chat, isTrue);
  });
  testWidgets(
      'multiple People create separate invitations and partial failures retain only unsent selections',
      (tester) async {
    final source = PeopleSource()
      ..rows = [
        available,
        const AxPerson(
            userId: 'julia',
            displayName: 'Julia',
            email: 'julia@test',
            establishedAt: '2026-03-01',
            sharedSpaceCount: 0,
            invitableSpaces: [candidate])
      ]
      ..failUserId = 'alex';
    final people = AxPeople(source, engine: AxSyncEngine());
    await openInvite(tester, people);
    await tester.tap(find.byKey(const ValueKey('invite-person-julia')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('invite-person-alex')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send invitation'));
    await tester.pumpAndSettle();
    expect(source.sentUserIds, ['julia']);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('invite-person-julia')))
            .value,
        isFalse);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('invite-person-alex')))
            .value,
        isTrue);
    expect(find.textContaining('1 invitation sent.'), findsOneWidget);
    source.failUserId = null;
    await tester.tap(find.text('Send invitation'));
    await tester.pumpAndSettle();
    expect(source.sentUserIds, ['julia', 'alex']);
  });
  test('the shared writer rejects permission escalation before posting',
      () async {
    final source = PeopleSource();
    final people = AxPeople(source, engine: AxSyncEngine());
    await people.ensure();
    await expectLater(
        AxSpaceInvitations(people).send(
            space: candidate,
            userId: 'alex',
            permissions: const AxSpacePermissions(work: true)),
        throwsStateError);
    expect(source.sentUserIds, isEmpty);
  });
  testWidgets('Resend preserves known recipient ID and configured permissions',
      (tester) async {
    final source = PeopleSource()
      ..rows = [bob]
      ..invitationRows = [
        const AxSpaceInvitation(
            id: 'old',
            inviteeUserId: 'b',
            email: 'old-b@test',
            role: 'collaborator',
            status: 'pending',
            createdAt: 'now',
            permissions: AxSpacePermissions(chat: true))
      ];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SpacePage(
                section: SpacePageSection.members,
                space: const AxSpace(
                    id: 'S', name: 'Space', branch: '', lastActivity: 'now'),
                dataSource: source,
                onOpenThread: (_) {},
                onArchive: () {},
                onDelete: () {}))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Resend invitation'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    expect(source.expiredIds, ['old']);
    expect(source.sentUserIds, ['b']);
    expect(source.invitedEmail, isNull);
    expect(source.invitedPermissions!.chat, isTrue);
    expect(source.invitedPermissions!.work, isFalse);
  });
}
