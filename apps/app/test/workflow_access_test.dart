import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/features/workflows/workflow_visibility.dart';

void main() {
  const preview = workflowPreviewAccountEmail;

  test('Research stays hidden from everyone but preview until release', () {
    expect(releasedPlusWorkflowIds, isEmpty);
    // A Plus plan never exposes an unfinished workflow.
    expect(workflowAccess('research', viewerEmail: 'p@x.test', hasPlus: true),
        WorkflowAccess.hidden);
    expect(workflowAccess('research', viewerEmail: 'f@x.test', hasPlus: false),
        WorkflowAccess.hidden);
  });

  test('preview shows Research but never bypasses the Plus requirement', () {
    expect(workflowAccess('research', viewerEmail: preview, hasPlus: false),
        WorkflowAccess.locked);
    expect(workflowAccess('research', viewerEmail: preview, hasPlus: true),
        WorkflowAccess.available);
  });

  test('Chat, Work, and Implement stay available on Free', () {
    for (final id in ['chat', 'direct', 'plan_implement']) {
      expect(workflowAccess(id, viewerEmail: 'f@x.test', hasPlus: false),
          WorkflowAccess.available);
    }
  });

  test('a locked Research explains the Plus benefit', () {
    expect(
        lockedWorkflowExplanation('research'),
        'Research compares independent investigations from different models '
        'and combines them into one outcome. Available with Syntila Plus.');
    expect(lockedWorkflowExplanation('chat'), isNull);
  });

  test('the plan cache follows the server plan (upgrade and downgrade)', () {
    final cache = AxAccountPlanCache.instance;
    addTearDown(() => cache.plan = AxAccountPlan.free);
    expect(cache.has('workflow.research'), isFalse);
    cache.plan = AxAccountPlan.fromJson({
      'tier': 'paid',
      'features': ['workspace.sharing', 'workflow.research'],
    });
    expect(cache.has('workflow.research'), isTrue);
    cache.plan = AxAccountPlan.fromJson({'tier': 'free', 'features': []});
    expect(cache.has('workflow.research'), isFalse);
  });
}
