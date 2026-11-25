import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'package:http/http.dart' as http;
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/ax_stores.dart';
import 'package:syntila_app/src/ax/sync/ax_idempotency.dart';
import 'package:syntila_app/src/ax/sync/ax_discussion_cache.dart';
import 'package:syntila_app/src/ax/sync/ax_work_history.dart';
import 'ax_fixture_data.dart';

class _Source extends AxFixtureDataSource {
  final chatKeys = <String?>[],
      streamKeys = <String?>[],
      workKeys = <String?>[];
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        AxBuiltinWorkflow.fromJson({
          'id': 'direct',
          'version': 2,
          'name': 'Work',
          'description': 'Work',
          'steps': [
            {'kind': 'implement', 'order': 0}
          ]
        })
      ];
  @override
  Future<String> createWorkRequest({
    required String threadId,
    required String workflowId,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    String? idempotencyKey,
  }) async {
    workKeys.add(idempotencyKey);
    if (loseResponse) throw StateError('response lost');
    return 'saved-request';
  }

  bool loseResponse = true;
  int validations = 0;
  @override
  Future<List<String>> validateWorkRequestEligibility({
    required String threadId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    validations++;
    return [];
  }

  @override
  Future<AxWorkRequestStatus> loadWorkRequest(
          {required String workRequestId}) async =>
      const AxWorkRequestStatus(status: 'completed');
  @override
  Future<AxThread> createThread(
      {required String spaceId,
      required String name,
      String? idempotencyKey}) async {
    streamKeys.add(idempotencyKey);
    if (loseResponse) throw StateError('response lost');
    return AxThread.fromJson(
        {'id': 'saved-stream', 'spaceId': spaceId, 'name': name});
  }

  @override
  Future<AxDiscussionMessage> sendDiscussionMessage(
      {required String threadId,
      required String text,
      List<String> references = const [],
      List<Map<String, dynamic>> attachments = const [],
      String? idempotencyKey,
      Map<String, dynamic>? replyTo}) async {
    chatKeys.add(idempotencyKey);
    if (loseResponse) throw StateError('response lost');
    return AxDiscussionMessage(
        id: 'saved-message',
        threadId: threadId,
        authorUserId: 'human',
        body: text,
        createdAt: 'now');
  }
}

class _Client extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final body = request.url.path.endsWith('work-requests')
        ? {
            'workRequest': {'id': 'R'}
          }
        : request.url.path.endsWith('discussion-messages')
            ? {
                'message': {
                  'id': 'D',
                  'threadId': 'W',
                  'body': 'Hello',
                  'createdAt': 'now'
                }
              }
            : {
                'thread': {'id': 'W', 'spaceId': 'P', 'name': 'Stream'}
              };
    return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(body))), 201);
  }
}

