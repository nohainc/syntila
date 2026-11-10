import '../../ax/ax_models.dart';

/// Workflows that are currently supported for regular users.
const implementedWorkflowIds = <String>{
  'chat',
  'direct',
  'work',
  'plan_implement',
};

/// Workflows that need the requester's Syntila Plus. Cloud enforces this; on
/// Free the app still offers them and opens Plans & subscription when picked.
const plusWorkflowIds = <String>{'research', 'plan_implement'};

/// Plus workflows that are not in [implementedWorkflowIds] but are released
/// and shown to everyone.
const releasedPlusWorkflowIds = <String>{'research'};

/// Shown on a locked Implement workflow.
const implementPlusExplanation =
    'Implement plans the work in phases and carries them out step by step '
    'with verification. Available with Syntila Plus.';

/// Shown on a locked Research workflow.
const researchPlusExplanation =
    'Research compares independent investigations from different models and '
    'combines them into one outcome. Available with Syntila Plus.';

/// The account allowed to preview workflow definitions that are still under
/// development. This is a UI visibility rule; execution authorization remains
/// owned by Cloud, so preview never bypasses the Plus requirement.
const workflowPreviewAccountEmail = 'vitalii@nohainc.com';

bool canPreviewUnimplementedWorkflows(String? viewerEmail) =>
    viewerEmail?.trim().toLowerCase() == workflowPreviewAccountEmail;

enum WorkflowAccess { available, locked, hidden }

/// How [workflowId] appears for this viewer. Release (or preview) decides
/// whether it is shown at all; the plan only decides whether it can run.
WorkflowAccess workflowAccess(
  String workflowId, {
  String? viewerEmail,
  required bool hasPlus,
}) {
  final preview = canPreviewUnimplementedWorkflows(viewerEmail);
  final released = implementedWorkflowIds.contains(workflowId) ||
      releasedPlusWorkflowIds.contains(workflowId);
  if (!released && !preview) return WorkflowAccess.hidden;
  if (plusWorkflowIds.contains(workflowId) && !hasPlus) {
    return WorkflowAccess.locked;
  }
  return WorkflowAccess.available;
}

/// Explanation for a locked workflow, or null when it is not Plus-gated.
String? lockedWorkflowExplanation(String workflowId) => switch (workflowId) {
      'research' => researchPlusExplanation,
      'plan_implement' => implementPlusExplanation,
      _ => null,
    };

List<AxBuiltinWorkflow> visibleWorkflowDefinitions(
  Iterable<AxBuiltinWorkflow> definitions, {
  String? viewerEmail,
}) {
  if (canPreviewUnimplementedWorkflows(viewerEmail)) {
    return definitions.toList(growable: false);
  }
  return definitions
      .where((definition) =>
          implementedWorkflowIds.contains(definition.id) ||
          releasedPlusWorkflowIds.contains(definition.id))
      .toList(growable: false);
}
