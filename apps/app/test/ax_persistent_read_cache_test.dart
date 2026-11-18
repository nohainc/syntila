import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/ax_stores.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/ax/sync/ax_discussion_cache.dart';
import 'package:syntila_app/src/ax/sync/ax_work_history.dart';
import 'package:syntila_app/src/ax/sync/persistence/ax_persistent_read_cache.dart';
import 'ax_fixture_data.dart';
import 'conversation_turn_fixture.dart';

AxStore store(MemoryAxReadCacheBackend backend, {String user = 'A'}) {
  final value = AxStore(const AxFixtureDataSource(), readCacheBackend: backend);
  value.auth.session = AxSession(
      authenticated: true,
      viewer: AxViewer(id: user, displayName: user, email: 'private@test'));
  return value;
}

const space = AxSpace(
    id: 'P',
    name: 'Cached Space',
    branch: 'main',
    lastActivity: 'now',
    settings: {
      'token': 'SECRET',
      'providerCredentials': {'apiKey': 'SECRET'},
      'threadOrder': ['W']
    });
AxWorkRequest request(String id) => AxWorkRequest(
    id: id,
    requestedByName: 'Human',
    prompt: 'Work',
    workflowId: 'direct',
    workflowVersion: 2,
    status: 'completed',
    createdAt: '2026-10-06T00:00:00Z',
    steps: const []);

class SessionSource extends AxFixtureDataSource {
  final pending = Completer<AxSession>();
  @override
  Future<AxSession> loadSession() => pending.future;
}

class _FailureSource extends AxFixtureDataSource {
  _FailureSource(this.row);
  final AxWorkRequest row;
  @override
  Future<List<AxWorkRequest>> workRequestRows(
          {required String threadId, bool activeOnly = false}) async =>
      [row];
}

class BrokenBackend implements AxReadCacheBackend {
  @override
  Future<AxReadCacheSnapshot> read(String userId) async =>
      throw StateError('storage blocked');
  @override
  Future<bool> write(String userId, int revision,
          List<Map<String, dynamic>> records) async =>
      throw StateError('quota');
  @override
  Future<void> clear(String userId) async => throw StateError('blocked');
  @override
  void close() {}
}

class DelayedBackend extends MemoryAxReadCacheBackend {
  Completer<AxReadCacheSnapshot>? pending;
  @override
  Future<AxReadCacheSnapshot> read(String userId) =>
      pending?.future ?? super.read(userId);
}

