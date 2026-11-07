import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/sync/persistence/ax_thread_view_state.dart';
import 'package:syntila_app/src/ax/sync/persistence/ax_thread_view_state_store.dart';

void main() {
  test('thread view state round trips locally without cloud fields', () {
    const state = AxThreadViewState(
      tabIndex: 1,
      workflowReference: 'direct:v2',
      workerId: 'worker-a',
      workerTypeId: 'claude',
      model: 'model-a',
      reasoningEffort: 'high',
      catalogRevision: 'reviewed',
      chatDraft: 'chat draft',
      workDraft: 'work draft',
      pane: AxThreadViewState.notesPane,
    );
    final restored = AxThreadViewState.decode(state.encode());
    expect(restored?.toJson(), state.toJson());
    expect(
        state.toJson().keys,
        containsAll([
          'tabIndex',
          'workflowReference',
          'workerId',
          'workerTypeId',
          'model',
          'reasoningEffort',
          'catalogRevision',
          'chatDraft',
          'workDraft',
        ]));
    expect(state.toJson().keys, isNot(contains('threadId')));
  });

  test('memory thread view state is isolated by user and thread', () async {
    final store = MemoryAxThreadViewStateStore();
    const state = AxThreadViewState(workDraft: 'local only');
    await store.save(userId: 'u1', threadId: 't1', state: state);
    expect(await store.load(userId: 'u1', threadId: 't1'), state);
    expect(await store.load(userId: 'u2', threadId: 't1'), isNull);
    expect(await store.load(userId: 'u1', threadId: 't2'), isNull);
    await store.clearUser('u1');
    expect(await store.load(userId: 'u1', threadId: 't1'), isNull);
  });

  test('unknown saved pane is ignored', () {
    expect(AxThreadViewState.fromJson({'pane': 'other'}).pane, isNull);
    expect(
        AxThreadViewState.withRemote(
                const AxThreadViewState(pane: AxThreadViewState.aiHistoryPane),
                {'model': 'cloud'})!
            .pane,
        AxThreadViewState.aiHistoryPane);
  });

  test('Cloud tab never hides the mode holding a local draft', () {
    final state = AxThreadViewState.withRemote(
        const AxThreadViewState(tabIndex: 1, workDraft: 'ask ai'), {
      'tabIndex': 0,
      'model': 'cloud',
      'selectionUpdatedAt': '2026-10-21T20:00:09.000Z',
    })!;
    expect(state.tabIndex, 1);
    expect(state.workDraft, 'ask ai');
    // Without a local copy (another browser) the Cloud tab still applies.
    expect(
        AxThreadViewState.withRemote(null, {'tabIndex': 1, 'model': 'm'})!
            .tabIndex,
        1);
  });

  group('withRemote', () {
    const local = AxThreadViewState(
      workflowReference: 'direct:2',
      workerId: 'w',
      model: 'local-model',
      selectionUpdatedAt: '2026-10-21T20:00:05.000Z',
      workDraft: 'draft',
    );

    test('Cloud selection wins when it is newer', () {
      final state = AxThreadViewState.withRemote(local, {
        'workflowReference': 'direct:2',
        'model': 'cloud-model',
        'selectionUpdatedAt': '2026-10-21T20:00:09.000Z',
      })!;
      expect(state.model, 'cloud-model');
      expect(state.workDraft, 'draft');
    });

    test('newer local selection beats a stale Cloud copy', () {
      for (final remote in [
        {'model': 'stale', 'selectionUpdatedAt': '2026-10-21T20:00:00.000Z'},
        // Written before selections were timestamped.
        {'model': 'stale'},
      ]) {
        expect(
            AxThreadViewState.withRemote(local, remote)!.model, 'local-model');
      }
    });

    test('untimestamped local copy keeps the Cloud selection', () {
      const legacy = AxThreadViewState(model: 'local-model');
      expect(AxThreadViewState.withRemote(legacy, {'model': 'cloud'})!.model,
          'cloud');
    });
  });
}
