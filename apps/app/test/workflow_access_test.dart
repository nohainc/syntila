import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/features/workflows/workflow_visibility.dart';

void main() {
  const preview = workflowPreviewAccountEmail;

  test('Research and Implement are shown to everyone and need Plus to run', () {
    for (final id in ['research', 'plan_implement']) {
      expect(workflowAccess(id, viewerEmail: 'f@x.test', hasPlus: false),
          WorkflowAccess.locked);
      expect(workflowAccess(id, viewerEmail: 'p@x.test', hasPlus: true),
          WorkflowAccess.available);
      expect(lockedWorkflowExplanation(id), contains('Syntila Plus'));
    }
  });

  test('Chat and Work stay available on Free', () {
    for (final id in ['chat', 'direct']) {
      expect(workflowAccess(id, viewerEmail: 'f@x.test', hasPlus: false),
          WorkflowAccess.available);
      expect(lockedWorkflowExplanation(id), isNull);
    }
  });

  test('unreleased workflows stay hidden from everyone but preview', () {
    expect(workflowAccess('full_cycle', viewerEmail: 'p@x.test', hasPlus: true),
        WorkflowAccess.hidden);
    expect(workflowAccess('full_cycle', viewerEmail: preview, hasPlus: true),
        WorkflowAccess.available);
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
