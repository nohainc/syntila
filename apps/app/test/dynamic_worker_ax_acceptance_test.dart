import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AX spaces a Profile Lab-created Worker into Work execution history',
      () {
    const workerTypeId = 'phase-13-unknown-provider';
    final worker = AxWorker.fromJson({
      'id': 'worker-phase13',
      'workerTypeId': workerTypeId,
      'displayName': 'Phase 13 Unknown Worker',
      'catalogLifecycleState': 'active',
      'catalogVisibilityState': 'visible',
      'status': 'ready',
      'readinessState': 'ready',
      'activationState': 'enabled',
      'localConcurrencyLimit': 1,
      'capabilities': ['text', 'thread_write', 'durable_session'],
      'profileDefinitionId': 'phase-13-profile',
      'profileReleaseVersion': 1,
      'providerToolName': 'Phase 13 Fixture CLI',
      'providerToolVersion': '1.2.3',
    });

    expect(worker.workerTypeId, workerTypeId);
    expect(worker.displayName, 'Phase 13 Unknown Worker');
    expect(worker.profileDefinitionId, 'phase-13-profile');
    expect(worker.status, 'ready');

    final workStep = AxWorkRequestStep.fromJson({
      'kind': 'implement',
      'status': 'completed',
      'workerId': worker.id,
      'workerTypeId': worker.workerTypeId,
      'workerDisplayName': worker.displayName,
      'profileDefinitionId': worker.profileDefinitionId,
      'profileReleaseVersion': worker.profileReleaseVersion,
      'providerToolName': worker.providerToolName,
      'providerToolVersion': worker.providerToolVersion,
      'resultText': 'WORK_DONE',
      'assignmentId': 'phase13-work-assignment',
      'sessionPolicy': 'stateless',
    });
    expect(workStep.workerTypeId, workerTypeId);
    expect(workStep.workerDisplayName, worker.displayName);
    expect(workStep.providerToolName, 'Phase 13 Fixture CLI');
    expect(workStep.resultText, 'WORK_DONE');
  });
}
