import 'package:syntila_design/syntila_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/ax_workflow_configuration.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'ax_fixture_data.dart';

const ownerSpace =
    AxSpace(id: 'S', name: 'Space', branch: '', lastActivity: 'now');
const memberThread = AxThread(
    id: 'T',
    spaceId: 'S',
    name: 'Member thread',
    lead: 'member',
    status: 'active',
    brief: '',
    primaryWorkspace: '',
    queueStatus: '',
    creatorEmail: 'member@example.test',
    creatorIsOwner: false,
    canExecuteWork: true);

class PermissionSource extends AxFixtureDataSource {
  AxSpacePermissions memberRights = AxSpacePermissions.forRole('collaborator');
  bool failSave = false;
  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async => [
        memberThread,
        const AxThread(
            id: 'owner-thread',
            spaceId: 'S',
            name: 'Owner thread',
            lead: 'owner',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: '',
            creatorEmail: 'owner@example.test')
      ];
  @override
  Future<List<AxSpaceMember>> loadSpaceMembers(
          {required String spaceId}) async =>
      [
        const AxSpaceMember(
            userId: 'owner',
            displayName: 'Owner name',
            email: 'owner@example.test',
            role: 'owner',
            createdAt: 'now'),
        AxSpaceMember(
            userId: 'member',
            displayName: 'Member',
            email: 'member@example.test',
            role: 'collaborator',
            createdAt: 'now',
            permissions: memberRights),
      ];
  @override
  Future<void> updateSpaceMemberPermissions(
      {required String spaceId,
      required String userId,
      required AxSpacePermissions permissions}) async {
    if (failSave) throw Exception('Save failed');
    memberRights = permissions;
  }

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        for (final id in ['chat', 'direct'])
          AxBuiltinWorkflow(
              id: id,
              version: 1,
              name: id == 'chat' ? 'Chat workflow' : 'Work workflow',
              description: '',
              steps: const [],
              snapshot: const {},
              composerBindingId: id),
      ];
}

AxWorker _worker(String id, String workspaceId, {bool shared = false}) =>
    AxWorker(
        id: id,
        workspaceId: workspaceId,
        workspaceName: 'Workspace $workspaceId',
        workerTypeId: 'chatgpt',
        displayName: 'ChatGPT',
        status: 'ready',
        readinessState: 'ready',
        localConcurrencyLimit: 1,
        shared: shared);

/// Space Workspace "space-ws"; the viewer owns "own-ws" and borrows "lent-ws".
class OwnWorkersSource extends PermissionSource
    implements
        AxWorkflowWorkspaceDataSource,
        AxSpaceWorkflowConfigurationDataSource {
  @override
  Future<List<AxUserWorkflowConfiguration>> loadSpaceWorkflowConfigurations(
          String spaceId) async =>
      const [];
  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async => [
        _worker('space-worker', 'space-ws', shared: true),
        _worker('own-worker', 'own-ws'),
        _worker('lent-worker', 'lent-ws', shared: true),
      ];
  @override
  Future<AxWorkflowWorkspaceSettings> loadWorkflowWorkspace(
          {String? spaceId}) async =>
      const AxWorkflowWorkspaceSettings(workspaceId: 'space-ws');
  @override
  Future<AxWorkflowWorkspaceSettings> selectWorkflowWorkspace(
          {String? spaceId, String? workspaceId, bool inherit = false}) =>
      loadWorkflowWorkspace(spaceId: spaceId);
}

Widget page(PermissionSource source, {AxSpace space = ownerSpace}) =>
    MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: SpacePage(
                    section: SpacePageSection.members,
                    space: space,
                    dataSource: source,
                    onOpenThread: (_) {},
                    onArchive: () {},
                    onDelete: () {}))));

