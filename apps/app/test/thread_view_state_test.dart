import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/sync/persistence/ax_thread_view_state.dart';
import 'package:syntila_app/src/ax/sync/persistence/ax_thread_view_state_store.dart';
import 'package:syntila_app/src/ax/sync/persistence/ax_thread_view_state_store_kv.dart';

void main() {
  storeTests();
  test('only device-local state is persisted; the selection is Cloud-owned',
      () {
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
      chatResumeId: 'm5',
      workResumeId: 'r2|response',
      pane: AxThreadViewState.notesPane,
    );
    final restored = AxThreadViewState.decode(state.encode())!;
    expect(restored.tabIndex, 1);
    expect(restored.chatDraft, 'chat draft');
    expect(restored.workDraft, 'work draft');
    expect(restored.pane, AxThreadViewState.notesPane);
    expect(restored.chatResumeId, 'm5');
    expect(restored.workResumeId, 'r2|response');
    expect([
      restored.workerId,
      restored.workerTypeId,
      restored.model,
      restored.reasoningEffort,
      restored.catalogRevision,
    ], everyElement(isNull));
    for (final key in [
      'workerId',
      'workerTypeId',
      'model',
      'reasoningEffort'
    ]) {
      expect(state.toJson().keys, isNot(contains(key)));
    }
    expect(state.toJson().keys, isNot(contains('threadId')));
    // A pane this build does not know is ignored.
    expect(AxThreadViewState.fromJson({'pane': 'other'}).pane, isNull);
  });

  test('memory thread view state is isolated by user and thread', () async {
    final store = MemoryAxThreadViewStateStore();
    const state = AxThreadViewState(workDraft: 'local only');
    await store.save(userId: 'u1', threadId: 't1', state: state);
    expect(await store.load(userId: 'u1', threadId: 't1'), state);
    expect(await store.load(userId: 'u2', threadId: 't1'), isNull);
    expect(await store.load(userId: 'u1', threadId: 't2'), isNull);
    await store.save(userId: 'u1', threadId: 't2', state: state);
    await store.remove(userId: 'u1', threadId: 't1');
    expect(await store.load(userId: 'u1', threadId: 't1'), isNull);
    expect(await store.load(userId: 'u1', threadId: 't2'), state);
    await store.clearUser('u1');
    expect(await store.load(userId: 'u1', threadId: 't2'), isNull);
  });

  test('restore takes the selection from Cloud and the rest from the device',
      () {
    const local = AxThreadViewState(
      tabIndex: 1,
      workDraft: 'ask ai',
      chatSeenId: 'm9',
      pane: AxThreadViewState.aiHistoryPane,
      workflowSelections: {
        'chat': {'workerId': 'w1', 'model': 'm1'},
      },
    );
    final state = AxThreadViewState.restore(local, {
      'tabIndex': 0, // Left by an older build; never read.
      'workflowReference': 'direct:2',
      'workerId': 'w',
      'model': 'cloud-model',
    })!;
    expect(state.model, 'cloud-model');
    expect(state.workerId, 'w');
    expect(state.workflowReference, 'direct:2');
    // The tab is the composer mode and stays with the local draft.
    expect(state.tabIndex, 1);
    expect(state.workDraft, 'ask ai');
    expect(state.chatSeenId, 'm9');
    expect(state.pane, AxThreadViewState.aiHistoryPane);
    expect(state.workflowSelections, local.workflowSelections);
    // Another browser has no local copy: defaults for the local part.
    final fresh = AxThreadViewState.restore(null, {'model': 'm'})!;
    expect(fresh.tabIndex, 0);
    expect(fresh.model, 'm');
    expect(fresh.workDraft, isEmpty);
  });

  test('step choices and researcher count follow the Workflow', () {
    const local = AxThreadViewState(
      workflowReference: 'research:v2',
      stepSelections: {
        'research-1': {'workerId': 'worker-a', 'model': 'm1'},
        'synthesis': {'workerId': 'worker-b'},
      },
      researcherCount: 3,
    );
    final restored = AxThreadViewState.decode(local.encode())!;
    expect(restored.stepSelections, local.stepSelections);
    expect(restored.researcherCount, 3);
    final same =
        AxThreadViewState.restore(local, {'workflowReference': 'research:v2'})!;
    expect(same.stepSelections, local.stepSelections);
    expect(same.researcherCount, 3);
    for (final remote in [
      {'workflowReference': 'chat:v1'},
      <String, dynamic>{},
    ]) {
      final other = AxThreadViewState.restore(local, remote)!;
      expect(other.stepSelections, isEmpty);
      expect(other.researcherCount, isNull);
    }
  });
}

class _FakeStorage implements AxKeyValueStorage {
  final values = <String, String>{};
  var full = false;

  @override
  String? get(String key) => values[key];

  @override
  void set(String key, String value) {
    if (full) throw StateError('quota');
    values[key] = value;
  }

