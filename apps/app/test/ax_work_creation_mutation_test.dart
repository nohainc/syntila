import 'dart:async';
import 'package:flutter/material.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'package:syntila_app/src/features/common/syntila_markdown_body.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/sync/ax_work_history.dart';
import 'package:syntila_app/src/ax/sync/ax_realtime_cache_router.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'ax_fixture_data.dart';

AxWorkRequest request(String id, {String status = 'running'}) => AxWorkRequest(
    id: id,
    requestedByName: 'Human',
    prompt: 'Prompt',
    workflowId: 'direct',
    workflowVersion: 2,
    status: status,
    createdAt: '2026-10-06T00:00:00Z',
    steps: const []);

class WorkCreationSource extends AxFixtureDataSource {
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        AxBuiltinWorkflow.fromJson({
          'id': 'direct',
          'version': 2,
          'name': 'Work',
          'description': 'Implement work.',
          'steps': [
            {'kind': 'implement', 'order': 0}
          ]
        }),
      ];
  Completer<List<String>>? validation;

  bool failRead = false;
  int validations = 0, detailReads = 0, pageReads = 0;
  AxWorkRequestStatus details = const AxWorkRequestStatus(status: 'running');
  @override
  Future<List<String>> validateWorkRequestEligibility({
    required String threadId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
  }) {
    validations++;
    return validation?.future ?? Future.value([]);
  }

  @override
  Future<AxWorkRequestStatus> loadWorkRequest(
      {required String workRequestId}) async {
    detailReads++;
    if (failRead) throw StateError('read offline');
    return details;
  }

  @override
  Future<AxWorkRequestPage> loadThreadWorkRequestPage(
      {required String threadId,
      bool activeOnly = false,
      int limit = 40,
      String? beforeCreatedAt,
      String? beforeId}) async {
    pageReads++;
    return AxWorkRequestPage(requests: []);
  }
}

