import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/instance_workers.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_protocol/syntila_protocol.dart' show WorkerInstance;

AxWorker _legacy(String id, String? instanceId) => AxWorker(
      id: id,
      workerInstanceId: instanceId,
      workspaceId: 'ws',
      workspaceName: 'Mac',
      workerTypeId: 'codex',
      displayName: 'Codex',
      status: 'ready',
      readinessState: 'ready',
      localConcurrencyLimit: 1,
    );

WorkerInstance _instance(String id,
        {bool online = true, bool enabled = true, String? revokedAt}) =>
    WorkerInstance(
      id: id,
      actorId: 'a-$id',
      workerTypeId: 'codex',
      workerTypeName: 'Codex',
      name: 'Worker $id',
      description: '',
      enabled: enabled,
      online: online,
      ready: true,
      createdAt: '2026-11-20T00:00:00Z',
      updatedAt: '2026-11-20T00:00:00Z',
      revokedAt: revokedAt,
    );

void main() {
  test('lists only the owner Worker Instances, not stale inventory', () {
    final inventory = [_legacy('l1', 'i1'), _legacy('l2', null)];
    expect(workersFromInstances(inventory, const []), isEmpty);
    final workers = workersFromInstances(inventory, [
      _instance('i1'),
      _instance('i2', online: false),
      _instance('i3', revokedAt: '2026-11-20T01:00:00Z'),
    ]);
    expect(workers.map((w) => w.id), ['i1', 'i2']);
    expect(workers.first.isReady, isTrue);
    expect(workers.last.isReady, isFalse);
  });
}
