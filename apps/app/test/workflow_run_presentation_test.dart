import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';
import 'package:syntila_app/src/ax/workflow_run_presentation.dart';
import 'conversation_turn_fixture.dart';

AxBuiltinWorkflow definition(
        {String id = 'implement_verify',
        int version = 1,
        bool multiStep = true}) =>
    AxBuiltinWorkflow.fromJson({
      'id': id,
      'version': version,
      'name': 'Implement + Verify',
      'executionPolicy': {'multiStep': multiStep},
      'steps': [
        {'kind': 'implement', 'order': 0},
        {'kind': 'verify', 'order': 1},
        {'kind': 'correct', 'order': 2}
      ],
    });
Map<String, dynamic> step(String id, String role, String status, String worker,
        String model, String effort, List<String> turnIds) =>
    {
      'schemaVersion': 1,
      'id': 'step-$id',
      'workflowRunId': 'run-R',
      'taskId': 'task-$id',
      'stepId': id,
      'role': role,
      'status': status,
      'workerId': worker,
      'modelId': model,
      'effort': effort,
      'workerSessionId': null,
      'baseContextRevision': 0,
      'result': null,
      'workerTurnIds': turnIds,
    };
Map<String, dynamic> runJson() => {
      'schemaVersion': 1,
      'id': 'run-R',
      'conversationId': 'conversation-C',
      'userMessageId': 'message-user-R',
      'triggerMessageId': 'message-user-R',
      'workRequestId': 'R',
      'workflowId': 'implement_verify',
      'workflowVersion': 1,
      'status': 'running',
      'runtimeRunIds': ['runtime-R'],
      'workerTurnIds': ['turn-implement', 'turn-verify'],
      'createdAt': 'now',
      'updatedAt': 'now',
      'stepRuns': [
        // Deliberately reverse the persistence order: definition controls presentation.
        step('correct', 'implement', 'queued', 'chatgpt', 'model-X', 'medium',
            []),
        step('verify', 'verify', 'running', 'gemini', 'model-Y', 'high',
            ['turn-verify']),
        step('implement', 'implement', 'completed', 'chatgpt', 'model-X',
            'high', ['turn-implement']),
      ]
    };
AxConversationTurn turn(
        String id, String stepId, String name, String model, String effort) =>
    AxConversationTurn.fromJson({
      ...turnFixture(id: id).toJson(),
      'workflowId': 'implement_verify',
      'workflowVersion': 1,
      'taskId': 'task-$stepId',
      'workerId': name == 'Gemini' ? 'gemini' : 'chatgpt',
      'workerTypeId': name == 'Gemini' ? 'gemini' : 'chatgpt',
      'workflowRunId': 'run-R',
      'workflowStepRunId': 'step-$stepId',
      'workerDisplayName': name,
      'modelId': model,
      'effort': effort,
    });

