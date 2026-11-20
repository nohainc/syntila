import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/features/workspace/worker_target_picker.dart';
import 'package:syntila_protocol/syntila_protocol.dart' show WorkerInstance;

WorkerInstance worker(
  String id, {
  String name = 'Laptop',
  String type = 'Codex',
  String alias = '',
  bool enabled = true,
  bool online = true,
  String? revokedAt,
}) =>
    WorkerInstance(
      id: id,
      actorId: 'actor-$id',
      workerTypeId: type.toLowerCase(),
      workerTypeName: type,
      name: name,
      description: alias,
      enabled: enabled,
      online: online,
      ready: false,
      readinessKnown: false,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      revokedAt: revokedAt,
    );

void main() {
  test('a unique name is shown as is', () {
    final labels = workerPickerLabels([worker('w1'), worker('w2', name: 'Desk')]);
    expect(labels, {'w1': 'Laptop', 'w2': 'Desk'});
  });

  test('duplicate names are told apart by Type, alias and ID suffix', () {
    final labels = workerPickerLabels([
      worker('worker-aaaa', type: 'Codex'),
      worker('worker-bbbb', type: 'Claude'),
      worker('worker-cccc', type: 'Claude', alias: 'home'),
      worker('worker-dddd', type: 'Claude', alias: 'home'),
    ]);
    expect(labels['worker-aaaa'], 'Laptop · Codex');
    expect(labels['worker-bbbb'], 'Laptop · Claude');
    expect(labels['worker-cccc'], 'Laptop · Claude · home · #cccc');
    expect(labels['worker-dddd'], 'Laptop · Claude · home · #dddd');
    expect(labels.values.toSet().length, 4);
  });

  test('status follows revoked, disabled, eligible, then online', () {
    expect(workerPickerState(worker('a', revokedAt: 'x'), {'a'}),
        WorkerPickerState.revoked);
    expect(workerPickerState(worker('a', enabled: false), {'a'}),
        WorkerPickerState.disabled);
    expect(workerPickerState(worker('a'), {'a'}), WorkerPickerState.available);
    expect(workerPickerState(worker('a', online: false), const {}),
        WorkerPickerState.offline);
    expect(workerPickerState(worker('a'), const {}),
        WorkerPickerState.notEligible);
  });
}