  @override
  void remove(String key) => values.remove(key);

  @override
  List<String> keys() => values.keys.toList();
}

void storeTests() {
  group('browser store parts', () {
    late _FakeStorage storage;
    setUp(() => storage = _FakeStorage());
    KeyValueAxThreadViewStateStore tab() =>
        KeyValueAxThreadViewStateStore(storage);

    test('saves and restores a Thread view', () async {
      final store = tab();
      await store.save(
          userId: 'u',
          threadId: 't',
          state: const AxThreadViewState(
              tabIndex: 1,
              chatDraft: 'c',
              workDraft: 'w',
              pane: AxThreadViewState.notesPane));
      final restored = tab().loadSync(userId: 'u', threadId: 't')!;
      expect(restored.tabIndex, 1);
      expect(restored.chatDraft, 'c');
      expect(restored.workDraft, 'w');
      expect(restored.pane, AxThreadViewState.notesPane);
    });

    test('a tab saving an unrelated change keeps another tab\'s draft',
        () async {
      final a = tab()..loadSync(userId: 'u', threadId: 't');
      final b = tab()..loadSync(userId: 'u', threadId: 't');
      await b.save(
          userId: 'u',
          threadId: 't',
          state: const AxThreadViewState(workDraft: 'typed in B'));
      // Tab A never touched the draft; its marker change must not erase it.
      await a.save(
          userId: 'u',
          threadId: 't',
          state: const AxThreadViewState(chatSeenId: 'm1'));
      final restored = tab().loadSync(userId: 'u', threadId: 't')!;
      expect(restored.workDraft, 'typed in B');
      expect(restored.chatSeenId, 'm1');
    });

    test('clearing a draft removes it', () async {
      final store = tab();
      await store.save(
          userId: 'u',
          threadId: 't',
          state: const AxThreadViewState(workDraft: 'x'));
      await store.save(
          userId: 'u', threadId: 't', state: const AxThreadViewState());
      expect(tab().loadSync(userId: 'u', threadId: 't')!.workDraft, isEmpty);
      expect(storage.values.keys.where((k) => k.endsWith('#work')), isEmpty);
    });

    test('a refused write is kept for the next load in this page', () async {
      final store = tab();
      await store.save(
          userId: 'u',
          threadId: 't',
          state: const AxThreadViewState(workDraft: 'old'));
      storage.full = true;
      await store.save(
          userId: 'u',
          threadId: 't',
          state: const AxThreadViewState(workDraft: 'new'));
      expect(store.loadSync(userId: 'u', threadId: 't')!.workDraft, 'new');
      // Nothing newer reached storage, and a fresh page sees the old copy.
      expect(tab().loadSync(userId: 'u', threadId: 't')!.workDraft, 'old');
    });

    test('keeps only the most recently saved Threads per user', () async {
      final store = KeyValueAxThreadViewStateStore(storage, maxThreads: 3);
      Future<void> save(String user, String thread) => store.save(
          userId: user,
          threadId: thread,
          state: AxThreadViewState(workDraft: 'draft $thread'));
      for (final thread in ['t1', 't2', 't3']) {
        await save('u', thread);
      }
      await save('other', 'x');
      await save('u', 't1'); // Reused, so t2 is now the oldest.
      await save('u', 't4');
      final reader = KeyValueAxThreadViewStateStore(storage, maxThreads: 3);
      expect(reader.loadSync(userId: 'u', threadId: 't2'), isNull);
      for (final thread in ['t1', 't3', 't4']) {
        expect(reader.loadSync(userId: 'u', threadId: thread)!.workDraft,
            'draft $thread');
      }
      // Another user's Threads do not count against this one's cap.
      expect(reader.loadSync(userId: 'other', threadId: 'x'), isNotNull);
      // A removed Thread leaves the list, so it frees its place.
      await store.remove(userId: 'u', threadId: 't3');
      await save('u', 't5');
      expect(reader.loadSync(userId: 'u', threadId: 't1'), isNotNull);
    });

    test('remove and clearUser drop parts and legacy blobs', () async {
      storage.values['syntila-thread-view-v1:u:old'] = '{"workDraft":"big"}';
      final store = tab();
      await store.save(
          userId: 'u',
          threadId: 't1',
          state: const AxThreadViewState(workDraft: 'a'));
      await store.save(
          userId: 'u',
          threadId: 't2',
          state: const AxThreadViewState(workDraft: 'b'));
      // The first save already dropped the single-blob entry.
      expect(storage.values.keys.any((k) => k.contains('-v1:')), isFalse);
      await store.remove(userId: 'u', threadId: 't1');
      expect(tab().loadSync(userId: 'u', threadId: 't1'), isNull);
      expect(tab().loadSync(userId: 'u', threadId: 't2'), isNotNull);
      await store.clearUser('u');
      expect(storage.values, isEmpty);
    });
  });
}