void main() {
  testWidgets(
      'user retry after response loss resends the same key and replaces failed local work',
      (tester) async {
    final source = _Source();
    final cache = AxWorkHistoryCache(source);
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space: const AxSpace(
          id: 'P', name: 'Space', branch: '', lastActivity: '', role: 'owner'),
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
      onRunWork: (prompt, workflow, inputs, key) => source.createWorkRequest(
          threadId: 'W',
          workflowId: workflow,
          prompt: prompt,
          attachments: inputs,
          idempotencyKey: key),
    ))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Implement this');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(source.workKeys, hasLength(1));
    expect(cache.peek('W').requests.single.status, 'failed');
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Implement this');
    // Reopening/revalidation must not submit; only a user action triggers retry.
    await tester.pump(const Duration(seconds: 20));
    expect(source.workKeys, hasLength(1));
    source.loseResponse = false;
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(source.workKeys, hasLength(2));
    expect(source.workKeys[1], source.workKeys[0]);
    expect(source.validations, 1);
    expect(cache.peek('W').requests.map((r) => r.id), ['saved-request']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    cache.clear();
  });

  test('HTTP timeout retains Work operation identity for an explicit retry',
      () async {
    final cache = AxWorkHistoryCache(_Source());
    final keys = <String>[];
    Future<String> submit() =>
        cache.createRequest('W', prompt: 'Work', workflowId: 'direct',
            execute: (p, w, a, key) async {
          keys.add(key);
          if (keys.length == 1) {
            throw const AxApiException('Request timed out', statusCode: 408);
          }
          return 'saved-request';
        });
    await expectLater(submit(), throwsA(isA<AxApiException>()));
    expect(cache.localProgress('W').values.single,
        contains('Submission status is unknown'));
    await submit();
    expect(keys[1], keys[0]);
    cache.clear();
  });
  test(
      'keys are opaque, bounded and canonical retry identity resets after success or session clear',
      () {
    final attempts = AxMutationAttempts();
    final one = attempts.keyFor('W', {'a': 1, 'b': 2});
    expect(one, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(attempts.keyFor('W', {'b': 2, 'a': 1}), one);
    expect(attempts.keyFor('W2', {'a': 1, 'b': 2}), isNot(one));
    attempts.complete('W', {'a': 1, 'b': 2}, one);
    expect(attempts.keyFor('W', {'a': 1, 'b': 2}), isNot(one));
    attempts.clear();
    expect(attempts.keyFor('W', {'a': 1, 'b': 2}), isNot(one));
  });
  test(
      'all three HTTP mutations send an explicit key unchanged or generate a new one',
      () async {
    final client = _Client();
    final source = AxApiClient(baseUrl: 'https://cloud.test', client: client);
    const key = 'explicit-operation-000001';
    await source.createThread(
        spaceId: 'P', name: 'Stream', idempotencyKey: key);
    await source.sendDiscussionMessage(
        threadId: 'W', text: 'Hello', idempotencyKey: key);
    await source.createWorkRequest(
        threadId: 'W',
        workflowId: 'direct',
        prompt: 'Work',
        idempotencyKey: key);
    expect(client.requests.every((r) => r.headers['Idempotency-Key'] == key),
        isTrue);
    await source.createWorkRequest(
        threadId: 'W', workflowId: 'direct', prompt: 'Work');
    expect(client.requests.last.headers['Idempotency-Key'],
        matches(RegExp(r'^[a-f0-9]{64}$')));
  });
  test(
      'explicit Discussion retry keeps its key, does not replay during reads and commits one row',
      () async {
    final source = _Source();
    final cache = AxDiscussionCache(source);
    await expectLater(cache.send('W', 'Hello'), throwsStateError);
    await cache.synchronize('W');
    expect(source.chatKeys, hasLength(1));
    source.loseResponse = false;
    await cache.send('W', 'Hello');
    expect(source.chatKeys[1], source.chatKeys[0]);
    expect(cache.peek('W').messages.map((m) => m.id), ['saved-message']);
    await cache.send('W', 'Hello');
    expect(source.chatKeys[2], isNot(source.chatKeys[0]));
    cache.clear();
  });
  test(
      'Thread creation retry retains key after loss and resets on session clear',
      () async {
    final source = _Source();
    final store = AxStore(source);
    await expectLater(
        store.collaboration.createThread(spaceId: 'P', name: 'Stream'),
        throwsStateError);
    source.loseResponse = false;
    await store.collaboration.createThread(spaceId: 'P', name: 'Stream');
    expect(source.streamKeys[1], source.streamKeys[0]);
    source.loseResponse = true;
    await expectLater(
        store.collaboration.createThread(spaceId: 'P', name: 'Other'),
        throwsStateError);
    final failed = source.streamKeys.last;
    store.clearServerState();
    source.loseResponse = false;
    await store.collaboration.createThread(spaceId: 'P', name: 'Other');
    expect(source.streamKeys.last, isNot(failed));
    store.dispose();
  });
  test(
      'Work retries are explicit, keep key and local row identity, skip only client preflight and never queue',
      () async {
    final source = _Source();
    final cache = AxWorkHistoryCache(source);
    final keys = <String>[];
    Future<String> submit() =>
        cache.createRequest('W', prompt: 'Work', workflowId: 'direct',
            execute: (p, w, a, key) async {
          keys.add(key);
          if (source.loseResponse) throw StateError('response lost');
          return 'saved-request';
        });
    await expectLater(submit(), throwsStateError);
    final local = cache.peek('W').requests.single.id;
    await cache.refresh('W');
    await Future<void>.delayed(Duration.zero);
    expect(keys, hasLength(1));
    source.loseResponse = false;
    await submit();
    expect(keys[1], keys[0]);
    expect(source.validations, 1);
    expect(cache.peek('W').requests.map((r) => r.id), ['saved-request']);
    expect(cache.peek('W').requests.any((r) => r.id == local), isFalse);
    await submit();
    expect(keys[2], isNot(keys[0]));
    expect(source.validations, 2);
    cache.clear();
  });
}
