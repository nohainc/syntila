import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/sync/persistence/ax_thread_view_state.dart';
import 'package:syntila_app/src/features/spaces/thread_selection_restore.dart';

AxBuiltinWorkflow _workflow(String id, int version) => AxBuiltinWorkflow(
    id: id,
    version: version,
    name: id,
    description: '',
    steps: const [],
    snapshot: const {});

AxWorker _worker(String id, String type,
        {bool ready = true, String? revision}) =>
    AxWorker(
      id: id,
      displayName: id,
      workerTypeId: type,
      status: ready ? 'ready' : 'offline',
      readinessState: ready ? 'ready' : 'offline',
      localConcurrencyLimit: 1,
      executionOptions: revision == null
          ? null
          : AxWorkerExecutionOptions(
              modelSelectionSupported: true,
              modelDiscovery: 'profile_catalog',
              allowsCustomModel: true,
              allowedModelIds: const [],
              modelSwitchSupported: true,
              effort: const AxWorkerEffortOptions(supported: false, values: []),
              models: const [],
              catalogRevision: revision),
    );

RestoredThreadSelection? _restore(
  AxThreadViewState saved, {
  List<AxBuiltinWorkflow>? workflows,
  List<AxWorker> workers = const [],
  bool settled = true,
  bool awaitingInitial = false,
  bool loading = false,
}) {
  final available = workflows ?? [_workflow('chat', 1), _workflow('direct', 2)];
  return restoreThreadSelection(saved,
      workflows: available,
      currentWorkflows: available,
      workers: workers,
      workersSettled: settled,
      awaitingInitialWorkers: awaitingInitial,
      loadingWorkflows: loading);
}

void main() {
  test('keeps the saved Workflow, Worker, model and effort', () {
    final restored = _restore(
        const AxThreadViewState(
            workflowReference: 'direct:v2',
            workerId: 'w1',
            model: 'm',
            reasoningEffort: 'high'),
        workers: [_worker('w1', 'claude')])!;
    expect(restored.workflowReference, 'direct:v2');
    expect(restored.selection,
        {'workerId': 'w1', 'model': 'm', 'reasoningEffort': 'high'});
  });

  test('a Workflow version bump keeps the choice at the current version', () {
    final restored = restoreThreadSelection(
      const AxThreadViewState(workflowReference: 'direct:v1'),
      workflows: [_workflow('direct', 2)],
      currentWorkflows: [_workflow('direct', 2)],
      workers: const [],
      workersSettled: true,
      awaitingInitialWorkers: false,
      loadingWorkflows: false,
    )!;
    expect(restored.workflowReference, 'direct:v2');
  });

  test('a vanished Workflow falls back to the default but keeps the Worker',
      () {
    final restored = _restore(
        const AxThreadViewState(workflowReference: 'gone:v1', workerId: 'w1'),
        workers: [_worker('w1', 'claude')])!;
    expect(restored.workflowReference, isNull);
    expect(restored.selection['workerId'], 'w1');
  });

  group('re-binding a Worker whose ID is gone', () {
    const saved = AxThreadViewState(workerId: 'old', workerTypeId: 'claude');

    test('binds the only Worker of that type', () {
      expect(
          _restore(saved, workers: [_worker('new', 'claude')])!
              .selection['workerId'],
          'new');
    });

    test('prefers the single ready Worker among several', () {
      expect(
          _restore(saved, workers: [
            _worker('off', 'claude', ready: false),
            _worker('on', 'claude'),
          ])!
              .selection['workerId'],
          'on');
    });

    test('an ambiguous type keeps the saved ID instead of guessing', () {
      expect(
          _restore(saved, workers: [
            _worker('a', 'claude'),
            _worker('b', 'claude'),
          ])!
              .selection['workerId'],
          'old');
    });

    test('a Worker of another type is never substituted', () {
      expect(
          _restore(saved, workers: [_worker('x', 'codex')])!
              .selection['workerId'],
          'old');
    });
  });

  test('takes the catalog revision from the current Worker', () {
    final restored = _restore(
        const AxThreadViewState(workerId: 'w1', catalogRevision: 'stale'),
        workers: [_worker('w1', 'claude', revision: 'fresh')])!;
    expect(restored.selection['catalogRevision'], 'fresh');
  });

  test('step choices and researcher count come back as saved', () {
    final restored =
        _restore(const AxThreadViewState(researcherCount: 3, stepSelections: {
      'plan': {'workerId': 'w1'}
    }))!;
    expect(restored.selection['researcherCount'], 3);
    expect(restored.selection['steps'], {
      'plan': {'workerId': 'w1'}
    });
  });

  group('waits for what it depends on', () {
    const withWorker = AxThreadViewState(workerId: 'w1');

    test('an empty Workflow catalog', () {
      expect(_restore(withWorker, workflows: const []), isNull);
    });

    test('an unsettled Worker list, only when a Worker was saved', () {
      expect(_restore(withWorker, settled: false), isNull);
      expect(_restore(const AxThreadViewState(model: 'm'), settled: false),
          isNotNull);
    });

    test('the first Worker catalog', () {
      expect(_restore(withWorker, awaitingInitial: true), isNull);
    });

    test('a still-loading catalog before giving up on a Workflow', () {
      const missing = AxThreadViewState(workflowReference: 'gone:v1');
      expect(_restore(missing, loading: true), isNull);
      expect(_restore(missing), isNotNull);
    });
  });

  test('the Cloud payload carries only the selection, nulls included', () {
    const state = AxThreadViewState(
        tabIndex: 1, workflowReference: 'direct:v2', workDraft: 'x');
    expect(state.cloudSelection.keys.toSet(), {
      'workflowReference',
      'workerId',
      'workerTypeId',
      'model',
      'reasoningEffort',
      'catalogRevision',
    });
    expect(state.cloudSelection['model'], isNull);
  });
}
