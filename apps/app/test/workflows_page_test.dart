import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_app.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/ax_stores.dart';
import 'package:syntila_app/src/ax/sync/ax_session_catalogs.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/ax/sync/ax_workflow_configurations.dart';
import 'package:syntila_app/src/brand.dart';
import 'package:syntila_app/src/features/workflows/workflow_editor.dart';
import 'package:syntila_app/src/features/workflows/workflows_page.dart';
import 'package:syntila_app/src/features/workspace/workspaces_page.dart';
import 'package:syntila_app/src/navigation/ax_browser_navigation.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'ax_fixture_data.dart';
import 'workflow_editor_test.dart' show worker, choices;
import 'ax_fixture_realtime.dart';

AxBuiltinWorkflow workflow(String id, String name,
        {int version = 1,
        String? description,
        List<String> steps = const ['chat']}) =>
    AxBuiltinWorkflow(
      id: id,
      version: version,
      name: name,
      description: description ?? 'Description for $name',
      steps: [
        for (var i = 0; i < steps.length; i++)
          AxBuiltinWorkflowStep(kind: steps[i], order: i)
      ],
      snapshot: const {},
    );

class WorkflowSource extends AxFixtureDataSource
    implements
        AxWorkflowConfigurationDataSource,
        AxWorkflowDefaultDataSource,
        AxWorkflowWorkspaceDataSource {
  List<AxBuiltinWorkflow>? definitions;
  String? selectedWorkspace = 'ws';
  int workspaceReads = 0, workspaceWrites = 0;
  final selectedSpaceWorkspaces = <String, String?>{};
  @override
  Future<AxWorkflowWorkspaceSettings> loadWorkflowWorkspace(
      {String? spaceId}) async {
    workspaceReads++;
    return AxWorkflowWorkspaceSettings(
        // Test Spaces start with their own Workspace (as after migration
        // 0103); an explicit null entry means the Space has none.
        workspaceId: spaceId == null
            ? selectedWorkspace
            : selectedSpaceWorkspaces.containsKey(spaceId)
                ? selectedSpaceWorkspaces[spaceId]
                : selectedWorkspace,
        workspaces: const [
          AxWorkflowWorkspace(id: 'ws', name: 'First Workspace'),
          AxWorkflowWorkspace(id: 'other', name: 'Second Workspace')
        ]);
  }

  @override
  Future<AxWorkflowWorkspaceSettings> selectWorkflowWorkspace(
      {String? spaceId, String? workspaceId}) async {
    workspaceWrites++;
    if (spaceId == null) {
      selectedWorkspace = workspaceId;
      values = [];
    } else {
      selectedSpaceWorkspaces[spaceId] = workspaceId;
    }
    return loadWorkflowWorkspace(spaceId: spaceId);
  }

  int reads = 0, catalogReads = 0, writes = 0;
  bool fail = false;
  Completer<List<AxUserWorkflowConfiguration>>? pending;
  Completer<AxUserWorkflowConfiguration>? pendingSave;
  List<AxWorker> workers = [];
  List<AxUserWorkflowConfiguration> values = [];
  String defaultWorkflow = 'chat';

  /// Per-Workspace state used when a request addresses a Workspace.
  final scopedValues = <String, List<AxUserWorkflowConfiguration>>{};
  final scopedDefaults = <String, String>{};
  @override
  Future<String> loadWorkflowDefault({String? workspaceId}) async =>
      workspaceId == null
          ? defaultWorkflow
          : scopedDefaults[workspaceId] ?? 'chat';

  @override
  Future<String> saveWorkflowDefault(String workflowId,
      {String? workspaceId}) async {
    if (workspaceId == null) {
      defaultWorkflow = workflowId;
    } else {
      scopedDefaults[workspaceId] = workflowId;
    }
    return workflowId;
  }

  @override
  Future<String> loadSpaceWorkflowDefault(String spaceId) async =>
      defaultWorkflow;

  @override
  Future<List<AxUserWorkflowConfiguration>> loadWorkflowConfigurations(
      {String? workspaceId}) async {
    reads++;
    if (fail) throw StateError('Read failed');
    if (workspaceId != null) return scopedValues[workspaceId] ?? const [];
    return pending?.future ?? values;
  }

  @override
  Future<AxUserWorkflowConfiguration> saveWorkflowConfiguration(
      AxUserWorkflowConfiguration configuration,
      {String? workspaceId}) async {
    writes++;
    if (fail) throw StateError('Write failed');
    if (workspaceId != null) {
      scopedValues[workspaceId] = [configuration];
      return configuration;
    }
    if (pendingSave != null) return pendingSave!.future;
    values = [configuration];
    return configuration;
  }

  @override
  Future<AxUserWorkflowConfiguration> resetWorkflowConfiguration(
      String workflowId,
      {String? workspaceId}) async {
    if (workspaceId == null) {
      values = [];
    } else {
      scopedValues.remove(workspaceId);
    }
    return AxUserWorkflowConfiguration(workflowId: workflowId);
  }

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async {
    if (definitions != null) return definitions!;
    catalogReads++;
    return [
      workflow('chat', 'Chat'),
      workflow('direct', 'Direct'),
      workflow('direct', 'Work', version: 2, steps: ['implement']),
      workflow('plan_implement', 'Implement', version: 2, steps: ['plan']),
      workflow('research', 'Research',
          version: 2, steps: ['research', 'synthesis']),
    ];
  }

  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async => workers;
}

