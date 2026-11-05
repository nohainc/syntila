import 'dart:async';
import 'dart:io';
import 'package:syntila_plugin_sdk/syntila_plugin_sdk.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late SessionStore store;
  setUp(() {
    root = Directory.systemTemp.createTempSync('checkpoint-test');
    store = SessionStore(root.path);
  });
  tearDown(() => root.deleteSync(recursive: true));
  SessionCheckpoint next(String id, int generation,
          {String output = 'answer'}) =>
      SessionCheckpoint(
          requestId: id,
          formatId: 'test-v1',
          model: 'm',
          generation: generation,
          contextRevision: generation,
          state: 'state',
          output: output);
  test('commits atomically and deduplicates a retry after reopening', () async {
    await store.transact('key',
        requestId: 'r1',
        formatId: 'test-v1',
        model: 'm',
        update: (_) async => next('r1', 1));
    final reopened = SessionStore(root.path);
    final result = await reopened.transact('key',
        requestId: 'r1',
        formatId: 'test-v1',
        model: 'm',
        update: (_) async => throw StateError('must not run twice'));
    expect(result.output, 'answer');
    expect(
        Directory('${root.path}/sessions')
            .listSync()
            .where((f) => f.path.endsWith('.tmp')),
        isEmpty);
  });
  test('failed update preserves committed state and releases its lock',
      () async {
    await store.transact('key',
        requestId: 'r1',
        formatId: 'test-v1',
        model: 'm',
        update: (_) async => next('r1', 1));
    final before = store.read('key');
    await expectLater(
        store.transact('key',
            requestId: 'r2',
            formatId: 'test-v1',
            model: 'm',
            update: (_) async => throw StateError('save failed')),
        throwsStateError);
    expect(store.read('key'), before);
    final committed = await store.transact('key',
        requestId: 'r2',
        formatId: 'test-v1',
        model: 'm',
        update: (_) async => next('r2', 2));
    expect(committed.generation, 2);
  });
  test('concurrent updates fail closed and revision cannot go backwards',
      () async {
    final release = Completer<void>();
    final entered = Completer<void>();
    final first = store.transact('key',
        requestId: 'r1', formatId: 'test-v1', model: 'm', update: (_) async {
      entered.complete();
      await release.future;
      return next('r1', 1);
    });
    await entered.future;
    await expectLater(
        SessionStore(root.path).transact('key',
            requestId: 'r2',
            formatId: 'test-v1',
            model: 'm',
            update: (_) async => next('r2', 2)),
        throwsStateError);
    release.complete();
    await first;
    await expectLater(
        store.transact('key',
            requestId: 'r2',
            formatId: 'test-v1',
            model: 'm',
            update: (_) async => next('r2', 1)),
        throwsStateError);
  });
  test('keys and symlink paths cannot escape the store', () {
    expect(() => store.write('../escape', 'x'), throwsArgumentError);
    if (!Platform.isWindows) {
      Link('${root.path}/sessions').createSync(Directory.systemTemp.path);
      expect(() => store.write('key', 'x'), throwsStateError);
    }
  });
}
