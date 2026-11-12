import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/ax/sync/ax_session_catalogs.dart';
import 'package:syntila_app/src/ax/sync/ax_workflow_configurations.dart';
import 'package:syntila_app/src/ax/sync/ax_worker_visibility_preferences.dart';
import 'package:syntila_app/src/ax/workflow_configuration_options.dart';
import 'package:syntila_app/src/features/workflows/workflow_editor.dart';
import 'workflows_page_test.dart' show WorkflowSource, workflow;

AxWorker worker(String id,
        {bool offline = false,
        bool metadata = true,
        String workspaceId = 'ws',
        bool combined = false,
        String? catalogRevision}) =>
    AxWorker(
      id: id,
      workspaceId: workspaceId,
      workspaceName: 'Laptop',
      workerTypeId: 'custom',
      displayName: id == 'a' ? 'First' : 'Second',
      status: offline ? 'offline' : 'ready',
      readinessState: offline ? 'offline' : 'ready',
      localConcurrencyLimit: 1,
      executionOptions: !metadata
          ? null
          : AxWorkerExecutionOptions(
              catalogRevision: catalogRevision,
              modelSelectionSupported: true,
              modelDiscovery: 'profile_catalog',
              allowsCustomModel: false,
              allowedModelIds: id == 'a' ? ['analysis', 'review'] : ['other'],
              models: id == 'a'
                  ? [
                      AxWorkerModelOption(
                          id: 'analysis',
                          selectionMode: combined ? 'combined' : 'separate',
                          name: 'Analysis model',
                          effort: const AxWorkerEffortOptions(
                              supported: true, values: ['low', 'high'])),
                      const AxWorkerModelOption(
                          id: 'review',
                          name: 'Review model',
                          effort: AxWorkerEffortOptions(
                              supported: true, values: ['thorough'])),
                    ]
                  : const [
                      AxWorkerModelOption(
                          id: 'other',
                          name: 'Other model',
                          effort: AxWorkerEffortOptions(
                              supported: true, values: ['careful']))
                    ],
              modelSwitchSupported: false,
              effort: const AxWorkerEffortOptions(supported: false, values: []),
            ),
    );
const defaultSelection =
    AxWorkflowSelection(worker: 'a', model: 'analysis', effort: 'low');
AxUserWorkflowConfiguration configuration(
        {Map<String, AxWorkflowSelection> overrides = const {},
        AxWorkflowSelection defaults = defaultSelection}) =>
    AxUserWorkflowConfiguration(
        workflowId: 'plan_implement',
        defaults: defaults,
        stepOverrides: overrides);

Finder picker(String scope, String label) => find.byWidgetPredicate((widget) =>
    widget is DropdownButtonFormField<String> &&
    widget.key is ValueKey<String> &&
    (widget.key as ValueKey<String>).value.startsWith('$scope-$label-'));
Future<void> choose(
    WidgetTester tester, String scope, String label, String text) async {
  await tester.ensureVisible(picker(scope, label));
  await tester.tap(picker(scope, label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Iterable<String?> choices(
        WidgetTester tester, String scope, String label) =>
    tester
        .widget<DropdownButton<String>>(find.descendant(
            of: picker(scope, label),
            matching: find.byType(DropdownButton<String>)))
        .items!
        .map((item) => item.value);

Future<WorkflowSource> mount(
    WidgetTester tester, AxUserWorkflowConfiguration saved,
    {List<AxWorker>? workers,
    AxBuiltinWorkflow? definition,
    WorkflowSource? fixture,
    String? workspaceId,
    bool stepsOnly = false,
    AxWorkerVisibilityPreferences? visibility}) async {
  tester.view.physicalSize = const Size(1000, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final source = (fixture ?? WorkflowSource())
    ..values = [saved]
    ..workers = workers ?? [worker('a'), worker('b')];
  final engine = AxSyncEngine();
  final catalogs = AxSessionCatalogs(source, engine: engine);
  final cache = AxWorkflowConfigurations(source, engine: engine);
  await catalogs.ensureWorkers();
  await cache.ensure();
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => WorkflowEditor.open(
                      context,
                      WorkflowEditor(
                        stepsOnly: stepsOnly,
                        visibility: visibility,
                        workspaceId: workspaceId,
                        definition: definition ??
                            workflow('plan_implement', 'Implement',
                                steps: ['plan', 'implement', 'verify']),
                        configuration: saved,
                        catalogs: catalogs,
                        cache: cache,
                      )),
                  child: const Text('Open'))))));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return source;
}

