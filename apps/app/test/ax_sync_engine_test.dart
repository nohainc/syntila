import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';

void main() {
  late AxSyncEngine engine;
  late DateTime now;
  late AxQuery<int> query;
  late List<Completer<int>> requests;
  setUp(() {
    now = DateTime.utc(2026);
    engine = AxSyncEngine(clock: () => now);
    requests = [];
    query = AxQuery(
        key: AxQueryKey(['space', 'P1']),
        load: () {
          final request = Completer<int>();
          requests.add(request);
          return request.future;
        });
  });
  Future<void> seed([int value = 1]) async {
    final future = engine.refresh(query);
    requests.last.complete(value);
    await future;
  }

  test('existing HTTP data source remains underneath query loaders', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(request.url.path, '/spaces');
      return http.Response(jsonEncode({'spaces': []}), 200);
    });
    addTearDown(client.close);
    final source = AxApiClient(baseUrl: 'https://example.test', client: client);
    final spaces = AxQuery<List<AxSpace>>(
        key: AxQueryKey(['spaces']), load: source.loadSpaces);
    await engine.ensure(spaces);
    await engine.ensure(spaces);
    expect(calls, 1);
    expect(engine.peek(spaces).hasData, isTrue);
  });
  test('synchronous loader failure clears fetching and reports error',
      () async {
    final q = AxQuery<int>(
        key: AxQueryKey(['sync-error']), load: () => throw StateError('sync'));
    await expectLater(engine.ensure(q), throwsStateError);
    expect(engine.peek(q).isFetching, isFalse);
    expect(engine.peek(q).error, isStateError);
  });
  test('zero stale duration always revalidates cached data', () async {
    var calls = 0;
    final q = AxQuery<int>(
        key: AxQueryKey(['zero']),
        staleTime: Duration.zero,
        load: () async => ++calls);
    await engine.ensure(q);
    expect(engine.peek(q).isStale, isTrue);
    expect(await engine.ensure(q), 1);
    await Future<void>.delayed(Duration.zero);
    expect(engine.peek(q).data, 2);
    expect(calls, 2);
  });
  test('listener can cancel another listener during notification', () async {
    void Function()? cancel;
    var events = 0;
    engine.watch(query, (_) => cancel?.call(), fireImmediately: false);
    cancel = engine.watch(query, (_) => events++, fireImmediately: false);
    await seed();
    expect(events, 0);
  });
  test('later read supersedes pending mutation without rollback', () async {
    final write = Completer<int>();
    final mutation = engine.mutate(AxMutation(
        query: query, optimistic: (_) => 1, execute: () => write.future));
    await seed(3);
    write.complete(2);
    await mutation;
    expect(engine.peek(query).data, 3);
  });
  test('structural immutable keys and prefixes', () {
    final parts = ['space', 'a:b'];
    final key = AxQueryKey(parts);
    parts.clear();
    expect(key, AxQueryKey(['space', 'a:b']));
    expect(key.hashCode, AxQueryKey(['space', 'a:b']).hashCode);
    expect(key, isNot(AxQueryKey(['space:a', 'b'])));
    expect(key.startsWith(AxQueryKey(['space'])), isTrue);
    expect(() => key.parts.add('x'), throwsUnsupportedError);
    expect(() => AxQueryKey([]), throwsArgumentError);
    expect(() => AxQueryKey(['']), throwsArgumentError);
  });
  test('missing state and invalid stale duration', () {
    expect(engine.peek(query).hasData, isFalse);
    expect(engine.peek(query).isStale, isTrue);
    expect(engine.peek(query).lastAccessedAt, now);
    expect(
        () => AxQuery(
            key: query.key,
            load: query.load,
            staleTime: const Duration(seconds: -1)),
        throwsArgumentError);
  });
  test('five cold requests share the exact future', () async {
    final futures = List.generate(5, (_) => engine.ensure(query));
    expect(requests, hasLength(1));
    expect(futures.every((f) => identical(f, futures.first)), isTrue);
    expect(engine.peek(query).isFetching, isTrue);
    requests.single.complete(7);
    expect(await Future.wait(futures), [7, 7, 7, 7, 7]);
    expect(engine.peek(query).lastFetchedAt, now);
    expect(engine.peek(query).isStale, isFalse);
    expect(engine.peek(query).isFetching, isFalse);
  });
  test('fresh cache avoids network', () async {
    await seed();
    expect(await engine.ensure(query), 1);
    expect(requests, hasLength(1));
  });
  test('cacheFirst retains stale cache', () async {
    await seed();
    now = now.add(const Duration(minutes: 2));
    expect(await engine.ensure(query, policy: AxCachePolicy.cacheFirst), 1);
    expect(requests, hasLength(1));
    expect(engine.peek(query).isStale, isTrue);
  });
  test('stale cache returns immediately during deduplicated background read',
      () async {
    await seed();
    now = now.add(const Duration(minutes: 1));
    expect(await engine.ensure(query), 1);
    expect(await engine.ensure(query), 1);
    expect(requests, hasLength(2));
    expect(engine.peek(query).hasData, isTrue);
    expect(engine.peek(query).isFetching, isTrue);
    requests.last.complete(2);
    await engine.refresh(query);
    expect(engine.peek(query).data, 2);
  });
  test('networkOnly ignores cache and deduplicates', () async {
    await seed();
    final future = engine.ensure(query, policy: AxCachePolicy.networkOnly);
    expect(identical(future, engine.refresh(query)), isTrue);
    requests.last.complete(2);
    expect(await future, 2);
  });
  test('null is cached data', () async {
    var calls = 0;
    final q = AxQuery<int?>(
        key: AxQueryKey(['null']),
        load: () async {
          calls++;
          return null;
        });
    await engine.ensure(q);
    await engine.ensure(q);
    expect(engine.peek(q).hasData, isTrue);
    expect(calls, 1);
  });
  for (final background in [false, true]) {
    test('failure ${background ? 'preserves cached data' : 'is retryable'}',
        () async {
      if (background) {
        await seed();
        engine.invalidate(query.key);
        await engine.ensure(query);
      }
      final future = engine.refresh(query);
      final check = expectLater(future, throwsStateError);
      requests.last.completeError(StateError('offline'));
      await check;
      expect(engine.peek(query).error, isStateError);
      expect(engine.peek(query).isFetching, isFalse);
      expect(engine.peek(query).hasData, background);
      if (background) expect(engine.peek(query).data, 1);
      await seed(3);
      expect(engine.peek(query).error, isNull);
    });
  }
  for (final failure in [false, true]) {
    test(
        'superseded ${failure ? 'failure' : 'success'} cannot overwrite newer state',
        () async {
      final old = engine.refresh(query);
      final check = failure ? expectLater(old, throwsStateError) : null;
      final newer = engine.refresh(query, supersede: true);
      requests.last.complete(2);
      await newer;
      if (failure) {
        requests.first.completeError(StateError('old'));
        await check;
      } else {
        requests.first.complete(1);
        await old;
      }
      expect(engine.peek(query).data, 2);
      expect(engine.peek(query).error, isNull);
    });
  }
  test('invalidate fences old read and permits new request', () async {
    final old = engine.refresh(query);
    engine.invalidate(query.key);
    final newer = engine.refresh(query);
    requests.first.complete(1);
    await old;
    expect(engine.peek(query).hasData, isFalse);
    expect(engine.peek(query).isFetching, isTrue);
    requests.last.complete(2);
    await newer;
    expect(engine.peek(query).data, 2);
  });
  test('listeners are isolated, cancelable and reentrant', () async {
    final states = <AxQueryState<int>>[];
    var unrelated = 0;
    Future<int>? nested;
    final cancel = engine.watch(query, (s) {
      states.add(s);
      if (s.isFetching) nested = engine.refresh(query);
    });
    engine.watch(AxQuery<int>(key: AxQueryKey(['other']), load: () async => 9),
        (_) => unrelated++,
        fireImmediately: false);
    final future = engine.refresh(query);
    expect(identical(future, nested), isTrue);
    requests.single.complete(1);
    await future;
    expect(states.map((s) => s.isFetching), [false, true, false]);
    expect(unrelated, 0);
    cancel();
    cancel();
    engine.invalidate(query.key);
    expect(states, hasLength(3));
  });
  test('targeted and prefix invalidation', () async {
    await seed();
    final other =
        AxQuery<int>(key: AxQueryKey(['space', 'P2']), load: () async => 2);
    await engine.ensure(other);
    engine.invalidate(query.key);
    expect(engine.peek(query).isStale, isTrue);
    expect(engine.peek(other).isStale, isFalse);
    engine.invalidate(AxQueryKey(['space']), prefix: true);
    expect(engine.peek(other).isStale, isTrue);
  });
  for (final clear in [false, true]) {
    for (final observed in [false, true]) {
      test('${clear ? 'clear' : 'remove'} fences reads, observed=$observed',
          () async {
        var events = 0;
        if (observed) engine.watch(query, (_) => events++);
        final old = engine.refresh(query);
        if (clear) {
          engine.clear();
        } else {
          engine.remove(query.key);
        }
        await seed(2);
        requests.first.complete(1);
        await old;
        expect(engine.peek(query).data, 2);
        if (observed) expect(events, 5);
      });
    }
  }
  test('optimistic commit fences pending reads', () async {
    await seed();
    final old = engine.refresh(query);
    final write = Completer<int>();
    final future = engine.mutate(AxMutation(
        query: query,
        optimistic: (s) => s.data! + 1,
        execute: () => write.future));
    expect(engine.peek(query).data, 2);
    requests.last.complete(0);
    await old;
    expect(engine.peek(query).data, 2);
    write.complete(3);
    await future;
    expect(engine.peek(query).data, 3);
    expect(engine.peek(query).isStale, isFalse);
  });
  for (final cached in [false, true]) {
    test('mutation rollback cached=$cached', () async {
      if (cached) await seed();
      final before = engine.peek(query);
      await expectLater(
          engine.mutate(AxMutation(
              query: query,
              optimistic: (_) => 2,
              execute: () async => throw StateError('denied'))),
          throwsStateError);
      expect(engine.peek(query).data, before.data);
      expect(engine.peek(query).hasData, cached);
      expect(engine.peek(query).lastFetchedAt, before.lastFetchedAt);
      expect(engine.peek(query).error, isStateError);
      expect(engine.peek(query).isStale, isTrue);
    });
  }
  for (final failure in [false, true]) {
    test(
        'older mutation completion cannot override newer write, failure=$failure',
        () async {
      await seed();
      final write = Completer<int>();
      final old = engine.mutate(AxMutation(
          query: query, optimistic: (_) => 2, execute: () => write.future));
      final check = failure ? expectLater(old, throwsStateError) : null;
      await engine.mutate(AxMutation(query: query, execute: () async => 3));
      if (failure) {
        write.completeError(StateError('old'));
        await check;
      } else {
        write.complete(0);
        await old;
      }
      expect(engine.peek(query).data, 3);
      expect(engine.peek(query).error, isNull);
    });
  }
  test('clear fences mutations', () async {
    final write = Completer<int>();
    final future =
        engine.mutate(AxMutation(query: query, execute: () => write.future));
    engine.clear();
    write.complete(1);
    await future;
    expect(engine.peek(query).hasData, isFalse);
  });
  test('throwing optimistic transform changes nothing', () async {
    await seed();
    await expectLater(
        engine.mutate(AxMutation<int>(
            query: query,
            optimistic: (_) => throw StateError('transform'),
            execute: () async => 2)),
        throwsStateError);
    expect(engine.peek(query).data, 1);
    expect(engine.peek(query).generation, 1);
  });
  test('local update fences reads and preserves server timestamp', () async {
    await seed();
    final timestamp = engine.peek(query).lastFetchedAt;
    final pending = engine.refresh(query);
    engine.update(query, (state) => state.data! + 2);
    requests.last.complete(9);
    await pending;
    expect(engine.peek(query).data, 3);
    expect(engine.peek(query).lastFetchedAt, timestamp);
  });
  test('non-fencing update retains shared read', () async {
    await seed();
    final pending = engine.refresh(query);
    engine.update(query, (_) => 3, fenceReads: false);
    expect(engine.refresh(query), same(pending));
    expect(engine.peek(query).isFetching, isTrue);
    requests.last.complete(9);
    await pending;
    expect(engine.peek(query).data, 9);
  });
  test('throwing local update leaves generation and data intact', () async {
    await seed();
    final generation = engine.peek(query).generation;
    expect(() => engine.update(query, (_) => throw StateError('transform')),
        throwsStateError);
    expect(engine.peek(query).data, 1);
    expect(engine.peek(query).generation, generation);
  });
  test('conflicting definitions fail early', () {
    engine.peek(query);
    expect(
        () =>
            engine.peek(AxQuery<String>(key: query.key, load: () async => 'x')),
        throwsStateError);
    expect(
        () => engine.peek(AxQuery<int>(
            key: query.key, load: query.load, staleTime: Duration.zero)),
        throwsStateError);
  });
}
