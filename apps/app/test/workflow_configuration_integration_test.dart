import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/sync/ax_session_catalogs.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/ax/sync/ax_workflow_configurations.dart';
import 'package:syntila_app/src/ax/sync/ax_work_history.dart';
import 'package:syntila_app/src/ax/sync/persistence/ax_thread_view_state.dart';
import 'package:syntila_app/src/ax/sync/persistence/ax_thread_view_state_store.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'workflows_page_test.dart' show WorkflowSource;
import 'workflow_editor_test.dart' show worker;

class IntegrationSource extends WorkflowSource
    implements AxSpaceWorkflowConfigurationDataSource {
  @override
  Future<AxWorkflowWorkspaceSettings> selectWorkflowWorkspace(
      {String? spaceId, String? workspaceId}) async {
    if (spaceId != null) {
      spaceValues.remove(spaceId);
      spaceDefaults.remove(spaceId);
    }
    return super
        .selectWorkflowWorkspace(spaceId: spaceId, workspaceId: workspaceId);
  }

  final spaceValues = <String, Map<String, AxUserWorkflowConfiguration>>{};
  final spaceDefaults = <String, String>{};
  int spaceReads = 0;
  @override
  Future<List<AxUserWorkflowConfiguration>> loadSpaceWorkflowConfigurations(
      String spaceId) async {
    spaceReads++;
    return {
      if (!selectedSpaceWorkspaces.containsKey(spaceId)) ...{
        for (final c in values) c.workflowId: c
      },
      ...?spaceValues[spaceId]
    }.values.toList();
  }

  @override
  Future<String> loadSpaceWorkflowDefault(String spaceId) async =>
      spaceDefaults[spaceId] ?? super.loadSpaceWorkflowDefault(spaceId);

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async =>
      (await super.loadBuiltinWorkflowCatalog())
          .map((workflow) => AxBuiltinWorkflow.fromJson({
                'id': workflow.id,
                'version': workflow.version,
                'name': workflow.name,
                'description': workflow.description,
                'steps': [
                  for (final step in workflow.steps)
                    {'kind': step.kind, 'order': step.order}
                ],
                'composerBindingId': workflow.id == 'direct'
                    ? 'direct'
                    : workflow.steps.length == 1
                        ? workflow.steps.single.kind
                        : null,
                'executionPolicy': {
                  'userSelectsWorker': true,
                  'userSelectsModel': true,
                  'userSelectsEffort': true
                }
              }))
          .toList();
  @override
  Future<List<Map<String, dynamic>>> loadSpaceWorkflowWorkspaceGrants(
          {required String spaceId}) async =>
      [
        {'workspaceId': 'ws'}
      ];
}

class _SlowWorkersSource extends IntegrationSource {
  final workersReady = Completer<void>();
  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async {
    await workersReady.future;
    return super.loadWorkspaceWorkerInventory();
  }
}

class _ResearchSource extends IntegrationSource {
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        ...await super.loadBuiltinWorkflowCatalog(),
        AxBuiltinWorkflow.fromJson({
          'id': 'research',
          'version': 2,
          'name': 'Research',
          'description': 'Independent investigations and synthesis',
          'steps': [
            {'id': 'research-1', 'kind': 'research', 'order': 0},
            {'id': 'research-2', 'kind': 'research', 'order': 1},
            {'id': 'synthesis', 'kind': 'synthesis', 'order': 2},
          ],
          'executionPolicy': {'multiStep': true, 'multiWorker': true},
          'composerBindingId': 'research',
        }),
      ];
}

