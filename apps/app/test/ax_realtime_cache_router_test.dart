import 'dart:async';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/ax/sync/ax_realtime_cache_router.dart';

void main() {
  late AxSyncEngine engine;
  late AxRealtimeCacheRouter router;
  late Map<String, int> loads;
  AxQuery<int> query(List<String> parts) => AxQuery(
      key: AxQueryKey(parts),
      load: () async {
        final name = parts.join(':');
        return loads.update(name, (n) => n + 1, ifAbsent: () => 1);
      });
  setUp(() {
    engine = AxSyncEngine();
    router = AxRealtimeCacheRouter(engine);
    loads = {};
  });
  test('Space updates leave People alone; people.updated reloads People',
      () async {
    final people = query(['people']);
    await engine.ensure(people);
    await router.handle({'type': 'space.updated', 'spaceId': 'A'});
    expect(loads['people'], 1);
    await router.handle({'type': 'people.updated'});
    expect(loads['people'], 2);
  });
  test('thread.read refreshes read receipts only, not the Thread list',
      () async {
    final receipts = query(['thread', 'W', 'read-states']);
    final threads = query(['space', 'A', 'threads']);
    await engine.ensure(receipts);
    await engine.ensure(threads);
    await router.handle({
      'type': 'thread.read',
      'spaceId': 'A',
      'threadId': 'W',
      'payload': {'entityId': 'W', 'threadId': 'W'}
    });
    expect(loads['thread:W:read-states'], 2);
    expect(loads['space:A:threads'], 1);
  });
  test('Discussion without integration callback revalidates its query',
      () async {
    final discussion = query(['thread', 'W', 'discussion']);
    await engine.ensure(discussion);
    await router.handle({
      'type': 'discussion.updated',
      'threadId': 'W',
      'payload': {'entityId': 'message'}
    });
    expect(loads['thread:W:discussion'], 2);
  });
  test('terminal Work events synchronize the observed discussion', () async {
    final synchronized = <String>[];
    router = AxRealtimeCacheRouter(engine,
        discussionObserved: (id) => id == 'W',
        discussionResynchronize: (id) async => synchronized.add(id));
    for (final type in [
      'work_request.completed',
      'work_request.failed',
      'work_request.cancelled'
    ]) {
      await router.handle({'type': type, 'threadId': 'W'});
    }
    await router
        .handle({'type': 'work_request.completed', 'threadId': 'other'});
    expect(synchronized, ['W', 'W', 'W']);
    router.reset();
  });
  test('Work and Discussion bursts share one debounced indicator refresh',
      () async {
    final spaces = query(['spaces']);
    final threads = query(['space', 'A', 'threads']);
    await engine.ensure(spaces);
    await engine.ensure(threads);
    router = AxRealtimeCacheRouter(engine,
        activityDebounce: const Duration(milliseconds: 10));
    for (final type in [
      'work_request.started',
      'discussion.created',
      'work_request.completed'
    ]) {
      await router.handle({
        'type': type,
        'spaceId': 'A',
        'threadId': 'W',
        'payload': {'entityId': 'x', 'threadId': 'W'}
      });
    }
    expect(loads['spaces'], 1);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(loads['spaces'], 2);
    expect(loads['space:A:threads'], 2);
  });
  test('activity in the viewed Thread refreshes sidebar ordering', () async {
    final spaces = query(['spaces']);
    await engine.ensure(spaces);
    final viewed = <String>[];
    router = AxRealtimeCacheRouter(engine,
        activityDebounce: const Duration(milliseconds: 10),
        viewedThreadActivity: (id) {
      viewed.add(id);
      return id == 'W';
    });
    await router.handle({
      'type': 'work_request.completed',
      'spaceId': 'A',
      'threadId': 'W',
      'payload': {'threadId': 'W'}
    });
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(viewed, ['W']);
    expect(loads['spaces'], 2);
  });
  test('a newly accepted request refreshes ordering for a viewed Thread',
      () async {
    final spaces = AxQuery<List<AxSpace>>(
        key: AxQueryKey(['spaces']),
        load: () async {
          loads.update('spaces', (n) => n + 1, ifAbsent: () => 1);
          return const [];
        });
    final threads = AxQuery<List<AxThread>>(
        key: AxQueryKey(['space', 'A', 'threads']),
        load: () async {
          loads.update('space:A:threads', (n) => n + 1, ifAbsent: () => 1);
          return const [];
        });
    await engine.ensure(spaces);
    await engine.ensure(threads);
    router = AxRealtimeCacheRouter(engine,
        activityDebounce: const Duration(milliseconds: 10),
        viewedThreadActivity: (_) => true);
    await router.handle({
      'type': 'work_request.created',
      'spaceId': 'A',
      'threadId': 'W',
      'payload': {'threadId': 'W', 'workRequestId': 'request'}
    });
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(loads['spaces'], 2);
    expect(loads['space:A:threads'], 2);
  });
  test('background Space updates only its own registered queries', () async {
    final a = query(['space', 'A', 'threads']);
    final b = query(['space', 'B', 'threads']);
    await engine.ensure(a);
    await engine.ensure(b);
    var aChanges = 0;
    var bChanges = 0;
    engine.watch(a, (_) => aChanges++, fireImmediately: false);
    engine.watch(b, (_) => bChanges++, fireImmediately: false);
    await router
        .handle({'type': 'thread.updated', 'spaceId': 'A', 'threadId': 'W'});
    expect(engine.peek(a).data, 2);
    expect(engine.peek(b).data, 1);
    expect(aChanges, greaterThan(0));
    expect(bChanges, 0);
  });

  test(
      'Space configuration changes refresh only registered scope queries and reconnect recovers them',
      () async {
    final config = query(['space-workflow-configurations', 'A']);
    final defaults = query(['workflow-default', 'A']);
    final other = query(['workflow-default', 'B']);
    final global = query(['workflow-default', 'user']);
    for (final q in [config, defaults, other, global]) {
      await engine.ensure(q);
    }
    await router.handle({'type': 'space.updated', 'spaceId': 'A'});
    expect(engine.peek(config).data, 2);
    expect(engine.peek(defaults).data, 2);
    expect(engine.peek(other).data, 1);
    expect(engine.peek(global).data, 1);
    await router.handle({
      'type': 'sync.required',
      'scope': {'kind': 'space', 'spaceId': 'A'}
    });
    expect(engine.peek(config).data, 3);
    expect(engine.peek(defaults).data, 3);
    expect(engine.peek(other).data, 1);
  });

  test(
      'Space deletion clears both workflow query types without clearing global selection',
      () async {
    final config = query(['space-workflow-configurations', 'A']);
    final defaults = query(['workflow-default', 'A']);
    final global = query(['workflow-default', 'user']);
    for (final q in [config, defaults, global]) {
      await engine.ensure(q);
    }
    await router.handle({'type': 'space.deleted', 'spaceId': 'A'});
    expect(engine.peek(config).hasData, isFalse);
    expect(engine.peek(defaults).hasData, isFalse);
    expect(engine.peek(global).data, 1);
  });
  test('Discussion routing survives a destroyed view and excludes history',
      () async {
    final chat = query(['thread', 'W', 'discussion']);
    final history = query(['thread', 'W', 'work-requests']);
    await engine.ensure(chat);
    await engine.ensure(history);
    await router.handle({
      'type': 'thread.discussion.created',
      'payload': {'threadId': 'W'}
    });
    expect(engine.peek(chat).data, 2);
    expect(engine.peek(history).data, 1);
  });
  test('Thread ID finds its cached parent without a Space envelope', () async {
    var calls = 0;
    final q = AxQuery<List<AxThread>>(
        key: AxQueryKey(['space', 'A', 'threads']),
        load: () async {
          calls++;
          return [
            AxThread.fromJson({'id': 'W', 'spaceId': 'A'})
          ];
        });
    await engine.ensure(q);
    await router.handle({
      'type': 'thread.updated',
      'payload': {'entityId': 'W'}
    });
    expect(calls, 2);
  });
  test('failed refresh preserves cached data and exposes a query error',
      () async {
    var fail = false;
    final q = AxQuery<int>(
        key: AxQueryKey(['space', 'A']),
        load: () async {
          if (fail) throw StateError('offline');
          return 1;
        });
    await engine.ensure(q);
    fail = true;
    await expectLater(router.handle({'type': 'space.updated', 'spaceId': 'A'}),
        throwsStateError);
    expect(engine.peek(q).data, 1);
    expect(engine.peek(q).isStale, isTrue);
    expect(engine.peek(q).error, isA<StateError>());
  });
  test('session clear fences a pending event refresh', () async {
    final delayed = Completer<int>();
    var calls = 0;
    final q = AxQuery<int>(
        key: AxQueryKey(['space', 'A']),
        load: () => ++calls == 1 ? Future.value(1) : delayed.future);
    await engine.ensure(q);
    final refresh = router.handle({'type': 'space.updated', 'spaceId': 'A'});
    engine.clear();
    router.reset();
    delayed.complete(2);
    await refresh;
    expect(engine.peek(q).hasData, isFalse);
  });
  test('scoped reconnect does not expand to parent or child queries', () async {
    var collections = 0;
    final q = AxQuery<List<AxThread>>(
        key: AxQueryKey(['space', 'A', 'threads']),
        load: () async {
          collections++;
          return [
            AxThread.fromJson({'id': 'W', 'spaceId': 'A'})
          ];
        });
    await engine.ensure(q);
    await engine.ensure(query(['thread', 'W', 'discussion']));
    await engine.ensure(query(['thread', 'other', 'discussion']));
    await router.handle({
      'type': 'sync.required',
      'scope': {'kind': 'space', 'spaceId': 'A'}
    });
    expect(collections, 2);
    expect(loads.values.toList(), [1, 1]);
    await router.handle({
      'type': 'sync.required',
      'scope': {'kind': 'thread', 'threadId': 'W'}
    });
    expect(collections, 2);
    expect(loads.values.toList(), [2, 1]);
  });
  test('stream identity narrows a user-scope gap', () async {
    await engine.ensure(query(['space', 'A']));
    await engine.ensure(query(['space', 'B']));
    await router.handle({
      'type': 'sync.required',
      'scope': {'kind': 'user'},
      'stream': {'kind': 'space', 'id': 'A'},
    });
    expect(loads.values.toList(), [2, 1]);
  });
  test('malformed narrow scope does not reload every cache', () async {
    await engine.ensure(query(['space', 'A']));
    await router.handle({
      'type': 'sync.required',
      'scope': {'kind': 'space'},
    });
    expect(loads.values.single, 1);
  });
  test('user recovery leaves unobserved Space data for stale navigation',
      () async {
    router =
        AxRealtimeCacheRouter(engine, initialReadyFreshness: Duration.zero);
    final q = query(['space', 'A']);
    await engine.ensure(q);
    await router.handle({'type': 'realtime.ready'});
    expect(loads.values.single, 1);
    expect(engine.peek(q).data, 1);
    expect(engine.peek(q).isStale, isTrue);
  });
  test('first realtime.ready keeps just-loaded bootstrap data', () async {
    final fresh = query(['space', 'A', 'threads']);
    await engine.ensure(fresh);
    final pending = Completer<int>();
    var slowCalls = 0;
    final slow = AxQuery<int>(
        key: AxQueryKey(['space', 'B', 'threads']),
        load: () {
          slowCalls++;
          return pending.future;
        });
    final read = engine.ensure(slow);
    engine.watch(fresh, (_) {}, fireImmediately: false);
    engine.watch(slow, (_) {}, fireImmediately: false);

    await Future.wait([
      router.handle({'type': 'realtime.ready'}),
      Future<void>(() => pending.complete(1)),
    ]);
    await read;

    expect(loads['space:A:threads'], 1);
    expect(engine.peek(fresh).isStale, isFalse);
    expect(slowCalls, 1);
    expect(engine.peek(slow).data, 1);

    // Later ready signals are reconnects and still recover everything.
    await router.handle({'type': 'realtime.ready'});
    expect(loads['space:A:threads'], 2);
    expect(slowCalls, 2);
  });
  test('Thread metadata bursts share one trailing list refresh', () async {
    final threads = query(['space', 'A', 'threads']);
    final spaces = query(['spaces']);
    await engine.ensure(threads);
    await engine.ensure(spaces);
    await Future.wait([
      for (var i = 0; i < 3; i++)
        router.handle(
            {'type': 'thread.updated', 'spaceId': 'A', 'threadId': 'W'}),
    ]);
    expect(loads['space:A:threads'], 2);
    expect(loads['spaces'], 1);
  });
  test('reconnect retains data while only the matching query loads', () async {
    final delayed = Completer<int>();
    var calls = 0;
    final q = AxQuery<int>(
        key: AxQueryKey(['space', 'A']),
        load: () => ++calls == 1 ? Future.value(1) : delayed.future);
    await engine.ensure(q);
    final other = query(['space', 'B']);
    await engine.ensure(other);
    final recovery = router.handle({
      'type': 'sync.required',
      'scope': {'kind': 'space', 'spaceId': 'A'}
    });
    expect(engine.peek(q).data, 1);
    expect(engine.peek(q).isFetching, isTrue);
    expect(engine.peek(other).data, 1);
    delayed.complete(2);
    await recovery;
    expect(engine.peek(q).data, 2);
  });
  test('Discussion recovery uses the incremental integration callback',
      () async {
    final q = query(['thread', 'W', 'discussion']);
    await engine.ensure(q);
    final ids = <String>[];
    router = AxRealtimeCacheRouter(engine, discussionResynchronize: (id) async {
      ids.add(id);
    });
    await router.handle({
      'type': 'sync.required',
      'scope': {'kind': 'thread', 'threadId': 'W'}
    });
    expect(ids, ['W']);
    expect(loads.values.single, 1);
    expect(engine.peek(q).data, 1);
  });

  test('plain realtime.ready reconciles observed history in full', () async {
    final q = query(['thread', 'W', 'discussion']);
    await engine.ensure(q);
    engine.watch(q, (_) {}, fireImmediately: false);
    var incremental = 0;
    var full = 0;
    router = AxRealtimeCacheRouter(engine, discussionResynchronize: (id) async {
      incremental++;
    }, discussionFullResynchronize: (id) async {
      full++;
    });

    await router.handle({'type': 'realtime.ready'});

    expect(incremental, 0);
    expect(full, 1);
  });
  test('reported replay gap reconciles observed history in full', () async {
    final q = query(['thread', 'W', 'discussion']);
    await engine.ensure(q);
    engine.watch(q, (_) {}, fireImmediately: false);
    var incremental = 0;
    var full = 0;
    router = AxRealtimeCacheRouter(engine, discussionResynchronize: (id) async {
      incremental++;
    }, discussionFullResynchronize: (id) async {
      full++;
    });

    await router.handle({
      'type': 'sync.required',
      'scope': {'kind': 'user'}
    });

    expect(full, 1);
    expect(incremental, 0);
  });
  test('reconnect bursts share one recovery without detaching it', () async {
    final delayed = Completer<int>();
    var calls = 0;
    final q = AxQuery<int>(
        key: AxQueryKey(['space', 'A']),
        load: () => ++calls == 1 ? Future.value(1) : delayed.future);
    await engine.ensure(q);
    final event = {
      'type': 'sync.required',
      'scope': {'kind': 'space', 'spaceId': 'A'}
    };
    final first = router.handle(event);
    final second = router.handle(event);
    expect(calls, 2);
    expect(engine.peek(q).data, 1);
    delayed.complete(2);
    await Future.wait([first, second]);
    expect(engine.peek(q).data, 2);
    expect(engine.peek(q).isStale, isFalse);
  });
  test('cold observed Discussion participates in reconnect recovery', () async {
    final old = Completer<int>();
    final q = AxQuery<int>(
        key: AxQueryKey(['thread', 'W', 'discussion']), load: () => old.future);
    engine.watch(q, (_) {});
    final initial = engine.ensure(q);
    final ids = <String>[];
    router = AxRealtimeCacheRouter(engine, discussionResynchronize: (id) async {
      ids.add(id);
      await engine.refresh<int>(AxQuery<int>(key: q.key, load: () async => 2));
    });
    await router.handle({
      'type': 'sync.required',
      'scope': {'kind': 'thread', 'threadId': 'W'}
    });
    old.complete(1);
    await initial;
    expect(ids, ['W']);
    expect(engine.peek(q).data, 2);
  });
  test('scope invalidation excludes immutable Work cursor pages', () async {
    final current = query(['thread', 'W', 'work-requests']);
    final older = query(['thread', 'W', 'work-requests', 'old']);
    await engine.ensure(current);
    await engine.ensure(older);
    engine.invalidateScope(const AxSyncScope('thread', 'W'));
    expect(engine.peek(current).data, 1);
    expect(engine.peek(current).isStale, isTrue);
    expect(engine.peek(older).isStale, isFalse);
    expect(loads.values.toList(), [1, 1]);
  });
  test('user recovery excludes detached Discussion cache bridge listeners',
      () async {
    final q = query(['thread', 'W', 'discussion']);
    await engine.ensure(q);
    engine.watch(q, (_) {});
    final ids = <String>[];
    router = AxRealtimeCacheRouter(engine,
        initialReadyFreshness: Duration.zero,
        discussionObserved: (_) => false,
        discussionResynchronize: (id) async {
          ids.add(id);
        });
    await router.handle({'type': 'realtime.ready'});
    expect(ids, isEmpty);
    expect(engine.peek(q).isStale, isTrue);
    expect(engine.peek(q).data, 1);
  });
  test('Space deletion fences even an unhydrated in-flight query', () async {
    final response = Completer<int>();
    final q = AxQuery<int>(
        key: AxQueryKey(['space', 'A']), load: () => response.future);
    final read = engine.ensure(q);
    await router.handle({'type': 'space.deleted', 'spaceId': 'A'});
    response.complete(1);
    await read;
    expect(engine.peek(q).hasData, isFalse);
  });
  test('unknown resources do not trigger eager requests', () async {
    await router.handle({'type': 'space.updated', 'spaceId': 'unknown'});
    expect(loads, isEmpty);
  });
  test('user reconnect revalidates cached resources but never older Work pages',
      () async {
    final keys = [
      ['space', 'A'],
      ['space', 'B', 'threads'],
      ['thread', 'W', 'discussion'],
      ['thread', 'W', 'work-requests', 'old']
    ];
    for (final key in keys) {
      final q = query(key);
      await engine.ensure(q);
      engine.watch(q, (_) {});
    }
    await router.handle({
      'type': 'sync.required',
      'scope': {'kind': 'user'}
    });
    expect(loads.values.toList(), [2, 2, 2, 1]);
  });
  test('Space reconnect does not refresh another Space', () async {
    await engine.ensure(query(['space', 'A']));
    await engine.ensure(query(['space', 'B']));
    await router.handle({
      'type': 'sync.required',
      'scope': {'kind': 'space', 'spaceId': 'A'}
    });
    expect(loads.values.toList(), [2, 1]);
  });
  test('duplicate delivery is ignored and reset permits a new session',
      () async {
    await engine.ensure(query(['space', 'A']));
    final event = {'eventId': 'E', 'type': 'space.updated', 'spaceId': 'A'};
    await router.handle(event);
    await router.handle(event);
    expect(loads.values.single, 2);
    router.reset();
    await router.handle(event);
    expect(loads.values.single, 3);
  });
  test('late pre-event response cannot overwrite revalidated state', () async {
    final old = Completer<int>();
    var calls = 0;
    final q = AxQuery<int>(
        key: AxQueryKey(['space', 'A']),
        load: () => ++calls == 1 ? old.future : Future.value(2));
    final first = engine.ensure(q);
    await router.handle({'type': 'space.updated', 'spaceId': 'A'});
    old.complete(1);
    await first;
    expect(engine.peek(q).data, 2);
  });
  test(
      'space and invitation events revalidate invitations, spaces and member queries',
      () async {
    final myInvitations = query(['me', 'invitations']);
    final spaces = query(['spaces']);
    final spaceMembers = query(['space', 'A', 'members']);
    final spaceInvitations = query(['space', 'A', 'invitations']);
    final otherSpace = query(['space', 'B', 'members']);

    await engine.ensure(myInvitations);
    await engine.ensure(spaces);
    await engine.ensure(spaceMembers);
    await engine.ensure(spaceInvitations);
    await engine.ensure(otherSpace);

    expect(loads['me:invitations'], 1);
    expect(loads['spaces'], 1);
    expect(loads['space:A:members'], 1);
    expect(loads['space:A:invitations'], 1);
    expect(loads['space:B:members'], 1);

    await router.handle({
      'type': 'space.updated',
      'spaceId': 'A',
      'payload': {'entityId': 'pinv-123'},
    });

    expect(loads['me:invitations'], 2);
    expect(loads['spaces'], 2);
    expect(loads['space:A:members'], 2);
    expect(loads['space:A:invitations'], 2);
    expect(loads['space:B:members'], 1);
  });
}