void main() {
  test('provider failure text stays out of cache and reloads from Cloud',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final row = AxWorkRequest.fromJson({
      'id': 'R',
      'requestedByName': 'User',
      'prompt': 'Work',
      'workflowId': 'direct',
      'workflowVersion': 2,
      'status': 'failed',
      'createdAt': '2026-10-06T00:00:00Z',
      'steps': [
        {
          'kind': 'implement',
          'status': 'failed',
          'workerId': 'worker-a',
          'providerFailure': {
            'schemaVersion': 1,
            'source': 'stderr',
            'providerErrorText': 'private provider error',
            'failedRunResponse': 'private response'
          },
        }
      ],
    });
    final first = store(backend);
    await first.hydrateReadCache();
    first.syncEngine.update(first.workHistory.query('W'),
        (_) => AxWorkHistory(requests: [row], initialLoaded: true));
    await first.persistence.flush();
    final saved = jsonEncode((await backend.read('A')).records);
    expect(saved, isNot(contains('private provider error')));
    expect(saved, isNot(contains('private response')));
    first.dispose();

    final second = AxStore(_FailureSource(row), readCacheBackend: backend);
    second.auth.session = const AxSession(
        authenticated: true,
        viewer: AxViewer(id: 'A', displayName: 'A', email: 'private@test'));
    await second.hydrateReadCache();
    expect(
        second.workHistory
            .peek('W')
            .requests
            .single
            .steps
            .single
            .providerFailure,
        isNull);
    await second.workHistory.refresh('W');
    expect(
        second.workHistory
            .peek('W')
            .requests
            .single
            .steps
            .single
            .providerFailure
            ?.providerErrorText,
        'private provider error');
    second.dispose();
  });
  test('per-turn attribution survives authenticated history persistence',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final first = store(backend);
    await first.hydrateReadCache();
    final turn = AxConversationTurn.fromJson({
      ...turnFixture().toJson(),
      'modelName': 'Original Family',
      'catalogRevision': 'a' * 64
    });
    final row = AxWorkRequest.fromJson({
      'id': 'R',
      'attachments': [
        {
          'kind': 'file',
          'name': 'photo.jpg',
          'sizeBytes': 2048,
          'contentBase64': 'DO_NOT_CACHE',
          'fileId': 'private-storage-id'
        }
      ],
      'workflowRun': {
        'schemaVersion': 1,
        'id': 'workflow-run-R',
        'conversationId': 'conversation-C',
        'userMessageId': 'message-user-R',
        'workRequestId': 'R',
        'workflowId': 'direct',
        'workflowVersion': 2,
        'status': 'running',
        'triggerMessageId': 'message-user-R',
        'startedAt': 'first-start',
        'completedAt': null,
        'stepRuns': [
          {
            'schemaVersion': 1,
            'id': 'step-run-task-R',
            'workflowRunId': 'workflow-run-R',
            'taskId': 'task-R',
            'stepId': 'implement',
            'role': 'implement',
            'workerId': 'worker-a',
            'modelId': 'model-x',
            'effort': 'medium',
            'workerSessionId': 'worker-session-opaque',
            'baseContextRevision': 0,
            'status': 'completed',
            'result': '**Recorded answer**',
            'startedAt': 'first-start',
            'completedAt': 'completed',
            'workerTurnIds': [turn.id]
          }
        ],
        'runtimeRunIds': ['runtime-1', 'runtime-2'],
        'workerTurnIds': [turn.id],
        'createdAt': 'now',
        'updatedAt': 'now'
      },
      'steps': [
        {
          'kind': 'direct',
          'status': 'completed',
          'workerId': 'worker-a',
          'model': 'model-x',
          'modelName': 'Original Family',
          'reasoningEffort': 'medium',
          'catalogRevision': 'a' * 64
        }
      ],
      'turns': [turn.toJson()]
    });
    first.syncEngine.update(first.workHistory.query('W'),
        (_) => AxWorkHistory(requests: [row], initialLoaded: true));
    await first.persistence.flush();
    final second = store(backend);
    await second.hydrateReadCache();
    expect(second.workHistory.peek('W').requests.single.attachments.single.name,
        'photo.jpg');
    expect(
        row.copyWith(status: 'completed').attachments.single.sizeBytes, 2048);
    expect(
        row.attachments.single.toJson().containsKey('contentBase64'), isFalse);
    expect(second.workHistory.peek('W').requests.single.turns.single.toJson(),
        turn.toJson());
    expect(
        row.copyWith(status: 'completed').turns.single.toJson(), turn.toJson());
    expect(second.workHistory.peek('W').requests.single.workflowRun!.toJson(),
        row.workflowRun!.toJson());
    expect(row.copyWith(status: 'completed').workflowRun!.id, 'workflow-run-R');
    final restoredStep =
        second.workHistory.peek('W').requests.single.steps.single;
    expect(restoredStep.modelName, 'Original Family');
    expect(restoredStep.reasoningEffort, 'medium');
    expect(restoredStep.catalogRevision, 'a' * 64);
    final restoredRun =
        second.workHistory.peek('W').requests.single.workflowRun!;
    expect(restoredRun.stepRuns.single.result, '**Recorded answer**');
    expect(restoredRun.triggerMessageId, 'message-user-R');
    expect(restoredRun.startedAt, 'first-start');
    expect(restoredRun.stepRuns.single.id, turn.workflowStepRunId);
    first.dispose();
    second.dispose();
  });

  test('workflow control policy survives authenticated read-cache hydration',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final first = store(backend);
    await first.hydrateReadCache();
    first.syncEngine.update(
        first.catalogs.workflows,
        (_) => [
              AxBuiltinWorkflow.fromJson({
                'id': 'future',
                'version': 1,
                'steps': [],
                'name': 'Future',
                'executionPolicy': {
                  'userSelectsModel': true,
                  'userSelectsEffort': false,
                  'multiStep': true,
                  'multiWorker': true,
                  'requiresApprovalBetweenSteps': true
                },
                'composerBindingId': 'future-binding',
              })
            ]);
    await first.persistence.flush();
    final second = store(backend);
    await second.hydrateReadCache();
    final restored =
        second.syncEngine.peek(second.catalogs.workflows).data!.single;
    expect(restored.executionPolicy.userSelectsModel, isTrue);
    expect(restored.executionPolicy.userSelectsEffort, isFalse);
    expect(restored.executionPolicy.multiStep, isTrue);
    expect(restored.executionPolicy.multiWorker, isTrue);
    expect(restored.executionPolicy.requiresApprovalBetweenSteps, isTrue);
    expect(restored.composerBindingId, 'future-binding');
    first.dispose();
    second.dispose();
  });
  test('late authentication cannot reactivate persistence after logout',
      () async {
    final source = SessionSource();
    final value = AxStore(source, readCacheBackend: MemoryAxReadCacheBackend());
    final loading = value.auth.load();
    await value.logout();
    source.pending.complete(const AxSession(
        authenticated: true,
        viewer: AxViewer(id: 'A', displayName: 'A', email: '')));
    await expectLater(loading, throwsStateError);
    expect(value.auth.session!.authenticated, isFalse);
    expect(await value.hydrateReadCache(), isFalse);
    value.dispose();
  });
  test('only the 20 most recently used persisted Thread histories are retained',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final value = store(backend);
    await value.hydrateReadCache();
    for (var i = 0; i < 25; i++) {
      final query = value.workHistory.query('W$i');
      value.syncEngine.update(
          query,
          (_) =>
              AxWorkHistory(requests: [request('R$i')], initialLoaded: true));
      value.syncEngine.peek(query);
    }
    await value.persistence.flush();
    final records = (await backend.read('A')).records;
    expect(records, hasLength(20));
    expect(records.any((r) => (r['key'] as List)[1] == 'W0'), isFalse);
    expect(records.any((r) => (r['key'] as List)[1] == 'W24'), isTrue);
    value.dispose();
  });

  test(
      'persistent histories are bounded and restore valid pagination frontiers',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final first = store(backend);
    await first.hydrateReadCache();
    final messages = List.generate(
        120,
        (i) => AxDiscussionMessage(
            id: 'D${i.toString().padLeft(3, '0')}',
            threadId: 'W',
            authorUserId: 'A',
            body: 'Message $i',
            createdAt: 'now'));
    first.syncEngine.update(
        first.discussion.query('W'),
        (_) => AxDiscussionHistory(
            messages: messages,
            initialLoaded: true,
            olderCursor: 'older-opaque',
            newestCursor: 'newest-opaque',
            deletedMessageIds: const ['D070']));
    first.syncEngine.update(
        first.workHistory.query('W'),
        (_) => AxWorkHistory(
            requests: List.generate(120, (i) => request('R$i')),
            initialLoaded: true));
    await first.persistence.flush();
    final second = store(backend);
    await second.hydrateReadCache();
    expect(second.discussion.peek('W').messages, hasLength(50));
    expect(second.discussion.peek('W').messages.first.id, 'D069');
    expect(second.discussion.peek('W').messages.any((m) => m.id == 'D070'),
        isFalse);
    expect(second.discussion.peek('W').olderCursor, isNull);
    expect(second.workHistory.peek('W').requests, hasLength(50));
    expect(second.workHistory.peek('W').olderCursor!.id, 'R70');
    first.dispose();
    second.dispose();
  });
  test('five callers see hydrated state and share one background request',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final first = store(backend);
    await first.hydrateReadCache();
    first.spaces.replace([space]);
    await first.persistence.flush();
    final second = store(backend);
    await second.hydrateReadCache();
    var reads = 0;
    final pending = Completer<List<AxSpace>>();
    final query = AxQuery<List<AxSpace>>(
        key: second.spaces.query.key,
        load: () {
          reads++;
          return pending.future;
        });
    final values = await Future.wait(
        List.generate(5, (_) => second.syncEngine.ensure(query)));
    expect(values.every((v) => v.single.name == 'Cached Space'), isTrue);
    expect(reads, 1);
    pending.complete([space.copyWith(name: 'Revalidated')]);
    await Future<void>.delayed(Duration.zero);
    expect(second.spaces.items.single.name, 'Revalidated');
    first.dispose();
    second.dispose();
  });

  test(
      'hydrates only the authenticated user and renders safe collections without a Cloud read',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final first = store(backend);
    await first.hydrateReadCache();
    first.spaces.replace([space]);
    first.workspaces.replace([const AxWorkspace(id: 'X', name: 'Workspace')]);
    first.syncEngine.update(
        first.spaceThreads.query('P'),
        (_) => [
              AxThread.fromJson({'id': 'W', 'spaceId': 'P', 'name': 'Stream'})
            ]);
    first.syncEngine.update(
        first.discussion.query('W'),
        (_) => AxDiscussionHistory(initialLoaded: true, messages: const [
              AxDiscussionMessage(
                  id: 'D',
                  threadId: 'W',
                  authorUserId: 'A',
                  body: 'Hello',
                  createdAt: 'now')
            ]));
    first.syncEngine.update(
        first.workHistory.query('W'),
        (_) => AxWorkHistory(
            initialLoaded: true,
            requests: [request('R')],
            confirmedIds: const ['R']));
    await first.persistence.flush();
    final text = jsonEncode((await backend.read('A')).records);
    expect(text, contains('Cached Space'));
    expect(text, isNot(contains('SECRET')));
    expect(text, isNot(contains('private@test')));
    final other = store(backend, user: 'B');
    expect(await other.hydrateReadCache(), isFalse);
    expect(other.spaces.items, isEmpty);
    final reopened = store(backend);
    expect(await reopened.hydrateReadCache(), isTrue);
    expect(reopened.spaces.items.single.name, 'Cached Space');
    expect(reopened.workspaces.items.single.name, 'Workspace');
    expect(reopened.discussion.peek('W').messages.single.isMe, isTrue);
    expect(reopened.workHistory.peek('W').requests.single.id, 'R');
    expect(reopened.syncEngine.peek(reopened.spaces.query).isStale, isTrue);
    first.dispose();
    other.dispose();
    reopened.dispose();
  });
  test(
      'never persists pending mutation overlays, local Work, security or unknown query keys',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final value = store(backend);
    await value.hydrateReadCache();
    value.spaces.replace([space]);
    final overlay = value.syncEngine.optimisticUpdate(
        value.spaces.query, (_) => [space.copyWith(name: 'Pending name')]);
    value.syncEngine.update(
        AxQuery<String>(
            key: AxQueryKey(['security']), load: () async => 'SECRET'),
        (_) => 'SECRET');
    value.syncEngine.update(
        value.workHistory.query('W'),
        (_) =>
            AxWorkHistory(requests: [request('local-pending'), request('R')]));
    await value.persistence.flush();
    final text = jsonEncode((await backend.read('A')).records);
    expect(text, isNot(contains('Pending name')));
    expect(text, isNot(contains('SECRET')));
    expect(text, isNot(contains('local-pending')));
    expect(text, contains('Cached Space'));
    overlay.rollback();
    value.dispose();
  });
  test('hydration does not overwrite newer data or in-flight reads', () async {
    final backend = MemoryAxReadCacheBackend();
    final first = store(backend);
    await first.hydrateReadCache();
    first.spaces.replace([space]);
    await first.persistence.flush();
    final second = store(backend);
    second.spaces.replace([space.copyWith(name: 'New')]);
    await second.hydrateReadCache();
    expect(second.spaces.items.single.name, 'New');
    final engine = AxSyncEngine();
    final pending = Completer<List<AxSpace>>();
    final query = AxQuery<List<AxSpace>>(
        key: AxQueryKey(['spaces']), load: () => pending.future);
    final read = engine.refresh(query);
    final cache = AxPersistentReadCache(engine, const AxFixtureDataSource(),
        backend: backend);
    expect(await cache.hydrate('A'), isFalse);
    expect(engine.peek(query).hasData, isFalse);
    pending.complete([space.copyWith(name: 'Network')]);
    await read;
    expect(engine.peek(query).data!.single.name, 'Network');
    cache.dispose();
    first.dispose();
    second.dispose();
  });
  test(
      'logout clears memory and only that user disk data, rejects old tab writes',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final a = store(backend);
    final b = store(backend, user: 'B');
    await a.hydrateReadCache();
    await b.hydrateReadCache();
    a.spaces.replace([space]);
    b.spaces.replace([space.copyWith(name: 'B')]);
    await a.persistence.flush();
    await b.persistence.flush();
    final stale = await backend.read('A');
    await a.logout();
    expect(a.spaces.items, isEmpty);
    expect(a.workHistory.peek('W').requests, isEmpty);
    expect((await backend.read('A')).records, isEmpty);
    expect((await backend.read('B')).records, isNotEmpty);
    expect(await backend.write('A', stale.revision, stale.records), isFalse);
    a.dispose();
    b.dispose();
  });
  test('late hydration after logout cannot restore private history', () async {
    final backend = DelayedBackend();
    final first = store(backend);
    await first.hydrateReadCache();
    first.spaces.replace([space]);
    await first.persistence.flush();
    final snapshot = await backend.read('A');
    backend.pending = Completer();
    final late = store(backend);
    final hydration = late.hydrateReadCache();
    await Future<void>.delayed(Duration.zero);
    late.clearServerState();
    backend.pending!.complete(snapshot);
    expect(await hydration, isFalse);
    expect(late.spaces.items, isEmpty);
    await late.persistence.flush();
    expect((await backend.read('A')).records,
        isNotEmpty); // delayed test read returns the captured snapshot
    backend.pending = null;
    expect((await backend.read('A')).records, isEmpty);
    first.dispose();
    late.dispose();
  });
  test(
      'storage unavailable or explicitly disabled leaves ordinary memory caching intact',
      () async {
    for (final enabled in [true, false]) {
      final value = AxStore(const AxFixtureDataSource(),
          readCacheBackend: BrokenBackend(), persistReadCache: enabled);
      value.auth.session = const AxSession(
          authenticated: true,
          viewer: AxViewer(id: 'A', displayName: 'A', email: ''));
      expect(await value.hydrateReadCache(), isFalse);
      value.spaces.replace([space]);
      await value.persistence.flush();
      expect(value.spaces.items.single.name, 'Cached Space');
      await value.logout();
      expect(value.spaces.items, isEmpty);
      value.dispose();
    }
  });
  test('corrupt records and unsupported versions are discarded individually',
      () async {
    final backend = MemoryAxReadCacheBackend();
    await backend.write('A', 0, [
      {
        'version': 999,
        'key': ['spaces'],
        'data': []
      },
      {
        'version': 1,
        'key': ['spaces'],
        'data': 'bad'
      }
    ]);
    final value = store(backend);
    expect(await value.hydrateReadCache(), isFalse);
    expect(value.spaces.items, isEmpty);
    value.dispose();
  });
  testWidgets(
      'hydrated Space renders while background read is pending and remains on failure',
      (tester) async {
    final backend = MemoryAxReadCacheBackend();
    final first = store(backend);
    await first.hydrateReadCache();
    first.spaces.replace([space]);
    await first.persistence.flush();
    final second = store(backend);
    await second.hydrateReadCache();
    await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<List<AxSpace>>(
            valueListenable: second.spaces,
            builder: (context, values, _) => Text(values.single.name))));
    expect(find.text('Cached Space'), findsOneWidget);
    final pending = Completer<List<AxSpace>>();
    final query = AxQuery<List<AxSpace>>(
        key: second.spaces.query.key, load: () => pending.future);
    await second.syncEngine.ensure(query);
    await tester.pump();
    expect(find.text('Cached Space'), findsOneWidget);
    pending.completeError(StateError('offline'));
    await tester.pump();
    expect(find.text('Cached Space'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    first.dispose();
    second.dispose();
  });
}
