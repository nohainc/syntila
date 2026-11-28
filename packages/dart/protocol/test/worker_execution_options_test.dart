import 'package:syntila_protocol/syntila_protocol.dart';
import 'package:test/test.dart';

void main() {
  const worker =
      WorkerSelectionCapability(id: 'worker', name: 'Worker', models: [
    ExecutionModelCapability(
        id: 'family',
        name: 'Family',
        selectionMode: 'combined',
        efforts: ['small', 'large']),
    ExecutionModelCapability(
        id: 'renamed', name: 'Renamed', efforts: ['small']),
    ExecutionModelCapability(
        id: 'retired', name: 'Retired', status: 'unavailable'),
  ]);
  test(
      'validates exact pairs, missing combined defaults and unavailable models',
      () {
    expect(
        worker.validate(
            const ExecutionSelection(model: 'family', effort: 'small')),
        isNull);
    expect(worker.validate(const ExecutionSelection(model: 'family')),
        contains('Select an effort'));
    expect(
        worker.validate(
            const ExecutionSelection(model: 'family', effort: 'guessed')),
        contains('not supported'));
    expect(worker.supportsModel('retired'), isFalse);
    expect(worker.supportsModel('unknown'), isFalse);
    expect(worker.validate(const ExecutionSelection()),
        contains('Select an explicit model'));
  });
  test('a model is required only while the catalog lists one', () {
    const listed = WorkerSelectionCapability(
        id: 'copilot',
        name: 'Copilot',
        models: [ExecutionModelCapability(id: 'auto', name: 'Auto')]);
    const empty = WorkerSelectionCapability(id: 'free', name: 'Free');
    expect(listed.allowsImplicitModel, isFalse);
    expect(listed.validate(const ExecutionSelection()),
        contains('Select an explicit model'));
    expect(listed.validate(const ExecutionSelection(model: 'auto')), isNull);
    expect(empty.allowsImplicitModel, isTrue);
    expect(empty.validate(const ExecutionSelection()), isNull);
  });
  test('retains only supported explicit efforts on deliberate model changes',
      () {
    const catalog = ExecutionSelectionCatalog([worker]);
    const value =
        ExecutionSelection(worker: 'worker', model: 'family', effort: 'large');
    expect(catalog.changeModel(value, 'renamed').effort, isNull);
    expect(
        catalog
            .changeModel(
                const ExecutionSelection(
                    worker: 'worker', model: 'family', effort: 'small'),
                'renamed')
            .effort,
        'small');
    expect(value.effort, 'large');
  });
  test('projects legacy and v2 public options without provider logic', () {
    for (final schema in [1, 2]) {
      final projected = WorkerSelectionCapability.fromExecutionOptions(
          id: 'worker',
          name: 'Worker',
          options: {
            'schemaVersion': schema,
            'catalogStale': true,
            'models': {
              'supported': true,
              'options': [
                {
                  'id': 'model',
                  'name': 'Model',
                  if (schema == 1)
                    'effort': {
                      'values': ['actual'],
                      'defaultValue': 'actual'
                    }
                  else ...{
                    'efforts': ['actual'],
                    'defaultEffort': 'actual',
                    'selectionMode': 'separate',
                    'status': 'verified'
                  }
                }
              ],
              'allowedModelIds': ['model']
            },
            'effort': {'values': <String>[]},
          });
      expect(projected.effortsForModel('model'), ['actual']);
      expect(projected.model('model')!.defaultEffort, 'actual');
      expect(projected.validate(const ExecutionSelection()), contains('stale'));
    }
  });
  test(
      'revision pins remain bound to the selected Worker and deliberate choices',
      () {
    const catalog = ExecutionSelectionCatalog([
      WorkerSelectionCapability(
          id: 'worker',
          name: 'Worker',
          catalogRevision: 'current',
          models: [ExecutionModelCapability(id: 'model', name: 'Model')])
    ]);
    expect(
        catalog
            .changeModel(
                const ExecutionSelection(
                    worker: 'worker', catalogRevision: 'old'),
                'model')
            .catalogRevision,
        'current');
    expect(
        catalog.worker('worker')!.validate(
            const ExecutionSelection(model: 'model', catalogRevision: 'old')),
        contains('catalog changed'));
    expect(
        catalog.worker('worker')!.validatePreference(
            const ExecutionSelection(model: 'model', catalogRevision: 'old')),
        isNull);
    expect(
        catalog.worker('worker')!.validatePreference(
            const ExecutionSelection(model: 'removed', catalogRevision: 'old')),
        contains('not supported'));
    const base =
        ExecutionSelection(worker: 'one', catalogRevision: 'one-revision');
    expect(
        base.overlay(const ExecutionSelection(worker: 'two')).catalogRevision,
        isNull);
    expect(
        base
            .overlay(const ExecutionSelection(model: 'changed'))
            .catalogRevision,
        'one-revision');
  });
}
