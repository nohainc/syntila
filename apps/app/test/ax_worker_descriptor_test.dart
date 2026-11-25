import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AX parses Cloud-composed Worker metadata with local Worker state', () {
    final worker = AxWorker.fromJson({
      'id': 'workspace-worker-dynamic',
      'workspaceId': 'workspace-1',
      'workerTypeId': 'dynamic-test-worker',
      'displayName': 'Dynamic Test Worker',
      'description': 'Catalog-created acceptance Worker.',
      'status': 'needs_attention',
      'readinessState': 'setup_required',
      'localConcurrencyLimit': 1,
      'capabilities': ['text'],
    });

    expect(worker.displayName, 'Dynamic Test Worker');
    expect(worker.description, 'Catalog-created acceptance Worker.');
    expect(worker.status, 'needs_attention');
  });
}