void main() {
  testWidgets(
      'owner can change member rights in grid; owner checkboxes stay fixed; failed save preserves rights',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = PermissionSource();
    await tester.pumpWidget(page(source));
    await tester.pumpAndSettle();
    expect(find.text('Members'), findsOneWidget);
    expect(find.text('Name / email'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Invite'), findsOneWidget);
    expect(
        tester.getRect(find.text('Members')).bottom,
        lessThan(tester
            .getRect(find.text('Choose what each member can do in this Space.'))
            .top));
    final table = tester.widget<DataTable>(find.byType(DataTable));
    expect(
        find.descendant(
            of: find.byWidget(table.columns.first.label),
            matching: find.widgetWithText(TextButton, 'Invite')),
        findsOneWidget);
    expect(find.text('Created by member@example.test'), findsNothing);
    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('Add workspace'), findsNothing);
    expect(find.text('Invite members'), findsNothing);
    expect(
        tester
            .widget<Checkbox>(
                find.byKey(const ValueKey('permission-owner-chat')))
            .onChanged,
        isNull);
    await tester.tap(find.byKey(const ValueKey('permission-member-work')));
    await tester.pumpAndSettle();
    expect(source.memberRights.work, isFalse);
    source.failSave = true;
    await tester.tap(find.byKey(const ValueKey('permission-member-chat')));
    await tester.pumpAndSettle();
    expect(source.memberRights.chat, isTrue);
    expect(
        tester
            .widget<Checkbox>(
                find.byKey(const ValueKey('permission-member-chat')))
            .value,
        isTrue);
    await tester.pump(const Duration(seconds: 5));
  });
  testWidgets(
      'members tab shows renamed permission columns and legend; own Workers in Chat is removed from grid',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = PermissionSource();
    await tester.pumpWidget(page(source));
    await tester.pumpAndSettle();

    expect(find.text('Use Space AI for chat'), findsWidgets);
    expect(find.text('Use Space AI for work'), findsWidgets);
    expect(find.text('Create threads'), findsWidgets);
    expect(find.text('Chat workflow'), findsNothing);
    expect(find.text('Work workflow'), findsNothing);
    expect(find.text('Own threads'), findsNothing);
    expect(find.text('Own Workers in Chat'), findsNothing);

    final table = tester.widget<DataTable>(find.byType(DataTable));
    expect(table.columns.length, 5);
    expect(
        find.descendant(
            of: find.byWidget(table.columns[1].label),
            matching: find.byTooltip('Use Space AI for chat')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byWidget(table.columns[2].label),
            matching: find.byTooltip('Use Space AI for work')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byWidget(table.columns[3].label),
            matching: find.byTooltip('Create threads')),
        findsOneWidget);
    expect(find.byTooltip('Own Workers in Chat'), findsNothing);

    expect(find.byKey(const ValueKey('permission-member-useOwnWorkers')),
        findsNothing);
    expect(
        find.byKey(const ValueKey('permission-member-chat')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('permission-member-work')), findsOneWidget);
    expect(find.byKey(const ValueKey('permission-member-manageOwnThreads')),
        findsOneWidget);
  });
  test('own Workers is available by default and for all members', () {
    expect(const AxSpacePermissions().useOwnWorkers, isTrue);
    expect(AxSpacePermissions.forRole('viewer').useOwnWorkers, isTrue);
    expect(AxSpacePermissions.forRole('collaborator').useOwnWorkers, isTrue);
    expect(AxSpacePermissions.fromJson({}).useOwnWorkers, isTrue);
    expect(AxSpacePermissions.fromJson({'chat': false}).useOwnWorkers, isTrue);
    expect(
        AxSpacePermissions.fromJson({'chat': true, 'useOwnWorkers': true})
            .toJson()
            .keys,
        ['chat', 'useOwnWorkers', 'work', 'manageOwnThreads']);
  });
  testWidgets('member actions follow explicit rights, not collaborator role',
      (tester) async {
    final source = PermissionSource();
    final space = ownerSpace.copyWith(role: 'collaborator');
    await tester.pumpWidget(page(source,
        space: AxSpace(
            id: space.id,
            name: space.name,
            branch: '',
            lastActivity: '',
            role: 'collaborator',
            permissions: const AxSpacePermissions(chat: true))));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Create Thread'), findsNothing);
    expect(find.text('Workspaces'), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.byTooltip('Share Space'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Invite'), findsNothing);
    expect(
        tester
            .widget<Checkbox>(
                find.byKey(const ValueKey('permission-member-chat')))
            .onChanged,
        isNull);
  });
  testWidgets(
      'member Work permission filters composer choices and replaces Work default with Chat',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = PermissionSource();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'S',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'collaborator',
          permissions: AxSpacePermissions(chat: true)),
      thread:
          memberThread.copyWith(workConfig: {'defaultWorkflowId': 'direct'}),
      dataSource: source,
      initialTab: 1,
      onBackToSpace: () {},
      onArchive: () {},
    ))));
    await tester.pumpAndSettle();
    final chatToggle = find.byKey(const ValueKey('work-toggle-chat'));
    expect(chatToggle, findsOneWidget);
    final activeChatText = tester.widget<Text>(
        find.descendant(of: chatToggle, matching: find.text('Chat')));
    expect(activeChatText.style!.color!.a, 1.0);
    expect(find.text('Work workflow'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  for (final allowed in [true, false]) {
    testWidgets(
        'Chat offers only owned Workers outside the Space Workspace (allowed: $allowed)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
        space: AxSpace(
            id: 'S',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'collaborator',
            permissions:
                AxSpacePermissions(chat: true, useOwnWorkers: allowed)),
        thread:
            memberThread.copyWith(workConfig: {'defaultWorkflowId': 'chat'}),
        dataSource: OwnWorkersSource(),
        initialTab: 1,
        onBackToSpace: () {},
        onArchive: () {},
      ))));
      await tester.pumpAndSettle();
      final selector = tester
          .widget<ModelEffortSelector>(find.byType(ModelEffortSelector).first);
      final ids = selector.catalog.workers.map((worker) => worker.id).toList();
      expect(ids, contains('space-worker'));
      expect(ids.contains('own-worker'), allowed);
      expect(ids, isNot(contains('lent-worker')));
      if (allowed) {
        expect(selector.catalog.worker('own-worker')?.name,
            'ChatGPT · Workspace own-ws');
      }
    });
  }
}
