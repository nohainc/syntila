import 'ax_models.dart';
import 'ax_work_models.dart';

/// Presentation preparation only; current Chat/Work never opt in.
enum AxWorkflowStepPresentationState {
  completed,
  active,
  pending,
  waiting,
  failed,
  cancelled,
}

class AxWorkflowStepPresentation {
  const AxWorkflowStepPresentation({
    required this.id,
    required this.label,
    required this.state,
    required this.workerName,
    required this.workerTypeId,
    required this.modelId,
    required this.effort,
  });
  final String id;
  final String label;
  final AxWorkflowStepPresentationState state;
  final String workerName;
  final String? workerTypeId;
  final String? modelId;
  final String? effort;
}

class AxWorkflowRunPresentation {
  AxWorkflowRunPresentation(
      {required this.title,
      required Iterable<AxWorkflowStepPresentation> steps})
      : steps = List.unmodifiable(steps);
  final String title;
  final List<AxWorkflowStepPresentation> steps;
}

/// Explicit product opt-in AND a pinned multi-step definition are required.
/// Step labels/order come from the workflow definition, never inferred from
/// invocation count. Pending Worker labels can come from frozen binding labels.
AxWorkflowRunPresentation? prepareWorkflowRunPresentation({
  required AxBuiltinWorkflow workflow,
  required AxWorkflowRun run,
  required List<AxConversationTurn> turns,
  bool enabled = false,
  Map<String, String> stepLabels = const {},
  Map<String, String> pendingWorkerLabels = const {},
}) {
  if (!enabled || !workflow.executionPolicy.multiStep) return null;
  if (run.workflowId != workflow.id ||
      run.workflowVersion != workflow.version) {
    throw const FormatException('Workflow presentation definition mismatch');
  }
  final steps = {for (final step in run.stepRuns) step.stepId: step};
  final definitionSteps = [...workflow.steps]
    ..sort((a, b) => a.order.compareTo(b.order));
  // Step Runs are keyed by step-instance ID (the kind unless repeated).
  final definitionIds = definitionSteps.map((step) => step.instanceId).toList();
  if (definitionSteps.length < 2 ||
      definitionSteps.any((step) => step.kind.isEmpty || step.order < 0) ||
      definitionSteps.map((step) => step.order).toSet().length !=
          definitionSteps.length ||
      steps.length != run.stepRuns.length ||
      run.stepRuns.map((step) => step.id).toSet().length !=
          run.stepRuns.length ||
      definitionIds.toSet().length != definitionIds.length ||
      steps.keys.any((id) => !definitionIds.contains(id)) ||
      run.stepRuns.any((step) => step.workflowRunId != run.id)) {
    throw const FormatException('Invalid Workflow presentation step scope');
  }
  // Missing execution state must not be presented as invented pending work.
  if (definitionIds.any((id) => !steps.containsKey(id))) return null;
  final turnsById = {for (final turn in turns) turn.id: turn};
  return AxWorkflowRunPresentation(
    title: workflow.name,
    steps: definitionIds.map((id) {
      final step = steps[id]!;
      for (final turnId in step.workerTurnIds) {
        final turn = turnsById[turnId];
        if (turn == null) continue;
        if (turn.workflowRunId != run.id ||
            turn.workflowStepRunId != step.id ||
            turn.conversationId != run.conversationId ||
            turn.workRequestId != run.workRequestId ||
            turn.workflowId != run.workflowId ||
            turn.workflowVersion != run.workflowVersion ||
            turn.taskId != step.taskId) {
          throw const FormatException(
              'Worker turn presentation scope mismatch');
        }
      }
      final latest = step.workerTurnIds.isEmpty
          ? null
          : turnsById[step.workerTurnIds.last];
      return AxWorkflowStepPresentation(
        id: step.id,
        label: stepLabels[id] ?? _instanceLabel(id, step.role),
        state: switch (step.status) {
          'completed' => AxWorkflowStepPresentationState.completed,
          'running' => AxWorkflowStepPresentationState.active,
          'queued' => AxWorkflowStepPresentationState.pending,
          'waiting' => AxWorkflowStepPresentationState.waiting,
          'failed' => AxWorkflowStepPresentationState.failed,
          'cancelled' => AxWorkflowStepPresentationState.cancelled,
          _ => throw const FormatException('Unknown Workflow step status'),
        },
        workerName: latest?.workerDisplayName ??
            (step.workerTurnIds.isEmpty
                ? pendingWorkerLabels[step.workerId]
                : null) ??
            'Worker',
        workerTypeId: latest?.workerTypeId,
        modelId: latest != null ? latest.modelId : step.modelId,
        effort: latest != null ? latest.effort : step.effort,
      );
    }),
  );
}

/// "Researcher 2" for Research v2 instances; the role label otherwise.
String _instanceLabel(String id, String role) {
  final researcher = RegExp(r'^research-(\d+)$').firstMatch(id);
  if (role == 'research' && researcher != null) {
    return 'Researcher ${researcher.group(1)}';
  }
  return _roleLabel(role);
}

String _roleLabel(String role) => switch (role) {
      'synthesis' => 'Synthesis',
      'chat' => 'Chat',
      'research' => 'Research',
      'plan' => 'Plan',
      'implement' => 'Implement',
      'test' => 'Test',
      'verify' => 'Verify',
      'correct' || 'fix' => 'Correct',
      _ => 'Step',
    };