void main() {
  test('run and step execution snapshots survive typed cache round trips', () {
    final config = <String, dynamic>{
      'schemaVersion': 1,
      'workerId': 'saved-worker',
      'profileId': 'signed-profile',
      'profileReleaseVersion': 4,
      'modelId': null,
      'effort': 'high',
      'workflowId': 'implement_verify',
      'workflowVersion': 1,
    };
    final json = runJson();
    json['executionConfigs'] = {'implement': config};
    (json['stepRuns'] as List).last['executionConfig'] = config;
    final restored =
        AxWorkflowRun.fromJson(AxWorkflowRun.fromJson(json).toJson());
    expect(restored.executionConfigs['implement']!.profileReleaseVersion, 4);
    expect(restored.stepRuns.last.executionConfig!.toJson(), config);
    expect(restored.executionConfigs['implement']!.modelId, isNull);
    expect(() => restored.executionConfigs.clear(), throwsUnsupportedError);
  });

  test(
      'requires explicit enablement and multi-step policy even when metadata has many steps',
      () {
    final run = AxWorkflowRun.fromJson(runJson());
    expect(
        prepareWorkflowRunPresentation(
            workflow: definition(), run: run, turns: []),
        isNull);
    for (final id in ['chat', 'direct']) {
      expect(
          prepareWorkflowRunPresentation(
              workflow: definition(id: id, multiStep: false),
              run: run,
              turns: [],
              enabled: true),
          isNull);
    }
  });
  test(
      'prepares ordered future rows with immutable actual Worker selection and pending binding labels',
      () {
    final presentation = prepareWorkflowRunPresentation(
        workflow: definition(),
        run: AxWorkflowRun.fromJson(runJson()),
        turns: [
          turn('turn-verify', 'verify', 'Gemini', 'actual-model-Y', 'high'),
          turn('turn-implement', 'implement', 'ChatGPT', 'actual-model-X',
              'high')
        ],
        enabled: true,
        stepLabels: {'correct': 'Correct'},
        pendingWorkerLabels: {'chatgpt': 'ChatGPT'})!;
    expect(presentation.title, 'Implement + Verify');
    expect(presentation.steps.map((row) => row.label),
        ['Implement', 'Verify', 'Correct']);
    expect(presentation.steps.map((row) => row.state), [
      AxWorkflowStepPresentationState.completed,
      AxWorkflowStepPresentationState.active,
      AxWorkflowStepPresentationState.pending
    ]);
    expect(presentation.steps.map((row) => row.workerName),
        ['ChatGPT', 'Gemini', 'ChatGPT']);
    expect(presentation.steps.map((row) => row.workerTypeId),
        ['chatgpt', 'gemini', null]);
    expect(presentation.steps.map((row) => row.modelId),
        ['actual-model-X', 'actual-model-Y', 'model-X']);
    expect(presentation.steps.map((row) => row.effort),
        ['high', 'high', 'medium']);
    expect(() => presentation.steps.clear(), throwsUnsupportedError);
  });
  test(
      'keeps default model/effort null and handles waiting, failed, cancelled states',
      () {
    for (final status in ['waiting', 'failed', 'cancelled']) {
      final json = runJson();
      final steps = json['stepRuns'] as List;
      (steps[2] as Map)['status'] = status;
      final actual = AxConversationTurn.fromJson({
        ...turn('turn-implement', 'implement', 'ChatGPT', 'ignored', 'high')
            .toJson(),
        'modelId': null,
        'effort': null
      });
      final presentation = prepareWorkflowRunPresentation(
          workflow: definition(),
          run: AxWorkflowRun.fromJson(json),
          turns: [actual],
          enabled: true)!;
      expect(presentation.steps.first.modelId, isNull);
      expect(presentation.steps.first.effort, isNull);
      expect(presentation.steps.first.state.name, status);
    }
  });
  test(
      'rejects mismatched definition, foreign turns, duplicate steps and incomplete state',
      () {
    final run = AxWorkflowRun.fromJson(runJson());
    expect(
        () => prepareWorkflowRunPresentation(
            workflow: definition(version: 2),
            run: run,
            turns: [],
            enabled: true),
        throwsFormatException);
    final foreign = AxConversationTurn.fromJson({
      ...turn('turn-implement', 'implement', 'ChatGPT', 'X', 'high').toJson(),
      'workflowRunId': 'foreign'
    });
    expect(
        () => prepareWorkflowRunPresentation(
            workflow: definition(), run: run, turns: [foreign], enabled: true),
        throwsFormatException);
    final duplicate = runJson();
    (duplicate['stepRuns'] as List).add((duplicate['stepRuns'] as List).first);
    expect(
        () => prepareWorkflowRunPresentation(
            workflow: definition(),
            run: AxWorkflowRun.fromJson(duplicate),
            turns: [],
            enabled: true),
        throwsFormatException);
    final missing = runJson();
    (missing['stepRuns'] as List).removeLast();
    expect(
        prepareWorkflowRunPresentation(
            workflow: definition(),
            run: AxWorkflowRun.fromJson(missing),
            turns: [],
            enabled: true),
        isNull);
  });
  test(
      'a missing latest invocation never attributes the step to an older Worker',
      () {
    final json = runJson();
    final steps = json['stepRuns'] as List;
    (steps[2] as Map)['workerTurnIds'] = ['turn-old', 'turn-latest'];
    (steps[2] as Map)['modelId'] = 'most-recent-model';
    final old =
        turn('turn-old', 'implement', 'Earlier Worker', 'earlier-model', 'low');
    final presentation = prepareWorkflowRunPresentation(
        workflow: definition(),
        run: AxWorkflowRun.fromJson(json),
        turns: [old],
        enabled: true,
        pendingWorkerLabels: {'chatgpt': 'Current catalog label'})!;
    expect(presentation.steps.first.workerName, 'Worker');
    expect(presentation.steps.first.modelId, 'most-recent-model');
    expect(presentation.steps.first.workerTypeId, isNull);
  });

  test('Research v2 shows each researcher with its model and a synthesis stage',
      () {
    final research = AxBuiltinWorkflow.fromJson({
      'id': 'research',
      'version': 2,
      'name': 'Research',
      'executionPolicy': {'multiStep': true},
      'steps': [
        {'id': 'research-1', 'kind': 'research', 'order': 0},
        {'id': 'research-2', 'kind': 'research', 'order': 1},
        {'id': 'synthesis', 'kind': 'synthesis', 'order': 2},
      ],
    });
    final run = AxWorkflowRun.fromJson({
      ...runJson(),
      'workflowId': 'research',
      'workflowVersion': 2,
      'workerTurnIds': <String>[],
      'stepRuns': [
        step('research-1', 'research', 'completed', 'chatgpt', 'model-a',
            'medium', []),
        step('research-2', 'research', 'queued', 'chatgpt', 'model-b', 'high',
            []),
        step('synthesis', 'synthesis', 'queued', 'claude', 'model-a', 'medium',
            []),
      ],
    });
    final presentation = prepareWorkflowRunPresentation(
      workflow: research,
      run: run,
      turns: const [],
      enabled: true,
    )!;
    expect(presentation.steps.map((s) => s.label),
        ['Researcher 1', 'Researcher 2', 'Synthesis']);
    expect(presentation.steps.map((s) => s.modelId),
        ['model-a', 'model-b', 'model-a']);
    // A branch waiting for capacity is shown as pending, not running.
    expect(presentation.steps.map((s) => s.state), [
      AxWorkflowStepPresentationState.completed,
      AxWorkflowStepPresentationState.pending,
      AxWorkflowStepPresentationState.pending,
    ]);
  });

  test('a Research v2 step keeps its instance ID for targeted retry', () {
    final step = AxWorkRequestStep.fromJson(
        {'kind': 'research', 'stepId': 'research-2', 'status': 'failed'});
    expect(step.kind, 'research');
    expect(step.id, 'research-2');
    expect(AxWorkRequestStep.fromJson({'kind': 'verify'}).id, 'verify');
  });
}
