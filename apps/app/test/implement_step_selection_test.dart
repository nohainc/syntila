import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/workflows/research_execution_selection.dart';

void main() {
  Future<List<(String, Map<String, dynamic>)>> open(WidgetTester tester,
      {Map<String, Map<String, dynamic>> selections = const {}}) async {
    final changes = <(String, Map<String, dynamic>)>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ResearchExecutionSelection.implement(
          configuration: null,
          workers: const [],
          selections: selections,
          // Stands in for the shared Worker/model/effort selector.
          selectorBuilder: (step, current, onChanged) => TextButton(
            key: ValueKey('pick-$step'),
            onPressed: () => onChanged({'workerId': 'w-$step'}),
            child: Text(current['workerId']?.toString() ?? 'default $step'),
          ),
          onChanged: (step, value) => changes.add((step, value)),
        ),
      ),
    ));
    await tester
        .tap(find.byKey(const ValueKey('implement-execution-selection')));
    await tester.pumpAndSettle();
    return changes;
  }

  testWidgets(
      'shows a selection for plan, implement and verify, unchanged by default',
      (tester) async {
    final changes = await open(tester);
    for (final step in ['plan', 'implement', 'verify']) {
      expect(find.byKey(ValueKey('pick-$step')), findsOneWidget);
      expect(find.text('default $step'), findsOneWidget);
    }
    expect(changes, isEmpty);
  });

  for (final step in ['plan', 'implement', 'verify']) {
    testWidgets('choosing for $step changes only $step', (tester) async {
      final changes = await open(tester);
      await tester.tap(find.byKey(ValueKey('pick-$step')));
      await tester.pumpAndSettle();
      expect(changes.single.$1, step);
      expect(changes.single.$2, {'workerId': 'w-$step'});
      expect(find.text('w-$step'), findsOneWidget);
      expect(find.textContaining('default '), findsNWidgets(2));
    });
  }

  testWidgets('shows previously chosen steps', (tester) async {
    await open(tester, selections: {
      'verify': {'workerId': 'saved'}
    });
    expect(find.text('saved'), findsOneWidget);
    expect(find.text('default plan'), findsOneWidget);
  });

  test('multi-step submission carries only per-step choices', () {
    const workflow = AxBuiltinWorkflow(
        id: 'plan_implement',
        version: 2,
        name: 'Implement',
        description: '',
        steps: [],
        snapshot: {},
        executionPolicy: AxWorkflowCapabilities(multiStep: true));
    expect(submissionExecutionSelection(workflow, {'workerId': 'x'}), isEmpty);
    final steps = {
      'plan': {'workerId': 'a'}
    };
    expect(
        submissionExecutionSelection(
            workflow, {'workerId': 'x', 'steps': steps}),
        {'steps': steps});
  });

  testWidgets('research window sets 2 to 4 researchers and picks each step',
      (tester) async {
    final changes = <(String, Map<String, dynamic>)>[];
    final counts = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ResearchExecutionSelection(
          configuration: null,
          workers: const [],
          selectorBuilder: (step, current, onChanged) => TextButton(
            key: ValueKey('pick-$step'),
            onPressed: () => onChanged({'workerId': 'w-$step'}),
            child: Text('default $step'),
          ),
          onChanged: (step, value) => changes.add((step, value)),
          onResearcherCountChanged: counts.add,
        ),
      ),
    ));
    await tester
        .tap(find.byKey(const ValueKey('research-execution-selection')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pick-research-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('pick-research-3')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('research-researcher-count')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4').last);
    await tester.pumpAndSettle();
    expect(counts, [4]);
    expect(find.byKey(const ValueKey('pick-research-4')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('pick-synthesis')));
    await tester.tap(find.byKey(const ValueKey('pick-synthesis')));
    expect(changes.single.$1, 'synthesis');
  });

  testWidgets('displays stripped short model names and middle dots',
      (tester) async {
    AxWorker makeWorker(String id, String name, String typeId, String modelId,
            String modelName) =>
        AxWorker(
          id: id,
          workspaceId: 'ws',
          workspaceName: 'Laptop',
          displayName: name,
          workerTypeId: typeId,
          status: 'ready',
          readinessState: 'ready',
          localConcurrencyLimit: 1,
          executionOptions: AxWorkerExecutionOptions(
            modelSelectionSupported: true,
            modelDiscovery: 'profile_catalog',
            allowsCustomModel: false,
            allowedModelIds: [modelId],
            modelSwitchSupported: true,
            effort: const AxWorkerEffortOptions(
                supported: true, values: ['low', 'high']),
            models: [
              AxWorkerModelOption(
                id: modelId,
                name: modelName,
                effort: const AxWorkerEffortOptions(
                    supported: true, values: ['low', 'high']),
              ),
            ],
          ),
        );

    final workerClaude = makeWorker('w-claude', 'Claude', 'claude',
        'claude-3-5-sonnet', 'Claude 3.5 Sonnet');
    final workerGpt =
        makeWorker('w-gpt', 'ChatGPT', 'chatgpt', 'gpt-4o', 'GPT-4o');
    final workerCustom = makeWorker(
        'w-custom', 'CustomWorker', 'custom', 'custom-pro', 'CustomWorker Pro');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ResearchExecutionSelection.implement(
          configuration: null,
          workers: [workerClaude, workerGpt, workerCustom],
          selections: const {
            'plan': {'workerId': 'w-claude', 'model': 'claude-3-5-sonnet'},
            'implement': {'workerId': 'w-gpt', 'model': 'gpt-4o'},
            'verify': {'workerId': 'w-custom', 'model': 'custom-pro'},
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final buttonFinder =
        find.byKey(const ValueKey('implement-execution-selection'));
    expect(buttonFinder, findsOneWidget);
    // Verifies that worker names are stripped so the model names are shorter:
    expect(find.descendant(of: buttonFinder, matching: find.text('3.5 Sonnet')),
        findsOneWidget);
    expect(find.descendant(of: buttonFinder, matching: find.text('4o')),
        findsOneWidget);
    expect(find.descendant(of: buttonFinder, matching: find.text('Pro')),
        findsOneWidget);
    expect(find.descendant(of: buttonFinder, matching: find.text('·')),
        findsNWidgets(2));
  });

  testWidgets('uses same color and style as chat/work workflow selection',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.light(),
      home: const Scaffold(
        body: ResearchExecutionSelection.implement(
          configuration: null,
          workers: [],
        ),
      ),
    ));
    final button = tester.widget<TextButton>(
      find.byKey(const ValueKey('implement-execution-selection')),
    );
    final context = tester
        .element(find.byKey(const ValueKey('implement-execution-selection')));
    final expectedColor = Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).colorScheme.onSurface;
    expect(button.style?.foregroundColor?.resolve({}), expectedColor);
    expect(button.style?.textStyle?.resolve({})?.fontWeight, FontWeight.w600);
  });

  test('multi-step submission keeps the researcher count', () {
    const workflow = AxBuiltinWorkflow(
        id: 'research',
        version: 2,
        name: 'Research',
        description: '',
        steps: [],
        snapshot: {},
        executionPolicy: AxWorkflowCapabilities(multiStep: true));
    expect(submissionExecutionSelection(workflow, {'researcherCount': 3}),
        {'researcherCount': 3});
  });
}
