import 'package:syntila_app/src/ax/ax_data.dart'
    show AxAccountPlan, AxAccountPlanDataSource;
import 'package:syntila_app/src/ax/ax_people.dart';
import 'package:syntila_app/src/features/profile/account_plan.dart';
import 'package:syntila_app/src/ax/ax_workspace_member_access.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/workspace/workspace_sharing_section.dart';
import 'package:syntila_app/src/features/workspace/workspaces_page.dart';
import 'package:flutter/material.dart';
import 'workflow_editor_test.dart' show worker;
import 'package:flutter_test/flutter_test.dart';

class SharingSource implements AxWorkspaceSharingDataSource {
  List<AxPersonWithAccess> people = const [
    AxPersonWithAccess(
        userId: 'guest',
        displayName: 'Guest',
        email: 'guest@test',
        status: 'active',
        custom: true,
        mode: 'chat',
        usage: AxPersonUsage(
            requests: 2, approxSeconds: 90, workerIds: ['worker-a'])),
  ];
  List<AxSharedWorkspaceInvitation> invitations = const [
    AxSharedWorkspaceInvitation(
        id: 'i1', email: 'new@test', status: 'pending', expiresAt: 'later'),
  ];
  List<AxMyWorkspaceInvitation> mine = const [
    AxMyWorkspaceInvitation(
        id: 'm1',
        workspaceName: 'Mac',
        ownerName: 'Lender',
        expiresAt: 'later'),
  ];
  final calls = <String>[];

  @override
  Future<List<AxPersonWithAccess>> loadPeopleWithAccess(String w) async =>
      people;
  @override
  Future<List<AxSharedWorkspaceInvitation>> loadSharedWorkspaceInvitations(
          String w) async =>
      invitations;
  @override
  Future<void> createWorkspaceInvitation(String w, String email) async =>
      calls.add('invite:$email');
  @override
  Future<void> revokeWorkspaceInvitation(String w, String id) async =>
      calls.add('cancel:$id');
  @override
  Future<void> revokePersonGrant(String w, String userId) async =>
      calls.add('revoke:$userId');
  @override
  Future<void> setPersonQuota(String w, String userId, int limit) async =>
      calls.add('quota:$userId:$limit');
  @override
  Future<void> setPersonRunTimeLimit(String w, String userId, int? s) async =>
      calls.add('runtime:$userId:$s');
  @override
  Future<List<AxMyWorkspaceInvitation>> loadMyWorkspaceInvitations() async =>
      mine;
  @override
  Future<void> declineWorkspaceInvitation(String id) async {
    calls.add('decline:$id');
  }

  @override
  Future<void> acceptWorkspaceInvitation(String id) async {
    calls.add('accept:$id');
    mine = const [];
  }
}

class AccessOnlySource implements AxWorkspaceMemberAccessDataSource {
  @override
  Future<AxWorkspaceMemberAccess> loadWorkspaceMemberAccess(String w) async =>
      const AxWorkspaceMemberAccess();
  @override
  Future<AxWorkspaceMemberAccess> saveWorkspaceMemberAccess(
          String w, AxWorkspaceMemberAccess next) async =>
      next;
}

class PersonAccessSource implements AxWorkspacePersonAccessDataSource {
  final saved = <AxWorkspaceMemberAccess>[];
  int resets = 0;
  bool custom = false;
  @override
  Future<AxPersonAccess> loadPersonAccess(String w, String userId) async =>
      AxPersonAccess(
          custom: custom,
          access: const AxWorkspaceMemberAccess(
              restricted: true, mode: 'chat', workers: {}));
  @override
  Future<AxPersonAccess> savePersonAccess(
      String w, String userId, AxWorkspaceMemberAccess next) async {
    saved.add(next);
    custom = true;
    return AxPersonAccess(custom: true, access: next);
  }

  @override
  Future<AxPersonAccess> resetPersonAccess(String w, String userId) async {
    resets++;
    custom = false;
    return loadPersonAccess(w, userId);
  }
}

class PlanSource implements AxAccountPlanDataSource {
  PlanSource(this.plan);
  AxAccountPlan plan;
  @override
  Future<AxAccountPlan> loadAccountPlan() async => plan;
}

Future<void> pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(900, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))));
  await tester.pumpAndSettle();
}