void main() {
  late WorkCreationSource source;
  late AxWorkHistoryCache cache;
  late Completer<String> post;
  late int posts;
  setUp(() {
    source = WorkCreationSource();
    cache = AxWorkHistoryCache(source);
    post = Completer();
    posts = 0;
  });
  Future<void> drain() => Future<void>.delayed(Duration.zero);
  Future<String> create(
          {String id = 'W',
          List<Map<String, dynamic>> attachments = const []}) =>
      cache.createRequest(id,
          prompt: 'Prompt',
          workflowId: 'direct',
          workflowVersion: 2,
          workflowName: 'Work',
          requestedByUserId: 'human',
          attachments: attachments, execute: (prompt, workflow, inputs, key) {
        posts++;
        return post.future;
      });

  testWidgets('submission survives destroying and reopening the Thread',
      (tester) async {
    post = Completer<String>();
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Widget page() => MaterialApp(
            home: Scaffold(
                body: ThreadPage(
          initialTab: 1,
          space: const AxSpace(
              id: 'P',
              name: 'Space',
              branch: '',
              lastActivity: '',
              role: 'owner'),
          thread: const AxThread(
              id: 'W',
              spaceId: 'P',
              name: 'Stream',
              lead: '',
              status: 'active',
              brief: '',
              queueStatus: ''),
          dataSource: source,
          workHistoryCache: cache,
          currentUserId: 'human',
          onBackToSpace: () {},
          onArchive: () {},
          onRunWork: (_, __, ___, key) {
            posts++;
            return post.future;
          },
        )));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Persistent request');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pump();
    expect(posts, 1);
    expect(cache.submitting('W'), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(cache.submitting('W'), isTrue);
    expect(
        find.byType(SyntilaMarkdownBody).evaluate().any((element) =>
            (element.widget as SyntilaMarkdownBody).data ==
            'Persistent request'),
        isTrue);
    expect(posts, 1);
    post.complete('server-request');
    await tester.pumpAndSettle();
    expect(cache.submitting('W'), isFalse);
    expect(cache.peek('W').requests.map((r) => r.id), ['server-request']);
    expect(posts, 1);
    expect(tester.takeException(), isNull);
  });

  test(
      'shared cache publishes the local request and progress before POST then replaces its ID',
      () async {
    source.validation = Completer();
    final write = create();
    expect(cache.peek('W').requests.single.id, startsWith('local-'));
    expect(cache.localProgress('W').values.single,
        'Checking that everything is ready…');
    expect(cache.submitting('W'), isTrue);
    expect(posts, 0);
    source.validation!.complete([]);
    await drain();
    expect(posts, 1);
    expect(cache.localProgress('W').values.single, 'Sending your request…');
    post.complete('server');
    expect(await write, 'server');
    expect(cache.peek('W').requests.single.id, 'server');
    expect(cache.peek('W').requests.single.status, 'running');
    expect(cache.localProgress('W'), isEmpty);
    expect(cache.submitting('W'), isFalse);
    expect(source.detailReads, 1);
  });

  test(
      'realtime confirmation before POST response is retained without duplicate or downgrade',
      () async {
    final write = create();
    await drain();
    cache.patchRequest('W', request('server', status: 'completed'));
    source.failRead = true;
    post.complete('server');
    await write;
    expect(cache.peek('W').requests.map((r) => r.id), ['server']);
    expect(cache.peek('W').requests.single.status, 'completed');
    expect(cache.localProgress('W'), isEmpty);
    expect(posts, 1);
  });

  test(
      'accepted POST survives detail-read failure and only the read is retried',
      () async {
    source.failRead = true;
    final write = create();
    await drain();
    post.complete('server');
    await write;
    expect(cache.peek('W').requests.single.id, 'server');
    expect(cache.peek('W').requests.single.status, 'queued');
    expect(cache.error('W'), isStateError);
    expect(posts, 1);
    source.failRead = false;
    await cache.refreshRequest('W', 'server');
    expect(cache.peek('W').requests.single.status, 'running');
    expect(posts, 1);
  });

  test(
      'ambiguous POST failure remains failed locally and reconnect never executes it again',
      () async {
    final write = create();
    final check = expectLater(write, throwsStateError);
    await drain();
    post.completeError(StateError('connection lost'));
    await check;
    expect(cache.peek('W').requests.single.status, 'failed');
    expect(cache.peek('W').requests.single.error,
        contains('Submission status is unknown'));
    await cache.refresh('W', activeOnly: true);
    await AxRealtimeCacheRouter(cache.engine).handle({
      'type': 'sync.required',
      'scope': {'kind': 'thread', 'threadId': 'W'}
    });
    await cache.refresh('W');
    await drain();
    expect(posts, 1);
    expect(cache.peek('W').requests.single.status, 'failed');
  });

  test('eligibility rejection restores a failed local row without issuing POST',
      () async {
    source.validation = Completer();
    final write = create();
    final check = expectLater(write, throwsA(isA<AxApiException>()));
    source.validation!.complete(['Grant does not allow access']);
    await check;
    expect(posts, 0);
    expect(cache.peek('W').requests.single.error,
        'Cannot run Work\n• Grant does not allow access');
    expect(cache.submitting('W'), isFalse);
  });

  test('preflight connectivity failure is known to have made no POST',
      () async {
    source.validation = Completer();
    final write = create();
    final check = expectLater(write, throwsStateError);
    source.validation!.completeError(StateError('offline'));
    await check;
    expect(posts, 0);
    expect(cache.peek('W').requests.single.error,
        isNot(contains('status is unknown')));
  });

  test(
      'another view cannot start a duplicate while validation or POST is pending',
      () async {
    source.validation = Completer();
    final write = create();
    await expectLater(create(), throwsStateError);
    expect(source.validations, 1);
    source.validation!.complete([]);
    await drain();
    await expectLater(create(), throwsStateError);
    expect(posts, 1);
    post.complete('server');
    await write;
    await expectLater(create(), throwsStateError);
    expect(posts, 1);
  });

  test('disposing an observer retains in-flight state for a new observer',
      () async {
    final cancel = cache.watch('W', () {});
    final write = create();
    await drain();
    cancel();
    expect(cache.peek('W').requests.single.id, startsWith('local-'));
    var updates = 0;
    final cancelNew = cache.watch('W', () => updates++);
    expect(cache.localProgress('W').values.single, 'Sending your request…');
    post.complete('server');
    await write;
    expect(updates, greaterThan(0));
    expect(cache.peek('W').requests.single.id, 'server');
    cancelNew();
  });

  test('clearing or removing a Thread during validation prevents POST',
      () async {
    for (final clearSession in [true, false]) {
      source = WorkCreationSource()..validation = Completer();
      cache = AxWorkHistoryCache(source);
      posts = 0;
      final write = create();
      final check = expectLater(write, throwsA(isA<AxMutationSuperseded>()));
      if (clearSession) {
        cache.clear();
        cache.engine.clear();
      } else {
        cache.engine.remove(AxQueryKey(['thread', 'W']), prefix: true);
      }
      source.validation!.complete([]);
      await check;
      expect(posts, 0);
      expect(cache.peek('W').requests, isEmpty);
    }
  });

  test('cleared session fences an already-issued POST response without replay',
      () async {
    final write = create();
    final check = expectLater(write, throwsA(isA<AxMutationSuperseded>()));
    await drain();
    expect(posts, 1);
    cache.clear();
    cache.engine.clear();
    post.complete('server');
    await check;
    expect(cache.peek('W').requests, isEmpty);
    expect(source.detailReads, 0);
    expect(posts, 1);
  });

  test('authored attachments are snapshotted before asynchronous validation',
      () async {
    source.validation = Completer();
    final attachment = {'name': 'original.txt', 'content': 'Original'};
    final write = cache.createRequest('W',
        prompt: 'Prompt',
        workflowId: 'direct',
        attachments: [attachment], execute: (prompt, workflow, inputs, key) {
      posts++;
      expect(inputs.single['name'], 'original.txt');
      return post.future;
    });
    attachment['name'] = 'changed.txt';
    source.validation!.complete([]);
    await drain();
    post.complete('server');
    await write;
    expect(posts, 1);
  });
}
