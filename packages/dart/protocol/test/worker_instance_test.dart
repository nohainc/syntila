import 'package:syntila_protocol/syntila_protocol.dart';
import 'package:test/test.dart';

void main() {
  final json = <String, Object?>{
    'id': 'wrk-1',
    'actorId': 'actor-worker-wrk-1',
    'workerTypeId': 'chatgpt',
    'workerTypeName': 'ChatGPT',
    'name': 'Writer',
    'description': '',
    'enabled': true,
    'online': false,
    'ready': false,
    'readinessKnown': true,
    'defaultModel': null,
    'createdAt': '2026-01-01T00:00:00.000Z',
    'updatedAt': '2026-01-01T00:00:00.000Z',
    'revokedAt': null,
  };

  test('round-trips and keeps enabled/online/ready separate', () {
    final worker = WorkerInstance.fromJson(json);
    expect(worker.enabled, isTrue);
    expect(worker.online, isFalse);
    expect(worker.isRevoked, isFalse);
    expect(worker.toJson(), json);
  });

  test('accepts older responses and preserves unknown readiness', () {
    final older = Map<String, Object?>.of(json)..remove('readinessKnown');
    expect(WorkerInstance.fromJson(older).readinessKnown, isTrue);
    expect(
        WorkerInstance.fromJson({...json, 'readinessKnown': false})
            .readinessKnown,
        isFalse);
  });

  test('two Workers with the same name and Type stay distinct', () {
    final list = parseWorkerInstances({
      'workers': [
        json,
        {...json, 'id': 'wrk-2', 'actorId': 'actor-worker-wrk-2'}
      ],
    });
    expect(list.map((w) => w.id), ['wrk-1', 'wrk-2']);
    expect(parseWorkerInstances(null), isEmpty);
  });
}