class MemoryAxBrowserNavigation implements AxBrowserNavigation {
  MemoryAxBrowserNavigation(this.current);
  @override
  Uri current;
  final controller = StreamController<Uri>.broadcast(sync: true);
  @override
  Stream<Uri> get changes => controller.stream;
  @override
  Stream<void> get lifecycleChanges => const Stream.empty();
  void emit(Uri uri) {
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
  testWidgets('regular users see only implemented workflows', (tester) async {
    final source = WorkflowSource();
    final engine = AxSyncEngine();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkflowsPage(
                    workspaceId: 'ws',
                    catalogs: AxSessionCatalogs(source, engine: engine),
                    configurations:
                        AxWorkflowConfigurations(source, engine: engine))))));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workflow-chat')), findsOneWidget);
    expect(find.byKey(const ValueKey('workflow-direct')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('workflow-plan_implement')), findsOneWidget);
    expect(find.text('Implement'), findsOneWidget);
  });

  testWidgets('Worker selectors align below short and wrapped descriptions',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = WorkflowSource()
      ..workers = [worker('a')]
      ..definitions = [
        workflow('chat', 'Chat', description: 'Short'),
        workflow('direct', 'Work',
            steps: ['implement'],
            description:
                'A longer description that wraps onto a second line in this card, keeping the Worker selection aligned with the adjacent card.'),
      ];
    final engine = AxSyncEngine();
    for (final scale in [1.0, 1.5]) {
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                  body: SingleChildScrollView(
                      child: WorkflowsPage(
                          workspaceId: 'ws',
                          catalogs: AxSessionCatalogs(source, engine: engine),
                          configurations:
                              AxWorkflowConfigurations(source, engine: engine)
                                  .forWorkspace('ws')))))));
      await tester.pumpAndSettle();
      final chat = tester
          .getTopLeft(find.byKey(const ValueKey('workflow-worker-chat-a')));
      final work = tester
          .getTopLeft(find.byKey(const ValueKey('workflow-worker-direct-a')));
      expect(chat.dy, closeTo(work.dy, 0.1));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('card edits preserve distinct default and step MCP selections',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = WorkflowSource()
      ..workers = [worker('a')]
      ..scopedValues['ws'] = [
        AxUserWorkflowConfiguration(
          workflowId: 'direct',
          defaults: const AxWorkflowSelection(mcpTools: ['files']),
          stepOverrides: {'implement': const AxWorkflowSelection(mcpTools: [])},
        )
      ];
    final engine = AxSyncEngine();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: WorkflowsPage(
        workspaceId: 'ws',
        catalogs: AxSessionCatalogs(source, engine: engine),
        configurations:
            AxWorkflowConfigurations(source, engine: engine).forWorkspace('ws'),
      ),
    ))));
    await tester.pumpAndSettle();
    final choice = find.byKey(const ValueKey('workflow-worker-direct-a'));
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    final saved =
        source.scopedValues['ws']!.singleWhere((v) => v.workflowId == 'direct');
    expect(saved.defaults.mcpTools, ['files']);
    expect(saved.stepOverrides['implement']!.mcpTools, isEmpty);
  });

  testWidgets('disabled workflow remains configurable without enabling it',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = WorkflowSource()
      ..workers = [worker('a')]
      ..scopedValues['ws'] = [
        AxUserWorkflowConfiguration(workflowId: 'direct', enabled: false)
      ];
    final engine = AxSyncEngine();
    final configurations =
        AxWorkflowConfigurations(source, engine: engine).forWorkspace('ws');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkflowsPage(
                    workspaceId: 'ws',
                    catalogs: AxSessionCatalogs(source, engine: engine),
                    configurations: configurations)))));
    await tester.pumpAndSettle();
    final choice = find.byKey(const ValueKey('workflow-worker-direct-a'));
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    final saved = source.scopedValues['ws']!
        .singleWhere((value) => value.workflowId == 'direct');
    expect(saved.defaults.worker, 'a');
    expect(saved.enabled, isFalse);
  });

  testWidgets(
      'using another Workspace asks first, keeps every Workspace\'s workflows and filters Workers',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final saved = AxUserWorkflowConfiguration(
        workflowId: 'chat',
        enabled: false,
        defaults: const AxWorkflowSelection(
            worker: 'a', model: 'analysis', effort: 'high'),
        stepOverrides: const {'chat': AxWorkflowSelection(effort: 'low')});
    final source = WorkflowSource()
      ..workers = [worker('a'), worker('b', workspaceId: 'other')]
      ..scopedValues['ws'] = [saved];
    final engine = AxSyncEngine();
    final root = AxWorkflowConfigurations(source, engine: engine);
    Widget page(String workspaceId) => MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkflowsPage(
                    key: ValueKey(workspaceId),
                    viewerEmail: 'vitalii@nohainc.com',
                    workspaceId: workspaceId,
                    catalogs: AxSessionCatalogs(source, engine: engine),
                    configurations: root.forWorkspace(workspaceId)))));
    await tester.pumpWidget(page('ws'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-workflow-research')));
    await tester.pumpAndSettle();
    // Only this Workspace's Workers can be chosen.
    await tester.tap(find.byKey(const ValueKey('workflow-step-research-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('override-research-1')));
    await tester.pumpAndSettle();
    expect(choices(tester, 'research-1', 'Worker'), ['', 'a']);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(page('other'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-workflow-research')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workflow-step-research-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('override-research-1')));
    await tester.pumpAndSettle();
    expect(choices(tester, 'research-1', 'Worker'), ['', 'b']);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    Future<void> askToUse() async {
      await tester
          .tap(find.byKey(const ValueKey('use-workspace-for-workflows')));
      await tester.pumpAndSettle();
      expect(find.text('Use this Workspace?'), findsOneWidget);
    }

    await askToUse();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(source.workspaceWrites, 0);
    await askToUse();
    await tester.tap(find.text('Use Workspace'));
    await tester.pumpAndSettle();
    expect(source.workspaceWrites, 1);
    expect(source.selectedWorkspace, 'other');
    // Selecting a Workspace no longer resets anyone's workflows.
    expect(source.scopedValues['ws'], [saved]);
    expect(root.engine.peek(root.forWorkspace('ws').query).data, [saved]);
  });
  testWidgets(
      'edit choices come from owned Profile capabilities and preserve offline selections',
      (tester) async {
    final source = WorkflowSource()
      ..workers = [
        const AxWorker(
          id: 'worker',
          workspaceId: 'ws',
          workspaceName: 'Laptop',
          workerTypeId: 'custom',
          displayName: 'Custom Worker',
          status: 'offline',
          readinessState: 'offline',
          localConcurrencyLimit: 1,
          executionOptions: AxWorkerExecutionOptions(
              modelSelectionSupported: true,
              modelDiscovery: 'profile_catalog',
              allowsCustomModel: false,
              allowedModelIds: ['custom-model'],
              models: [
                AxWorkerModelOption(
                    id: 'custom-model',
                    name: 'Custom Model',
                    effort: AxWorkerEffortOptions(
                        supported: true, values: ['thorough']))
              ],
              modelSwitchSupported: false,
              effort: AxWorkerEffortOptions(supported: false, values: [])),
        )
      ]
      ..values = [
        AxUserWorkflowConfiguration(
            workflowId: 'chat',
            defaults: const AxWorkflowSelection(
                worker: 'worker', model: 'custom-model', effort: 'thorough'))
      ];
    final engine = AxSyncEngine();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkflowsPage(
                    workspaceId: 'ws',
                    catalogs: AxSessionCatalogs(source, engine: engine),
                    configurations:
                        AxWorkflowConfigurations(source, engine: engine))))));
    await tester.pumpAndSettle();
    expect(find.text('Custom Worker · Unavailable'), findsOneWidget);
    expect(find.text('Custom Model'), findsOneWidget);
    expect(find.byKey(const ValueKey('open-workflow-chat')), findsNothing);
    expect(source.values.single.defaults.effort, 'thorough');
  });
  testWidgets(
      'cards are editable for any Workspace and wide pages use two columns',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = WorkflowSource()..selectedWorkspace = null;
    final engine = AxSyncEngine();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkflowsPage(
                    workspaceId: 'ws',
                    catalogs: AxSessionCatalogs(source, engine: engine),
                    configurations:
                        AxWorkflowConfigurations(source, engine: engine)
                            .forWorkspace('ws'),
                    viewerEmail: 'vitalii@nohainc.com')))));
    await tester.pumpAndSettle();

    // No Workspace is active, yet this Workspace's workflows can be edited.
    expect(find.byKey(const ValueKey('use-workspace-for-workflows')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('workflow-make-default-direct')),
        findsOneWidget);
    expect(
        tester
            .widget<InkWell>(
                find.byKey(const ValueKey('open-workflow-research')))
            .onTap,
        isNotNull);
    final chat = tester.getRect(find.byKey(const ValueKey('workflow-chat')));
    final work = tester.getRect(find.byKey(const ValueKey('workflow-direct')));
    expect(chat.width, closeTo(work.width, 1));
    expect(chat.width, greaterThan(240));
  });
  testWidgets('default workflow is selectable only from enabled workflows',
      (tester) async {
    final source = WorkflowSource()
      ..values = [
        AxUserWorkflowConfiguration(workflowId: 'direct', enabled: false),
      ];
    final engine = AxSyncEngine();
    final cache = AxWorkflowConfigurations(source, engine: engine);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkflowsPage(
                    workspaceId: 'ws',
                    catalogs: AxSessionCatalogs(source, engine: engine),
                    configurations: cache,
                    viewerEmail: 'vitalii@nohainc.com')))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workflow-default-chat')), findsOneWidget);
    expect(find.byKey(const ValueKey('workflow-default')), findsNothing);
    expect(find.byKey(const ValueKey('workflow-make-default-direct')),
        findsNothing);
    expect(source.defaultWorkflow, 'chat');
  });
  test('foreground recovery refreshes only active stale preferences', () async {
    var now = DateTime(2026);
    final source = WorkflowSource();
    final engine = AxSyncEngine(clock: () => now);
    final cache = AxWorkflowConfigurations(source, engine: engine);
    await cache.ensure();
    final cancel = engine.watch(cache.query, (_) {});
    await engine.refreshActiveStale();
    expect(source.reads, 1);
    now = now.add(const Duration(hours: 1));
    await engine.refreshActiveStale();
    expect(source.reads, 2);
    cancel();
    now = now.add(const Duration(hours: 1));
    await engine.refreshActiveStale();
    expect(source.reads, 2);
  });
  test(
      'cache deduplicates, reuses stale preferences on return, publishes writes and preserves failed refresh data',
      () async {
    var now = DateTime(2026);
    final source = WorkflowSource();
    final engine = AxSyncEngine(clock: () => now);
    final cache = AxWorkflowConfigurations(source, engine: engine);
    source.pending = Completer();
    final first = cache.ensure();
    final second = cache.ensure();
    expect(source.reads, 1);
    source.pending!.complete([]);
    await Future.wait([first, second]);
    source.pending = null;
    now = now.add(const Duration(hours: 2));
    await cache.ensure();
    expect(source.reads, 1);
    var notifications = 0;
    final cancel = engine.watch(cache.query, (_) => notifications++,
        fireImmediately: false);
    await cache
        .save(AxUserWorkflowConfiguration(workflowId: 'chat', enabled: false));
    expect(engine.peek(cache.query).data!.single.enabled, false);
    expect(notifications, greaterThan(0));
    expect(source.reads, 1);
    source.fail = true;
    await expectLater(cache.refresh(), throwsStateError);
    expect(engine.peek(cache.query).data!.single.enabled, false);
    await expectLater(
        cache.save(AxUserWorkflowConfiguration(workflowId: 'chat')),
        throwsStateError);
    expect(engine.peek(cache.query).data!.single.enabled, false);
    source.fail = false;
    await cache.reset('chat');
    expect(engine.peek(cache.query).data!.single.defaults.toJson(), isEmpty);
    cancel();
  });
  test(
      'session clearing fences pending reads and prevents a waiting write from starting',
      () async {
    final source = WorkflowSource()..pending = Completer();
    final store = AxStore(source, persistReadCache: false);
    final cache = store.workflowConfigurations;
    final write = cache.save(AxUserWorkflowConfiguration(workflowId: 'chat'));
    final rejected = expectLater(write, throwsA(isA<AxMutationSuperseded>()));
    store.clearServerState();
    source.pending!.complete([]);
    await rejected;
    expect(source.writes, 0);
    expect(store.syncEngine.peek(cache.query).hasData, false);
    source.pending = null;
    await cache.ensure();
    expect(source.reads, 2);
    store.dispose();
  });
  test('late save cannot repopulate another session', () async {
    final source = WorkflowSource()..pendingSave = Completer();
    final engine = AxSyncEngine();
    final cache = AxWorkflowConfigurations(source, engine: engine);
    await cache.ensure();
    final write = cache
        .save(AxUserWorkflowConfiguration(workflowId: 'chat', enabled: false));
    await Future<void>.delayed(Duration.zero);
    cache.clear();
    source.pendingSave!.complete(
        AxUserWorkflowConfiguration(workflowId: 'chat', enabled: false));
    await write;
    expect(engine.peek(cache.query).hasData, false);
  });
  testWidgets(
      'overview selects latest definitions, supports editing/reset and reuses preferences after recreation',
      (tester) async {
    final source = WorkflowSource()
      ..values = [
        AxUserWorkflowConfiguration(
            workflowId: 'direct',
            defaults:
                const AxWorkflowSelection(worker: 'offline', effort: 'high'))
      ];
    final engine = AxSyncEngine();
    final cache = AxWorkflowConfigurations(source, engine: engine);
    final catalogs = AxSessionCatalogs(source, engine: engine);
    Widget page() => MaterialApp(
        theme: SyntilaBrand.lightTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkflowsPage(
                    workspaceId: 'ws',
                    catalogs: catalogs,
                    configurations: cache,
                    viewerEmail: 'vitalii@nohainc.com'))));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('Direct'), findsNothing);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Saved Worker is no longer available'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    expect(find.text('2 steps'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-workflow-research')));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(WorkflowEditor), matching: find.byType(Switch)),
        findsNothing);
    expect(find.text('Default execution'), findsNothing);
    expect(find.text('Workflow steps'), findsOneWidget);
    expect(find.text('Advanced'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(source.reads, 1);
    await tester.tap(find.byKey(const ValueKey('open-workflow-research')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Disabled'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(source.reads, 1);
    expect(source.catalogReads, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'cold failure is a retryable error rather than an empty successful preference read',
      (tester) async {
    final source = WorkflowSource()..fail = true;
    final engine = AxSyncEngine();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkflowsPage(
                    workspaceId: 'ws',
                    catalogs: AxSessionCatalogs(source, engine: engine),
                    configurations:
                        AxWorkflowConfigurations(source, engine: engine))))));
    await tester.pumpAndSettle();
    expect(find.text('Workflow configuration is unavailable.'), findsOneWidget);
    source.fail = false;
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Chat'), findsAtLeastNWidgets(1));
    expect(source.reads, 2);
  });
  testWidgets('Workflows no longer have an application menu destination',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final browser = MemoryAxBrowserNavigation(Uri.parse('/workflows'));
    await tester.pumpWidget(SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: WorkflowSource(),
        browserNavigation: browser,
        realtimeClient: TestRealtime()));
    await tester.pumpAndSettle();
    // The legacy route opens the Workspaces page, which hosts Workflows.
    expect(find.byType(WorkspacesPage), findsOneWidget);
    await tester.tap(find.byTooltip('Application menu'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuItemButton, 'Workspaces'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'Workflows'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  Future<void> pumpEmbedded(
      WidgetTester tester, WorkflowSource source, String workspaceId) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final engine = AxSyncEngine();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkflowsPage(
                    workspaceId: workspaceId,
                    catalogs: AxSessionCatalogs(source, engine: engine),
                    configurations:
                        AxWorkflowConfigurations(source, engine: engine),
                    viewerEmail: 'vitalii@nohainc.com')))));
    await tester.pumpAndSettle();
  }

  testWidgets('embedded page hides the Workspace picker for the active one',
      (tester) async {
    await pumpEmbedded(tester, WorkflowSource(), 'ws');
    expect(find.byKey(const ValueKey('workflow-workspace')), findsNothing);
    expect(find.byKey(const ValueKey('use-workspace-for-workflows')),
        findsNothing);
    expect(
        find.byKey(const ValueKey('workspace-workflows-active')), findsNothing);
    expect(find.text('Active'), findsNothing);
    expect(find.byKey(const ValueKey('workflow-chat')), findsOneWidget);
    expect(find.byKey(const ValueKey('workflow-default')), findsNothing);
  });

  testWidgets(
      'another Workspace keeps editable workflows and can be made active',
      (tester) async {
    final source = WorkflowSource();
    await pumpEmbedded(tester, source, 'other');
    // Its workflows are editable although it is not the active Workspace.
    expect(find.byKey(const ValueKey('workflow-chat')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('workspace-workflows-active')), findsNothing);
    expect(
        tester
            .widget<InkWell>(
                find.byKey(const ValueKey('open-workflow-research')))
            .onTap,
        isNotNull);
    await tester.tap(find.byKey(const ValueKey('use-workspace-for-workflows')));
    await tester.pumpAndSettle();
    expect(find.text('Use this Workspace?'), findsOneWidget);
    await tester.tap(find.text('Use Workspace'));
    await tester.pumpAndSettle();
    expect(source.selectedWorkspace, 'other');
    expect(find.byKey(const ValueKey('use-workspace-for-workflows')),
        findsNothing);
  });

  testWidgets('Workspace tabs load workflow settings per Workspace',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = WorkflowSource()
      ..scopedValues['other'] = [
        AxUserWorkflowConfiguration(workflowId: 'chat', enabled: true)
      ]
      ..scopedDefaults['other'] = 'plan_implement';
    final engine = AxSyncEngine();
    final configurations = AxWorkflowConfigurations(source, engine: engine);
    final other = configurations.forWorkspace('other');
    expect(identical(other, configurations.forWorkspace('other')), isTrue);
    expect(other.queryKey, isNot(configurations.queryKey));
    expect(await other.ensure(), hasLength(1));
    expect(await other.ensureDefault(), 'plan_implement');
    expect(await configurations.forWorkspace('ws').ensure(), isEmpty);
    await other.save(
        AxUserWorkflowConfiguration(workflowId: 'direct', enabled: false));
    expect(source.scopedValues['other']!.single.workflowId, 'direct');
    expect(source.values, isEmpty);
  });

  testWidgets(
      'duplicate model IDs in worker execution options do not cause dropdown assertion error',
      (tester) async {
    const workerWithDuplicateModels = AxWorker(
      id: 'worker-dup',
      workspaceId: 'ws',
      workspaceName: 'Laptop',
      workerTypeId: 'gemini',
      displayName: 'Duplicate Worker',
      status: 'ready',
      readinessState: 'ready',
      localConcurrencyLimit: 1,
      executionOptions: AxWorkerExecutionOptions(
        modelDiscovery: 'profile_catalog',
        modelSelectionSupported: true,
        allowsCustomModel: false,
        allowedModelIds: ['claude-opus-5-5'],
        models: [
          AxWorkerModelOption(
            id: 'claude-opus-5-5',
            name: 'Claude Opus 5.5 (Low)',
            effort: AxWorkerEffortOptions(supported: true, values: ['low']),
          ),
          AxWorkerModelOption(
            id: 'claude-opus-5-5',
            name: 'Claude Opus 5.5 (Medium)',
            effort: AxWorkerEffortOptions(supported: true, values: ['medium']),
          ),
          AxWorkerModelOption(
            id: 'claude-opus-5-5',
            name: 'Claude Opus 5.5 (High)',
            effort: AxWorkerEffortOptions(supported: true, values: ['high']),
          ),
        ],
        modelSwitchSupported: false,
        effort: AxWorkerEffortOptions(supported: false, values: []),
      ),
    );

    final saved = AxUserWorkflowConfiguration(
      workflowId: 'chat',
      enabled: true,
      defaults: const AxWorkflowSelection(
        worker: 'worker-dup',
        model: 'claude-opus-5-5',
      ),
    );

    final source = WorkflowSource()
      ..workers = [workerWithDuplicateModels]
      ..scopedValues['ws'] = [saved];
    final engine = AxSyncEngine();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkflowsPage(
            workspaceId: 'ws',
            catalogs: AxSessionCatalogs(source, engine: engine),
            configurations: AxWorkflowConfigurations(source, engine: engine),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workflow-model-chat')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'workflow cards show Make default button opposite to Advanced button and omit Select a Worker badge',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = WorkflowSource()..selectedWorkspace = 'ws';
    final engine = AxSyncEngine();
    final configurations =
        AxWorkflowConfigurations(source, engine: engine).forWorkspace('ws');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkflowsPage(
            workspaceId: 'ws',
            catalogs: AxSessionCatalogs(source, engine: engine),
            configurations: configurations,
            viewerEmail: 'vitalii@nohainc.com',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Verify "Select a Worker" badge is omitted
    expect(find.text('Select a Worker'), findsNothing);

    // Chat is initial default: shows Default badge, no Make default button
    expect(find.byKey(const ValueKey('workflow-default-chat')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('workflow-make-default-chat')), findsNothing);
    expect(find.byKey(const ValueKey('workflow-advanced-chat')), findsNothing);

    // Direct is enabled and not default: shows Make default button and Advanced button
    expect(find.byKey(const ValueKey('workflow-make-default-direct')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('workflow-default-direct')), findsNothing);
    expect(
        find.byKey(const ValueKey('workflow-advanced-direct')), findsNothing);

    // Tapping Make default on Direct makes Direct the default workflow
    await tester
        .tap(find.byKey(const ValueKey('workflow-make-default-direct')));
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('workflow-default-direct')), findsOneWidget);
    expect(find.byKey(const ValueKey('workflow-make-default-direct')),
        findsNothing);
    expect(find.byKey(const ValueKey('workflow-default-chat')), findsNothing);
    expect(find.byKey(const ValueKey('workflow-make-default-chat')),
        findsOneWidget);
  });
}