Future<void> openStep(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(const ValueKey('workflow-advanced')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(ValueKey('workflow-step-$id')));
  await tester.tap(find.byKey(ValueKey('workflow-step-$id')));
  await tester.pumpAndSettle();
}

class VisibilityFixture extends WorkflowSource
    implements AxWorkerVisibilityDataSource {
  AxWorkerVisibility value = AxWorkerVisibility();
  @override
  Future<AxWorkerVisibility> loadWorkerVisibility(String id) async => value;
  @override
  Future<AxWorkerVisibility> saveWorkerVisibility(
          String id, AxWorkerVisibility v) async =>
      value = v;
  @override
  Future<AxWorkerVisibility> resetWorkerVisibility(String id) async =>
      value = AxWorkerVisibility();
}

void main() {
  testWidgets(
      'personal visibility refreshes choices while retaining saved values',
      (tester) async {
    final source = VisibilityFixture();
    final visibility =
        AxWorkerVisibilityPreferences(source, engine: AxSyncEngine())
            .forWorkspace('ws');
    await mount(tester, configuration(), visibility: visibility);
    expect(choices(tester, 'defaults', 'Model'), contains('review'));
    await visibility.save(AxWorkerVisibility(hiddenWorkers: [
      'b'
    ], hiddenModels: {
      'a': ['analysis', 'review']
    }, hiddenEfforts: {
      'a': {
        'analysis': ['low', 'high']
      }
    }));
    await tester.pumpAndSettle();
    expect(choices(tester, 'defaults', 'Worker'), isNot(contains('b')));
    expect(choices(tester, 'defaults', 'Model'), contains('analysis'));
    expect(choices(tester, 'defaults', 'Model'), isNot(contains('review')));
    expect(choices(tester, 'defaults', 'Effort'), contains('low'));
    expect(choices(tester, 'defaults', 'Effort'), isNot(contains('high')));
    expect(find.textContaining('Hidden in Workers for me'), findsWidgets);
    await visibility.reset();
    await tester.pumpAndSettle();
    expect(choices(tester, 'defaults', 'Model'), contains('review'));
  });
  test('MCP selections round-trip and an empty override disables inheritance',
      () {
    final saved = AxUserWorkflowConfiguration.fromJson({
      'schemaVersion': 1,
      'workflowId': 'plan_implement',
      'enabled': true,
      'defaults': {
        'worker': 'a',
        'mcpTools': ['files']
      },
      'stepOverrides': {
        'verify': {'mcpTools': <String>[]}
      },
    });
    expect(saved.toJson()['defaults'], {
      'worker': 'a',
      'mcpTools': ['files']
    });
    expect(saved.selectionFor('plan').mcpTools, ['files']);
    expect(saved.selectionFor('verify').mcpTools, isEmpty);
    expect((saved.toJson()['stepOverrides'] as Map)['verify'],
        {'mcpTools': <String>[]});
  });

  testWidgets(
      'editing Worker settings preserves default and step MCP selections',
      (tester) async {
    final source = await mount(
        tester,
        configuration(
          defaults: const AxWorkflowSelection(
              worker: 'a',
              model: 'analysis',
              effort: 'low',
              mcpTools: ['files']),
          overrides: {
            'verify': const AxWorkflowSelection(effort: 'low', mcpTools: [])
          },
        ));
    await choose(tester, 'defaults', 'Model', 'Review model');
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.defaults.mcpTools, ['files']);
    expect(source.values.single.stepOverrides['verify']!.mcpTools, isEmpty);
  });

  testWidgets('editing a step preserves its explicit empty MCP selection',
      (tester) async {
    final source = await mount(
        tester,
        configuration(
          defaults: const AxWorkflowSelection(
              worker: 'a',
              model: 'analysis',
              effort: 'low',
              mcpTools: ['files']),
          overrides: {
            'verify': const AxWorkflowSelection(effort: 'low', mcpTools: [])
          },
        ));
    await openStep(tester, 'verify');
    await choose(tester, 'verify', 'Effort', 'High');
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.defaults.mcpTools, ['files']);
    expect(source.values.single.stepOverrides['verify']!.mcpTools, isEmpty);
    expect(source.values.single.stepOverrides['verify']!.effort, 'high');
  });

  test('workflow defaults and inherited steps survive catalog revision changes',
      () {
    const saved = AxWorkflowSelection(
        worker: 'a', model: 'analysis', effort: 'low', catalogRevision: 'old');
    final options =
        AxWorkflowSelectionOptions([worker('a', catalogRevision: 'current')]);
    expect(options.validate(saved, saved: saved), isNull);
    final inherited = configuration(defaults: saved, overrides: {
      'verify':
          const AxWorkflowSelection(effort: 'high', catalogRevision: 'old'),
    });
    final selected = inherited.selectionFor('verify');
    expect(options.validate(selected, saved: selected), isNull);
    const removed = AxWorkflowSelection(
        worker: 'a',
        model: 'analysis',
        effort: 'removed',
        catalogRevision: 'old');
    expect(
        options.validate(removed, saved: removed), contains('not supported'));
    expect(saved.catalogRevision, 'old');
  });

  test(
      'combined families without a provider default require an explicit effort',
      () {
    final options = AxWorkflowSelectionOptions([worker('a', combined: true)]);
    const missing = AxWorkflowSelection(worker: 'a', model: 'analysis');
    expect(
        options.validate(const AxWorkflowSelection(worker: 'a'),
            saved: defaultSelection),
        contains('Select an explicit model'));
    expect(options.validate(missing, saved: defaultSelection),
        contains('Select an effort'));
    expect(options.validate(defaultSelection, saved: missing), isNull);
  });

  testWidgets(
      'a step can return to already-saved defaults while Worker metadata is unavailable',
      (tester) async {
    final saved = configuration(
        defaults: const AxWorkflowSelection(
            worker: 'missing', model: 'old-model', effort: 'old-effort'),
        overrides: {'verify': const AxWorkflowSelection(effort: 'high')});
    final source = await mount(tester, saved, workers: []);
    await openStep(tester, 'verify');
    await tester.ensureVisible(find.byKey(const ValueKey('reset-step-verify')));
    await tester.tap(find.byKey(const ValueKey('reset-step-verify')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNotNull);
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.stepOverrides, isEmpty);
    expect(source.values.single.defaults.toJson(), saved.defaults.toJson());
  });
  testWidgets(
      'workflow hides the explicit-model warning while keeping Save disabled',
      (tester) async {
    await mount(
      tester,
      configuration(defaults: const AxWorkflowSelection(worker: 'a')),
      workers: [worker('a', combined: true)],
    );
    expect(
        find.text('Select an explicit model for this Worker.'), findsNothing);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNull);
  });
  testWidgets('workflow hides the worker prompt while keeping Save disabled',
      (tester) async {
    await mount(
      tester,
      configuration(defaults: const AxWorkflowSelection()),
    );
    expect(find.text('Select a Worker.'), findsNothing);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNull);
  });
  testWidgets('workflow hides the effort prompt while keeping Save disabled',
      (tester) async {
    await mount(
      tester,
      configuration(
          defaults: const AxWorkflowSelection(worker: 'a', model: 'analysis')),
      workers: [worker('a', combined: true)],
    );
    expect(find.text('Select an effort for this model.'), findsNothing);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNull);
  });
  testWidgets(
      'inventory refresh revalidates the open draft without erasing saved selections',
      (tester) async {
    final source = await mount(tester, configuration());
    source.workers = [worker('b')];
    final editor = tester.widget<WorkflowEditor>(find.byType(WorkflowEditor));
    await editor.catalogs.refreshWorkers();
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Selected Worker is unavailable.'), findsOneWidget);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                picker('defaults', 'Worker'))
            .initialValue,
        'a');
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNotNull);
    expect(source.writes, 0);
  });
  testWidgets(
      'failed save preserves the draft and displays the error for explicit retry',
      (tester) async {
    final source = await mount(tester, configuration());
    await choose(tester, 'defaults', 'Model', 'Review model');
    source.fail = true;
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Write failed'), findsOneWidget);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                picker('defaults', 'Model'))
            .initialValue,
        'review');
    expect(source.values.single.defaults.model, 'analysis');
    source.fail = false;
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.defaults.model, 'review');
    expect(source.writes, 2);
    expect(source.reads, 1);
  });
  test('Worker selection is required before model and effort validation', () {
    final options = AxWorkflowSelectionOptions([worker('a'), worker('b')]);
    expect(options.models(null), isEmpty);
    expect(
        options
            .efforts(const AxWorkflowSelection(worker: 'a', model: 'analysis')),
        ['low', 'high']);
    expect(
        options.validate(
            const AxWorkflowSelection(model: 'analysis', effort: 'careful'),
            saved: const AxWorkflowSelection()),
        isNotNull);
    expect(
        options.validate(
            const AxWorkflowSelection(model: 'review', effort: 'thorough'),
            saved: const AxWorkflowSelection()),
        isNotNull);
    expect(
        options.validate(
            const AxWorkflowSelection(worker: 'b', model: 'analysis'),
            saved: defaultSelection),
        contains('model'));
    expect(
        options.validate(
            const AxWorkflowSelection(
                worker: 'a', model: 'review', effort: 'low'),
            saved: defaultSelection),
        contains('effort'));
  });
  test(
      'offline readiness preserves valid choices; missing Profile metadata preserves only unchanged intent',
      () {
    expect(
        AxWorkflowSelectionOptions([worker('a', offline: true)])
            .validate(defaultSelection, saved: const AxWorkflowSelection()),
        isNull);
    for (final workers in <List<AxWorker>>[
      [],
      [worker('a', metadata: false)]
    ]) {
      final options = AxWorkflowSelectionOptions(workers);
      expect(
          options.validate(defaultSelection, saved: defaultSelection), isNull);
      expect(
          options.validate(
              const AxWorkflowSelection(worker: 'a', model: 'review'),
              saved: defaultSelection),
          isNotNull);
    }
  });
  testWidgets(
      'Worker and model changes refresh dependent choices and clear explicit downstream values',
      (tester) async {
    final source = await mount(tester, configuration());
    expect(choices(tester, 'defaults', 'Worker'), ['', 'a', 'b']);
    expect(choices(tester, 'defaults', 'Worker').contains('Auto'), isFalse);
    expect(choices(tester, 'defaults', 'Effort'), ['', 'low', 'high']);
    await choose(tester, 'defaults', 'Model', 'Review model');
    expect(choices(tester, 'defaults', 'Effort'), ['', 'thorough']);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                picker('defaults', 'Effort'))
            .initialValue,
        '');
    await choose(tester, 'defaults', 'Worker', 'Second');
    expect(choices(tester, 'defaults', 'Model'), ['', 'other']);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                picker('defaults', 'Model'))
            .initialValue,
        '');
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.defaults.toJson(), {'worker': 'b'});
  });
  testWidgets(
      'effort-only step override inherits Worker/model and saves only the override; reset step restores inheritance',
      (tester) async {
    final source = await mount(tester, configuration());
    await openStep(tester, 'verify');
    await tester.tap(find.byKey(const ValueKey('override-verify')));
    await tester.pumpAndSettle();
    expect(choices(tester, 'verify', 'Effort'), ['', 'low', 'high']);
    await choose(tester, 'verify', 'Effort', 'High');
    expect(find.text('High effort'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.stepOverrides['verify']!.toJson(),
        {'effort': 'high'});
    expect(source.values.single.selectionFor('verify').worker, 'a');
    expect(source.values.single.selectionFor('plan').effort, 'low');
    final saved = source.values.single;
    final nextSource = await mount(tester, saved);
    await openStep(tester, 'verify');
    await tester.ensureVisible(find.byKey(const ValueKey('reset-step-verify')));
    await tester.tap(find.byKey(const ValueKey('reset-step-verify')));
    await tester.pumpAndSettle();
    expect(picker('verify', 'Worker'), findsNothing);
    expect(find.text('Inherit defaults'), findsNWidgets(3));
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(nextSource.values.single.stepOverrides, isEmpty);
  });
  testWidgets(
      'incompatible inherited combinations block Save until the step model and effort are corrected',
      (tester) async {
    final source = await mount(
        tester,
        configuration(
            overrides: {'verify': const AxWorkflowSelection(worker: 'b')}));
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNull);
    expect(source.writes, 0);
    await openStep(tester, 'verify');
    expect(find.textContaining('Verify: The selected model'), findsOneWidget);
    expect(
        find.text('Select an explicit model for this Worker.'), findsNothing);
    await choose(tester, 'verify', 'Model', 'Other model');
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNull);
    await choose(tester, 'verify', 'Effort', 'Careful');
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNotNull);
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.stepOverrides['verify']!.toJson(),
        {'worker': 'b', 'model': 'other', 'effort': 'careful'});
  });
  testWidgets(
      'use workflow defaults removes the entire override without touching other steps',
      (tester) async {
    final source = await mount(
        tester,
        configuration(overrides: {
          'verify': const AxWorkflowSelection(effort: 'high'),
          'plan': const AxWorkflowSelection(model: 'analysis')
        }));
    await openStep(tester, 'verify');
    await tester.tap(find.byKey(const ValueKey('inherit-verify')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.stepOverrides.keys, ['plan']);
    expect(source.values.single.defaults.toJson(), defaultSelection.toJson());
  });
  testWidgets(
      'missing saved Worker is visible and retained, and full reset clears Worker',
      (tester) async {
    final saved = configuration(
        defaults: const AxWorkflowSelection(
            worker: 'missing', model: 'old-model', effort: 'old-effort'),
        overrides: {'verify': const AxWorkflowSelection(effort: 'high')});
    final source = await mount(tester, saved, workers: []);
    expect(
        find.textContaining('Selected Worker is unavailable.'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNotNull);
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.toJson(), saved.toJson());
    final next = await mount(tester, saved, workers: []);
    await tester.tap(find.byKey(const ValueKey('reset-workflow')));
    await tester.pumpAndSettle();
    expect(next.values, isEmpty);
    expect(next.reads, 1);
  });
  testWidgets(
      'cancel discards local edits and fixed steps expose no structural editing',
      (tester) async {
    final source = await mount(tester, configuration());
    await choose(tester, 'defaults', 'Model', 'Review model');
    await tester.tap(find.byKey(const ValueKey('workflow-advanced')));
    await tester.pumpAndSettle();
    expect(find.text('1. Plan'), findsOneWidget);
    expect(find.text('2. Implement'), findsOneWidget);
    expect(find.text('3. Verify'), findsOneWidget);
    expect(find.byType(ReorderableListView), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(source.writes, 0);
    expect(source.values.single.defaults.toJson(), defaultSelection.toJson());
  });

  group('Research roles', () {
    const research = AxBuiltinWorkflow(
      id: 'research',
      version: 2,
      name: 'Research',
      description: 'Research',
      steps: [
        AxBuiltinWorkflowStep(kind: 'research', order: 0, id: 'research-1'),
        AxBuiltinWorkflowStep(kind: 'research', order: 1, id: 'research-2'),
        AxBuiltinWorkflowStep(kind: 'synthesis', order: 2, id: 'synthesis'),
      ],
      snapshot: {},
    );

    test('configuration schema 2 round-trips the researcher count and roles',
        () {
      final config = AxUserWorkflowConfiguration.fromJson({
        'schemaVersion': 2,
        'workflowId': 'research',
        'enabled': true,
        'researcherCount': 3,
        'defaults': {'worker': 'a'},
        'stepOverrides': {
          'research-1': {'model': 'analysis'},
          'synthesis': {'model': 'review'},
        },
      });
      expect(config.researcherCount, 3);
      expect(config.selectionFor('research-1').model, 'analysis');
      expect(config.toJson()['schemaVersion'], 2);
      expect(config.toJson()['researcherCount'], 3);
      expect(
          AxUserWorkflowConfiguration(workflowId: 'chat')
              .toJson()['schemaVersion'],
          1);
    });

    testWidgets('blocks saving until researchers use different explicit models',
        (tester) async {
      final source = await mount(
          tester,
          AxUserWorkflowConfiguration(
              workflowId: 'research',
              researcherCount: 2,
              defaults: defaultSelection),
          definition: research);
      await tester.tap(find.byKey(const ValueKey('workflow-advanced')));
      await tester.pumpAndSettle();
      expect(find.text('1. Researcher 1'), findsOneWidget);
      expect(find.text('3. Synthesis'), findsOneWidget);
      expect(
          find.textContaining(
              'Researcher 2: Uses the same model as Researcher 1'),
          findsOneWidget);
      final save = tester
          .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')));
      expect(save.onPressed, isNull);
      expect(source.scopedValues, isEmpty);
    });

    testWidgets(
        'renders stepsOnly editor without duplicate key assertion when definition steps omit id',
        (tester) async {
      // Research v2 definition where steps were loaded without explicit step id
      const untypedResearch = AxBuiltinWorkflow(
        id: 'research',
        version: 2,
        name: 'Research',
        description: 'Research',
        steps: [
          AxBuiltinWorkflowStep(kind: 'research', order: 0),
          AxBuiltinWorkflowStep(kind: 'research', order: 1),
          AxBuiltinWorkflowStep(kind: 'synthesis', order: 2),
        ],
        snapshot: {},
      );

      await mount(
        tester,
        AxUserWorkflowConfiguration(
          workflowId: 'research',
          researcherCount: 2,
          defaults: defaultSelection,
        ),
        definition: untypedResearch,
        stepsOnly: true,
      );

      await tester.pumpAndSettle();

      // Verify no duplicate key exception was thrown in the Column
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('workflow-step-research-1')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('workflow-step-research-2')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('workflow-step-synthesis')),
          findsOneWidget);
    });

    testWidgets(
        'disambiguates repeated step kinds when non-research workflow omits id',
        (tester) async {
      const repeatedKindWorkflow = AxBuiltinWorkflow(
        id: 'custom_pipeline',
        version: 1,
        name: 'Custom Pipeline',
        description: 'Pipeline',
        steps: [
          AxBuiltinWorkflowStep(kind: 'implement', order: 0),
          AxBuiltinWorkflowStep(kind: 'implement', order: 1),
        ],
        snapshot: {},
      );

      await mount(
        tester,
        AxUserWorkflowConfiguration(
          workflowId: 'custom_pipeline',
          defaults: defaultSelection,
        ),
        definition: repeatedKindWorkflow,
        stepsOnly: true,
      );

      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('workflow-step-implement-1')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('workflow-step-implement-2')),
          findsOneWidget);
    });
  });
}