void main() {
  test('people with access parse usage and ignore unknown modes', () {
    final person = AxPersonWithAccess.fromJson({
      'userId': 'u',
      'displayName': 'U',
      'email': 'u@test',
      'status': 'active',
      'custom': true,
      'mode': 'root',
      'maxConcurrentRequests': 3,
      'usage': {
        'requests': 4,
        'approxSeconds': 120,
        'lastUsedAt': 'then',
        'workerIds': ['w']
      }
    });
    expect(person.mode, isNull);
    expect(person.maxConcurrentRequests, 3);
    expect(person.usage.requests, 4);
    expect(person.usage.workerIds, ['w']);
    expect(person.active, isTrue);
  });

  testWidgets('a lent Workspace hides member access and sharing',
      (tester) async {
    Future<void> show(Map<String, dynamic> json) =>
        tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
                    child: WorkspacesPage(
          key: UniqueKey(),
          workspaces: [AxWorkspace.fromJson(json)],
          sharingSource: SharingSource(),
          memberAccessSource: AccessOnlySource(),
        )))));
    await show({'id': 'own', 'name': 'Mine', 'role': 'owner'});
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-sharing-own')), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-member-access-own')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-shared-badge')), findsNothing);
    // Both owner sections start collapsed behind expandable headers.
    expect(find.text('Share workspace'), findsOneWidget);
    expect(find.text('Member access'), findsOneWidget);
    expect(find.byKey(const ValueKey('sharing-invite')), findsNothing);
    await tester.tap(find.text('Share workspace'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sharing-invite')), findsOneWidget);
    expect(find.byKey(const ValueKey('sharing-person-guest')), findsOneWidget);

    await show(
        {'id': 'lent', 'name': 'Lender Mac', 'role': 'member', 'shared': true});
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-detail-lent')), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-sharing-lent')), findsNothing);
    expect(find.byKey(const ValueKey('workspace-member-access-lent')),
        findsNothing);
    expect(
        find.byKey(const ValueKey('workspace-shared-badge')), findsOneWidget);
  });

  testWidgets('owner sets parallel requests on the Workspaces page',
      (tester) async {
    final changes = <(String, int)>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkspacesPage(
      workspaces: [
        AxWorkspace.fromJson(
            {'id': 'own', 'name': 'Mine', 'role': 'owner', 'parallelSlots': 3})
      ],
      onSetParallelSlots: (workspace, slots) async =>
          changes.add((workspace.id, slots)),
    )))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('parallel-slots-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5').last);
    await tester.pumpAndSettle();
    expect(changes, [('own', 5)]);

    // A lent Workspace has no slot setting for the borrower.
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkspacesPage(
      key: UniqueKey(),
      workspaces: [
        AxWorkspace.fromJson(
            {'id': 'lent', 'name': 'Lent', 'role': 'member', 'shared': true})
      ],
      onSetParallelSlots: (workspace, slots) async {},
    )))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parallel-slots-select')), findsNothing);
  });

  testWidgets('owner invites, cancels, sets the quota and revokes',
      (tester) async {
    final source = SharingSource();
    await pump(
        tester,
        WorkspaceSharingSection(workspaceId: 'ws', source: source, people: [
          AxPerson.fromJson({
            'userId': 'u',
            'displayName': 'Ann',
            'email': 'a@b.test',
            'establishedAt': 'x',
            'sharedSpaceCount': 1
          })
        ]));
    expect(find.textContaining('Guest · guest@test'), findsOneWidget);
    expect(find.textContaining('2 requests'), findsOneWidget);
    expect(find.textContaining('Chat only (custom)'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('sharing-invite')))
            .tooltip,
        'Add people');
    expect(find.text('Add people'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sharing-invite')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sharing-add-u')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('sharing-revoke-invitation-i1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sharing-revoke-guest')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sharing-confirm-revoke')));
    await tester.pumpAndSettle();
    expect(source.calls, ['invite:a@b.test', 'cancel:i1', 'revoke:guest']);
  });

  testWidgets('owner sees an invitation response without reloading',
      (tester) async {
    final source = SharingSource();
    final refresh = ValueNotifier(0);
    addTearDown(refresh.dispose);
    await pump(
        tester,
        WorkspaceSharingSection(
            workspaceId: 'ws', source: source, refresh: refresh));
    expect(find.byKey(const ValueKey('sharing-invitation-i1')), findsOneWidget);
    // The invitee declined; the realtime signal bumps the revision.
    source.invitations = const [];
    refresh.value++;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sharing-invitation-i1')), findsNothing);
  });

  testWidgets('owner sets a monthly run-time limit', (tester) async {
    final source = SharingSource();
    await pump(
        tester, WorkspaceSharingSection(workspaceId: 'ws', source: source));
    await tester.tap(find.byKey(const ValueKey('sharing-runtime-guest')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10 h').last);
    await tester.pumpAndSettle();
    expect(source.calls, ['runtime:guest:36000']);
  });

  testWidgets('quota selectors work at mobile width including no limit',
      (tester) async {
    final source = SharingSource();
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: WorkspaceSharingSection(workspaceId: 'ws', source: source),
    ))));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButton<int>), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sharing-quota-guest')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '3'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sharing-runtime-guest')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'No limit'));
    await tester.pumpAndSettle();
    expect(source.calls, ['quota:guest:3', 'runtime:guest:null']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner edits one person: Workers and mode, then resets',
      (tester) async {
    final source = SharingSource();
    final access = PersonAccessSource();
    await pump(
        tester,
        WorkspaceSharingSection(
            workspaceId: 'ws',
            source: source,
            memberAccessSource: AccessOnlySource(),
            personAccessSource: access,
            workers: [worker('a')]));
    expect(find.text('Show access'), findsOneWidget);
    expect(find.text('Edit access'), findsNothing);
    expect(find.text('Done'), findsNothing);
    expect(
        tester.getTopLeft(find.byKey(const ValueKey('sharing-quota-guest'))).dy,
        lessThan(tester.getTopLeft(find.text('Show access')).dy));
    await tester.tap(find.byKey(const ValueKey('sharing-edit-guest')));
    await tester.pumpAndSettle();
    expect(find.text('Access for Guest'), findsOneWidget);

    // Verify the permissions matrix grid is displayed
    expect(find.byType(DataTable), findsOneWidget);
    expect(find.text('Worker / Model'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Low'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    expect(find.text('Thorough'), findsOneWidget);
    expect(find.text('All efforts'), findsNothing);

    // No Workers shared yet, and the default mode is the safest one.
    await tester.tap(find.byKey(const ValueKey('share-worker-a')));
    await tester.pumpAndSettle();

    // Toggle effort for analysis model
    await tester
        .tap(find.byKey(const ValueKey('member-effort-analysis-high-a')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('member-access-save')));
    await tester.pumpAndSettle();
    expect(access.saved.single.mode, 'chat');
    expect(access.saved.single.workers.keys, ['a']);
    expect(
        access.saved.single.workers['a']?.modelEfforts?['analysis'], ['low']);

    await tester.tap(find.byKey(const ValueKey('person-access-reset')));
    await tester.pumpAndSettle();
    expect(access.resets, 1);
    await tester.ensureVisible(find.text('Show access'));
    await tester.tap(find.text('Show access'));
    await tester.pumpAndSettle();
    expect(find.byType(DataTable), findsNothing);
    expect(find.text('Show access'), findsOneWidget);
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('an invited person accepts and the banner clears',
      (tester) async {
    final source = SharingSource();
    var accepted = 0;
    await pump(
        tester,
        WorkspaceInvitationsBanner(
            source: source, onAccepted: () => accepted++));
    expect(
        find.textContaining('Lender invited you to use Mac'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('accept-workspace-invitation-m1')));
    await tester.pumpAndSettle();
    expect(source.calls, ['accept:m1']);
    expect(accepted, 1);
    expect(find.textContaining('invited you'), findsNothing);
  });

  testWidgets('Free owners see existing access but cannot invite',
      (tester) async {
    final source = SharingSource();
    await pump(
        tester,
        WorkspaceSharingSection(
            workspaceId: 'w',
            source: source,
            planSource: PlanSource(AxAccountPlan.free)));
    expect(find.byKey(const ValueKey('sharing-invite')), findsNothing);
    expect(find.byKey(const ValueKey('sharing-requires-paid')), findsOneWidget);
    expect(find.byKey(const ValueKey('sharing-paused')), findsOneWidget);
    expect(find.textContaining('Guest'), findsWidgets);
    await tester
        .tap(find.byKey(const ValueKey('sharing-revoke-invitation-i1')));
    await tester.pumpAndSettle();
    expect(source.calls, ['cancel:i1']);
  });

  testWidgets('paid owners can invite', (tester) async {
    await pump(
        tester,
        WorkspaceSharingSection(
            workspaceId: 'w',
            source: SharingSource(),
            planSource: PlanSource(const AxAccountPlan(
                isPaid: true, features: {workspaceSharingFeature}))));
    expect(find.byKey(const ValueKey('sharing-invite')), findsOneWidget);
    expect(find.byKey(const ValueKey('sharing-requires-paid')), findsNothing);
    expect(find.byKey(const ValueKey('sharing-paused')), findsNothing);
  });
}