void main() {
  testWidgets(
      'Research keeps workflow controls and exposes every configured execution',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final oldPlan = AxAccountPlanCache.instance.plan;
    AxAccountPlanCache.instance.plan =
        const AxAccountPlan(isPaid: true, features: {'workflow.research'});
    addTearDown(() => AxAccountPlanCache.instance.plan = oldPlan);
    final source = _ResearchSource()
      ..defaultWorkflow = 'research'
      ..workers = [worker('a')]
      ..values = [
        AxUserWorkflowConfiguration(
          workflowId: 'research',
          researcherCount: 3,
          defaults: const AxWorkflowSelection(
              worker: 'a', model: 'model-a', effort: 'careful'),
          stepOverrides: const {
            'research-2': AxWorkflowSelection(model: 'model-b'),
            'research-3': AxWorkflowSelection(model: 'model-c'),
            'synthesis': AxWorkflowSelection(model: 'synthesis-model'),
          },
        )
      ];
    final engine = AxSyncEngine();
    final store = MemoryAxThreadViewStateStore();
    await store.save(
        userId: 'user',
        threadId: 'research-thread',
        state: const AxThreadViewState(
          tabIndex: 1,
          workflowReference: 'research:v2',
          workerId: 'a',
          model: 'saved-one-step-model',
        ));
    Map<String, dynamic>? submitted;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space: const AxSpace(
          id: 's', name: 'Space', branch: '', lastActivity: '', role: 'owner'),
      thread: const AxThread(
          id: 'research-thread',
          spaceId: 's',
          name: 'Thread',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: '',
          canExecuteWork: true),
      currentUserId: 'user',
      viewerEmail: 'vitalii@nohainc.com',
      dataSource: source,
      catalogs: AxSessionCatalogs(source, engine: engine),
      workflowConfigurations: AxWorkflowConfigurations(source, engine: engine),
      workHistoryCache: AxWorkHistoryCache(source, engine: engine),
      threadViewStateStore: store,
      onBackToSpace: () {},
      onArchive: () {},
      onRunWorkWithSelection:
          (prompt, workflow, attachments, key, selection) async {
        expect(workflow, 'research');
        submitted = selection;
        return 'research-accepted';
      },
    ))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('work-workflow-track')), findsOneWidget);
    expect(find.byKey(const ValueKey('work-toggle-chat')), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('research-execution-selection')));
    await tester.pumpAndSettle();
    expect(
        find.textContaining(
            'Every message sent with Research starts a new investigation'),
        findsOneWidget);
    for (final title in [
      'Researcher 1',
      'Researcher 2',
      'Researcher 3',
      'Synthesis'
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    for (final model in ['model-a', 'model-b', 'model-c', 'synthesis-model']) {
      expect(find.textContaining(model), findsOneWidget);
    }
    expect(find.textContaining('saved-one-step-model'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Investigate this');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(submitted, isEmpty);
    await tester.tap(find.byKey(const ValueKey('work-toggle-chat')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('research-execution-selection')),
        findsNothing);
    expect(
        find.byKey(const ValueKey('work-composer-selection')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'a choice made before the saved selection resolves is not overwritten',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = _SlowWorkersSource()
      ..defaultWorkflow = 'direct'
      ..workers = [worker('a'), worker('b')];
    final engine = AxSyncEngine();
    final store = MemoryAxThreadViewStateStore();
    await store.save(
      userId: 'user',
      threadId: 'thread',
      state: const AxThreadViewState(
          tabIndex: 1,
          workflowReference: 'direct:v2',
          workerId: 'b',
          model: 'saved-model'),
    );
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
                initialTab: 1,
                space: const AxSpace(
                    id: 's',
                    name: 'Space',
                    branch: '',
                    lastActivity: '',
                    role: 'owner'),
                thread: const AxThread(
                    id: 'thread',
                    spaceId: 's',
                    name: 'Thread',
                    lead: '',
                    status: 'active',
                    brief: '',
                    primaryWorkspace: '',
                    queueStatus: '',
                    canExecuteWork: true),
                currentUserId: 'user',
                dataSource: source,
                catalogs: AxSessionCatalogs(source, engine: engine),
                workflowConfigurations:
                    AxWorkflowConfigurations(source, engine: engine),
                workHistoryCache: AxWorkHistoryCache(source, engine: engine),
                threadViewStateStore: store,
                onBackToSpace: () {},
                onArchive: () {}))));
    await tester.pump(const Duration(milliseconds: 50));
    // Workers are still loading, so the saved selection is pending.
    await tester.tap(find.byKey(const ValueKey('work-toggle-chat')));
    await tester.pumpAndSettle();
    source.workersReady.complete();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 250));
    final saved = await store.load(userId: 'user', threadId: 'thread');
    expect(saved?.workflowReference, startsWith('chat'));
    expect(saved?.model, isNot('saved-model'));
    expect(saved?.selectionUpdatedAt, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'global configuration updates and reset reach Thread controls without reloading',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = IntegrationSource()
      ..defaultWorkflow = 'direct'
      ..workers = [worker('a'), worker('b')]
      ..values = [
        AxUserWorkflowConfiguration(
            workflowId: 'direct',
            defaults: const AxWorkflowSelection(
                worker: 'a', model: 'analysis', effort: 'high'))
      ];
    final engine = AxSyncEngine();
    final cache = AxWorkflowConfigurations(source, engine: engine);
    final catalogs = AxSessionCatalogs(source, engine: engine);
    final history = AxWorkHistoryCache(source, engine: engine);
    var submitted = 0;
    Map<String, dynamic>? submittedSelection;
    Widget page(String id) => MaterialApp(
        home: Scaffold(
            body: ThreadPage(
                key: ValueKey(id),
                initialTab: 1,
                space: const AxSpace(
                    id: 's',
                    name: 'Space',
                    branch: '',
                    lastActivity: '',
                    role: 'owner'),
                thread: AxThread(
                    id: id,
                    spaceId: 's',
                    name: 'Thread',
                    lead: '',
                    status: 'active',
                    brief: '',
                    primaryWorkspace: '',
                    queueStatus: '',
                    canExecuteWork: true,
                    workConfig: const {
                      'defaultWorkflowId': 'direct',
                      'bindings': {
                        'direct': {
                          'workerId': 'obsolete',
                          'model': 'obsolete-model'
                        }
                      }
                    }),
                dataSource: source,
                catalogs: catalogs,
                workflowConfigurations: cache,
                workHistoryCache: history,
                onBackToSpace: () {},
                onArchive: () {},
                onRunWork: (prompt, workflow, attachments, key) async {
                  submitted++;
                  expect(workflow, 'direct');
                  return 'accepted';
                },
                onRunWorkWithSelection:
                    (prompt, workflow, attachments, key, selection) async {
                  submittedSelection = selection;
                  submitted++;
                  expect(workflow, 'direct');
                  return 'accepted';
                })));
    await tester.pumpWidget(page('one'));
    await tester.pumpAndSettle();
    expect(find.textContaining('First'), findsNothing);
    expect(find.textContaining('Analysis model'), findsOneWidget);
    expect(find.text('obsolete-model'), findsNothing);
    await requestChoice(tester, 'Worker', 'Second');
    await tester.tapAt(const Offset(790, 5));
    await tester.pumpAndSettle();
    expect(find.textContaining('Second'), findsNothing);
    expect(find.textContaining('Auto'), findsOneWidget);
    expect(source.values.single.defaults.worker, 'a');
    await cache.save(AxUserWorkflowConfiguration(
        workflowId: 'direct',
        defaults: const AxWorkflowSelection(
            worker: 'b', model: 'other', effort: 'careful')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Second'), findsNothing);
    expect(find.textContaining('Other model'), findsOneWidget);
    await cache.reset('direct');
    await tester.pumpAndSettle();
    expect(find.textContaining('Select a Worker'), findsOneWidget);
    await requestChoice(tester, 'Worker', 'Second');
    await requestChoice(tester, 'Model', 'Other model');
    await requestChoice(tester, 'Effort', 'Careful');
    await tester.tapAt(const Offset(790, 5));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Run with Auto');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(submitted, 1);
    expect(submittedSelection, {
      'workerId': 'b',
      'model': 'other',
      'reasoningEffort': 'careful',
    });
    expect(find.textContaining('Other model'), findsOneWidget);
    expect(find.textContaining('Careful'), findsOneWidget);
    await tester.pumpWidget(page('two'));
    await tester.pumpAndSettle();
    expect(source.reads, 1);
    expect(source.spaceReads, 3);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('switching Chat and Work keeps the last selected Worker',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = IntegrationSource()
      ..defaultWorkflow = 'direct'
      ..workers = [worker('a'), worker('b')];
    final engine = AxSyncEngine();
    String? submittedWorkflow;
    Map<String, dynamic>? submittedSelection;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
                initialTab: 1,
                space: const AxSpace(
                    id: 's',
                    name: 'Space',
                    branch: '',
                    lastActivity: '',
                    role: 'owner'),
                thread: const AxThread(
                    id: 'keep',
                    spaceId: 's',
                    name: 'Thread',
                    lead: '',
                    status: 'active',
                    brief: '',
                    primaryWorkspace: '',
                    queueStatus: '',
                    canExecuteWork: true,
                    workConfig: {'defaultWorkflowId': 'direct'}),
                dataSource: source,
                catalogs: AxSessionCatalogs(source, engine: engine),
                workflowConfigurations:
                    AxWorkflowConfigurations(source, engine: engine),
                workHistoryCache: AxWorkHistoryCache(source, engine: engine),
                onBackToSpace: () {},
                onArchive: () {},
                onRunWork: (prompt, workflow, attachments, key) async =>
                    'accepted',
                onRunWorkWithSelection:
                    (prompt, workflow, attachments, key, selection) async {
                  submittedWorkflow = workflow;
                  submittedSelection = selection;
                  return 'accepted';
                }))));
    await tester.pumpAndSettle();
    await requestChoice(tester, 'Worker', 'Second');
    await requestChoice(tester, 'Model', 'Other model');
    await requestChoice(tester, 'Effort', 'Careful');
    await tester.tapAt(const Offset(790, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chat').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Discuss');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(submittedWorkflow, startsWith('chat'));
    expect(submittedSelection?['workerId'], 'b');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('send is blocked until Worker, model and effort are chosen',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = IntegrationSource()
      ..defaultWorkflow = 'direct'
      ..workers = [worker('a'), worker('b')];
    final engine = AxSyncEngine();
    String? submittedWorkflow;
    Map<String, dynamic>? submittedSelection;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
                initialTab: 1,
                space: const AxSpace(
                    id: 's',
                    name: 'Space',
                    branch: '',
                    lastActivity: '',
                    role: 'owner'),
                thread: const AxThread(
                    id: 'keep',
                    spaceId: 's',
                    name: 'Thread',
                    lead: '',
                    status: 'active',
                    brief: '',
                    primaryWorkspace: '',
                    queueStatus: '',
                    canExecuteWork: true,
                    workConfig: {'defaultWorkflowId': 'direct'}),
                dataSource: source,
                catalogs: AxSessionCatalogs(source, engine: engine),
                workflowConfigurations:
                    AxWorkflowConfigurations(source, engine: engine),
                workHistoryCache: AxWorkHistoryCache(source, engine: engine),
                onBackToSpace: () {},
                onArchive: () {},
                onRunWork: (prompt, workflow, attachments, key) async =>
                    'accepted',
                onRunWorkWithSelection:
                    (prompt, workflow, attachments, key, selection) async {
                  submittedWorkflow = workflow;
                  submittedSelection = selection;
                  return 'accepted';
                }))));
    await tester.pumpAndSettle();
    await requestChoice(tester, 'Worker', 'Second');
    await tester.tapAt(const Offset(790, 5));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Discuss');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(submittedWorkflow, isNull);
    expect(find.textContaining('before sending.'), findsOneWidget);
    final box = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('work-composer-selection')));
    expect(((box.decoration as BoxDecoration).border as Border).top.color,
        isNot(Colors.transparent));
    await requestChoice(tester, 'Model', 'Other model');
    await requestChoice(tester, 'Effort', 'Careful');
    expect(find.textContaining('before sending.'), findsNothing);
    await tester.tapAt(const Offset(790, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(submittedWorkflow, isNotNull, reason: 'sent');
    expect(submittedSelection?['model'], 'other');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Thread Work tab has no thread execution settings',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = IntegrationSource();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
                initialTab: 2,
                space: const AxSpace(
                    id: 's',
                    name: 'Space',
                    branch: '',
                    lastActivity: '',
                    role: 'owner'),
                thread: const AxThread(
                    id: 't',
                    spaceId: 's',
                    name: 'Thread',
                    lead: '',
                    status: 'active',
                    brief: '',
                    primaryWorkspace: '',
                    queueStatus: ''),
                dataSource: source,
                onBackToSpace: () {},
                onArchive: () {}))));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.byTooltip('Work settings'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'Thread restores local tab, workflow, execution choices and drafts',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = IntegrationSource()
      ..defaultWorkflow = 'direct'
      ..workers = [worker('a'), worker('b')]
      ..values = [
        AxUserWorkflowConfiguration(
            workflowId: 'direct',
            defaults: const AxWorkflowSelection(
                worker: 'a', model: 'analysis', effort: 'high'))
      ];
    final engine = AxSyncEngine();
    final store = MemoryAxThreadViewStateStore();
    final catalogs = AxSessionCatalogs(source, engine: engine);
    final cache = AxWorkflowConfigurations(source, engine: engine);
    final history = AxWorkHistoryCache(source, engine: engine);
    await store.save(
      userId: 'user',
      threadId: 'thread',
      state: const AxThreadViewState(
        tabIndex: 1,
        workflowReference: 'direct:v1',
        workerId: 'b',
        model: 'removed-model',
        reasoningEffort: 'removed-effort',
        chatDraft: 'remember this chat',
        workDraft: 'remember this work',
      ),
    );
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
                initialTab: 0,
                space: const AxSpace(
                    id: 's',
                    name: 'Space',
                    branch: '',
                    lastActivity: '',
                    role: 'owner'),
                thread: const AxThread(
                    id: 'thread',
                    spaceId: 's',
                    name: 'Thread',
                    lead: '',
                    status: 'active',
                    brief: '',
                    primaryWorkspace: '',
                    queueStatus: '',
                    canExecuteWork: true),
                currentUserId: 'user',
                dataSource: source,
                catalogs: catalogs,
                workflowConfigurations: cache,
                workHistoryCache: history,
                threadViewStateStore: store,
                onBackToSpace: () {},
                onArchive: () {}))));
    // The saved view is applied synchronously, before the first frame.
    expect(find.text('remember this work'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.textContaining('Second'), findsNothing);
    expect(find.textContaining('removed-model · Unavailable'), findsOneWidget);
    expect(find.textContaining('Removed-effort · Unavailable'), findsOneWidget);
    expect(find.text('remember this work'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('composer-mode-message')));
    await tester.pumpAndSettle();
    expect(find.text('remember this chat'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'updated chat draft');
    await tester.pump(const Duration(milliseconds: 250));
    final saved = await store.load(userId: 'user', threadId: 'thread');
    expect(saved?.tabIndex, 0);
    expect(saved?.chatDraft, 'updated chat draft');
    expect(saved?.workDraft, 'remember this work');
    expect(saved?.model, 'removed-model');
    expect(saved?.reasoningEffort, 'removed-effort');
    await tester.pumpWidget(const SizedBox());
  });
  Future<AxThreadViewState?> restoreAndResave(WidgetTester tester,
      {required List<AxWorker> workers, AxThreadViewState? saved}) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = IntegrationSource()
      ..defaultWorkflow = 'direct'
      ..workers = workers
      ..values = [
        AxUserWorkflowConfiguration(
            workflowId: 'direct',
            defaults: const AxWorkflowSelection(worker: 'a'))
      ];
    final engine = AxSyncEngine();
    final store = MemoryAxThreadViewStateStore();
    if (saved != null) {
      await store.save(userId: 'user', threadId: 'thread', state: saved);
    }
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
                initialTab: 1,
                space: const AxSpace(
                    id: 's',
                    name: 'Space',
                    branch: '',
                    lastActivity: '',
                    role: 'owner'),
                thread: const AxThread(
                    id: 'thread',
                    spaceId: 's',
                    name: 'Thread',
                    lead: '',
                    status: 'active',
                    brief: '',
                    primaryWorkspace: '',
                    queueStatus: '',
                    canExecuteWork: true),
                currentUserId: 'user',
                dataSource: source,
                catalogs: AxSessionCatalogs(source, engine: engine),
                workflowConfigurations:
                    AxWorkflowConfigurations(source, engine: engine),
                workHistoryCache: AxWorkHistoryCache(source, engine: engine),
                threadViewStateStore: store,
                onBackToSpace: () {},
                onArchive: () {}))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'draft');
    await tester.pump(const Duration(milliseconds: 250));
    final result = await store.load(userId: 'user', threadId: 'thread');
    await tester.pumpWidget(const SizedBox());
    return result;
  }

  testWidgets('the Workflow default Worker is never saved as the Thread choice',
      (tester) async {
    final saved =
        await restoreAndResave(tester, workers: [worker('a'), worker('b')]);
    expect(saved?.workDraft, 'draft');
    expect(saved?.workerId, isNull);
  });

  testWidgets('a superseded saved Workflow keeps the saved Worker',
      (tester) async {
    final saved = await restoreAndResave(tester,
        workers: [worker('a'), worker('b')],
        saved: const AxThreadViewState(
            tabIndex: 1, workflowReference: 'removed:v1', workerId: 'b'));
    expect(saved?.workerId, 'b');
  });

  testWidgets(
      'a saved own Worker is not re-bound to a Space Worker of its type',
      (tester) async {
    final saved = await restoreAndResave(tester,
        workers: [worker('a'), worker('b', workspaceId: 'mine')],
        saved: const AxThreadViewState(
            tabIndex: 1,
            workflowReference: 'direct:v1',
            workerId: 'b',
            workerTypeId: 'custom'));
    expect(saved?.workerId, 'b');
  });
}

Future<void> requestChoice(
    WidgetTester tester, String label, String text) async {
  if (find.byKey(const ValueKey('work-composer-popup')).evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey('work-composer-open')));
    await tester.pumpAndSettle();
  }
  if (label == 'Worker') {
    final id = text == 'Second' ? 'b' : 'a';
    await tester.tap(find.byKey(ValueKey('work-composer-worker-$id')));
  } else if (label == 'Effort') {
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(slider.max);
  } else {
    await tester.tap(find.text(text).last);
  }
  await tester.pumpAndSettle();
}
