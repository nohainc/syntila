import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/sync/ax_work_history.dart';
import 'package:syntila_app/src/ax/sync/ax_work_realtime_sync.dart';
import 'ax_fixture_data.dart';

AxWorkRequest work(String id, {String status = 'running'}) => AxWorkRequest(
        id: id,
        requestedByName: 'You',
        prompt: 'Prompt $id',
        workflowId: 'direct',
        workflowVersion: 2,
        status: status,
        createdAt: '2026-10-06T00:00:00Z',
        steps: const [
          AxWorkRequestStep(
              kind: 'implement', status: 'queued', workerId: 'worker')
        ]);
AxWorkRequestStatus detail(String id,
        {String status = 'completed', String ws = 'w'}) =>
    AxWorkRequestStatus(
        id: id,
        threadId: ws,
        status: status,
        text: '# Result',
        originalRequest: 'Prompt $id',
        workflowId: 'direct',
        workflowVersion: 2,
        createdAt: '2026-10-06T00:00:00Z',
        steps: [
          AxWorkRequestStep(
              kind: 'implement',
              status: status,
              workerId: 'worker',
              resultText: '# Result')
        ]);

class RealtimeSource extends AxFixtureDataSource {
  List<AxWorkRequest> records = [work('r')];
  final pages = <bool>[];
  final gets = <String>[];
  final pageScopes = <String>[];
  final queuedDetails = <Completer<AxWorkRequestStatus>>[];
  Completer<AxWorkRequestPage>? queuedPage;
  @override
  Future<AxWorkRequestPage> loadThreadWorkRequestPage(
      {required String threadId,
      int limit = 50,
      String? beforeCreatedAt,
      String? beforeId,
      bool activeOnly = false}) {
    pages.add(activeOnly);
    pageScopes.add(threadId);
    final pending = queuedPage;
    queuedPage = null;
    return pending?.future ??
        Future.value(AxWorkRequestPage(requests: records));
  }

  @override
  Future<AxWorkRequestStatus> loadWorkRequest({required String workRequestId}) {
    gets.add(workRequestId);
    return queuedDetails.isEmpty
        ? Future.value(detail(workRequestId))
        : queuedDetails.removeAt(0).future;
  }
}

Map<String, dynamic> event(String type,
        {String status = 'completed',
        String id = 'r',
        String ws = 'w',
        int? sequence}) =>
    {
      'type': type,
      if (sequence != null) 'sequence': sequence,
      'workspaceId': 'workspace',
      'payload': <String, dynamic>{
        'workRequestId': id,
        'threadId': ws,
        'status': status,
        'stepKind': 'implement'
      }
    };
void main() {
  late RealtimeSource source;
  late AxWorkHistoryCache cache;
  late AxWorkRealtimeSync sync;
  setUp(() {
    source = RealtimeSource();
    cache = AxWorkHistoryCache(source);
    sync = AxWorkRealtimeSync(cache);
  });
  tearDown(() => sync.dispose());
  Future<void> seed() async {
    await cache.refresh('w');
  }

  Future<void> drain() => Future<void>.delayed(Duration.zero);
  AxWorkRequest phased(String id, String phase) => work(id).copyWith(steps: [
        AxWorkRequestStep(
            kind: 'implement',
            status: 'running',
            workerId: 'worker',
            assignmentId: 'assignment-$id',
            executionPhase: phase)
      ]);
  Map<String, dynamic> phaseEvent(String id, String phase,
          {String? assignment}) =>
      {
        ...event('step.phase', id: id, status: phase),
        'assignmentId': assignment ?? 'assignment-$id',
      };

  test('phase events advance only their own assignment and request', () async {
    source.records = [phased('r', 'queued'), phased('other', 'delivered')];
    await seed();
    await sync.handle(phaseEvent('r', 'starting'));
    await sync.handle(phaseEvent('r', 'running'));
    await sync.handle(phaseEvent('r', 'delivered'));
    expect(cache.request('w', 'r')!.steps.single.effectivePhase, 'running');
    expect(
        cache.request('w', 'other')!.steps.single.effectivePhase, 'delivered');
    expect(source.gets, isEmpty);
    await sync.handle(phaseEvent('r', 'running', assignment: 'old-attempt'));
    expect(source.gets, ['r']);
    expect(cache.request('w', 'r')!.status, 'completed');
  });

  test('uncertain and terminal phase events re-read authoritative detail',
      () async {
    for (final phase in ['uncertain', 'failed', 'completed', 'cancelled']) {
      cache.patchRequest('w', phased('r', 'starting'));
      await sync.handle(phaseEvent('r', phase));
      expect(cache.request('w', 'r')!.status, 'completed');
    }
    expect(source.gets, List.filled(4, 'r'));
  });

  test('late phase and complete payload cannot revive a terminal request',
      () async {
    source.records = [work('r', status: 'completed')];
    await seed();
    await sync.handle(phaseEvent('r', 'running'));
    final stale = event('work_request.started', status: 'running');
    (stale['payload'] as Map)['workRequest'] = {
      'id': 'r',
      'createdAt': '2026-10-06T00:00:00Z',
      'workflowId': 'direct',
      'workflowVersion': 2,
      'prompt': 'p',
      'requestedByName': 'You',
      'status': 'running',
      'steps': [],
    };
    await sync.handle(stale);
    expect(cache.request('w', 'r')!.status, 'completed');
    expect(source.gets, ['r', 'r']);
  });

  test('late legacy queue events cannot regress running work', () async {
    source.records = [phased('r', 'running')];
    await seed();
    await sync.handle(event('step.queued', status: 'queued'));
    expect(cache.request('w', 'r')!.status, 'completed');
    cache.patchRequest('w', phased('r', 'running'));
    await sync.handle(event('work_request.created', status: 'queued'));
    expect(cache.request('w', 'r')!.status, 'completed');
  });

  test('a stale full payload cannot regress a running assignment', () async {
    source.records = [phased('r', 'running')];
    await seed();
    final stale = event('step.phase', status: 'starting');
    (stale['payload'] as Map)['workRequest'] = {
      'id': 'r',
      'createdAt': '2026-10-06T00:00:00Z',
      'workflowId': 'direct',
      'workflowVersion': 2,
      'prompt': 'p',
      'requestedByName': 'You',
      'status': 'running',
      'steps': [
        {
          'kind': 'implement',
          'status': 'running',
          'assignmentId': 'assignment-r',
          'executionPhase': 'starting'
        }
      ],
    };
    await sync.handle(stale);
    expect(source.gets, ['r']);
    expect(cache.request('w', 'r')!.status, 'completed');
  });

  test('full payload cannot revive a terminal step in an active request',
      () async {
    source.records = [phased('r', 'failed')];
    await seed();
    final stale = event('step.phase', status: 'running');
    (stale['payload'] as Map)['workRequest'] = {
      'id': 'r',
      'createdAt': '2026-10-06T00:00:00Z',
      'workflowId': 'direct',
      'workflowVersion': 2,
      'prompt': 'p',
      'requestedByName': 'You',
      'status': 'running',
      'steps': [
        {
          'kind': 'implement',
          'status': 'running',
          'assignmentId': 'assignment-r',
          'executionPhase': 'running'
        }
      ],
    };
    await sync.handle(stale);
    expect(source.gets, ['r']);
    expect(cache.request('w', 'r')!.status, 'completed');
  });
  test('Thread gap recovers its retained active entities only', () async {
    await seed();
    await cache.refresh('other');
    source.pages.clear();
    source.pageScopes.clear();
    source.records = [];
    await sync.handle({
      'type': 'sync.required',
      'scope': {'kind': 'thread', 'threadId': 'w'}
    });
    expect(source.pageScopes, ['w']);
    expect(source.pages, [true]);
    expect(source.gets, ['r']);
    expect(cache.request('other', 'r')!.status, 'running');
    expect(cache.request('w', 'r')!.status, 'completed');
  });
  test('background gap is retained while visible recovery is in flight',
      () async {
    await seed();
    await cache.refresh('background');
    final cancel = sync.listen(null, threadId: 'w');
    final delayed = Completer<AxWorkRequestPage>();
    source.queuedPage = delayed;
    final visible = sync.handle({
      'type': 'sync.required',
      'scope': {'kind': 'user'}
    });
    final background = sync.handle({
      'type': 'sync.required',
      'scope': {'kind': 'thread', 'threadId': 'background'}
    });
    delayed.complete(AxWorkRequestPage(requests: source.records));
    await Future.wait([visible, background]);
    expect(source.pageScopes.where((id) => id == 'background').length, 2);
    expect(cache.request('background', 'r'), isNotNull);
    cancel();
  });
  test('Space stream gaps do not fetch execution history', () async {
    await seed();
    await sync.handle({
      'type': 'sync.required',
      'scope': {'kind': 'user'},
      'stream': {'kind': 'space', 'id': 'P'}
    });
    expect(source.pages, [false]);
    expect(source.gets, isEmpty);
  });
  test('sufficient Work and Step statuses patch without HTTP', () async {
    source.records = [work('r', status: 'queued')];
    await seed();
    await sync.handle(event('work_request.started', status: 'running'));
    await sync.handle(event('step.running', status: 'running'));
    expect(cache.request('w', 'r')!.status, 'running');
    expect(cache.request('w', 'r')!.steps.single.status, 'running');
    expect(cache.request('w', 'r')!.steps.single.workerId, 'worker');
    expect(source.gets, isEmpty);
    expect(source.pages, [false]);
  });
  for (final type in [
    'work_request.completed',
    'work_request.failed',
    'work_request.cancelled',
  ]) {
    test('$type reconciles one request rather than history', () async {
      await seed();
      await sync.handle(event(type));
      expect(source.gets, ['r']);
      expect(source.pages, [false]);
      expect(cache.request('w', 'r')!.finalText, '# Result');
    });
  }
  for (final (type, status) in [
    ('step.completed', 'completed'),
    ('step.failed', 'failed'),
    ('step.cancelled', 'cancelled'),
  ]) {
    test('$type on the last Step waits for the request terminal read',
        () async {
      await seed();
      await sync.handle(event(type, status: status));
      expect(source.gets, isEmpty);
      expect(cache.request('w', 'r')!.status, 'running');
      expect(cache.request('w', 'r')!.steps.single.status, status);
      await sync.handle(event('work_request.$status', status: status));
      expect(source.gets, ['r']);
      expect(cache.request('w', 'r')!.finalText, '# Result');
    });
  }
  test('a terminal event for an earlier Step still re-reads', () async {
    source.records = [
      work('r').copyWith(steps: const [
        AxWorkRequestStep(
            kind: 'implement', status: 'running', workerId: 'worker'),
        AxWorkRequestStep(kind: 'review', status: 'queued', workerId: 'worker'),
      ])
    ];
    await seed();
    await sync.handle(event('step.completed'));
    expect(source.gets, ['r']);
  });
  test('first phase of a step read before assignment adopts it', () async {
    source.records = [work('r')];
    await seed();
    await sync.handle(phaseEvent('r', 'starting', assignment: 'asg-new'));
    expect(source.gets, isEmpty);
    final step = cache.request('w', 'r')!.steps.single;
    expect(step.assignmentId, 'asg-new');
    expect(step.effectivePhase, 'starting');
    await sync.handle(phaseEvent('r', 'running', assignment: 'asg-new'));
    expect(source.gets, isEmpty);
    expect(cache.request('w', 'r')!.steps.single.effectivePhase, 'running');
  });
  test('unknown created request is inserted from its single detail', () async {
    await seed();
    await sync
        .handle(event('work_request.created', id: 'new', status: 'queued'));
    expect(source.gets, ['new']);
    expect(cache.request('w', 'new')!.prompt, 'Prompt new');
    expect(cache.peek('w').requests.length, 2);
    expect(source.pages.length, 1);
  });
  test('a complete payload patches without a detail read', () async {
    await seed();
    final value = event('work_request.completed');
    (value['payload'] as Map)['workRequest'] = {
      'id': 'r',
      'requestedByName': 'You',
      'prompt': '# Exact prompt',
      'workflowId': 'direct',
      'workflowVersion': 2,
      'createdAt': '2026-10-06T00:00:00Z',
      'status': 'completed',
      'steps': [],
      'finalText': '# Exact result'
    };
    await sync.handle(value);
    expect(cache.request('w', 'r')!.finalText, '# Exact result');
    expect(source.gets, isEmpty);
  });
  test('duplicate and out-of-order sequences cannot regress the cache',
      () async {
    await seed();
    await sync.handle(event('work_request.completed', sequence: 20));
    await sync
        .handle(event('work_request.started', status: 'running', sequence: 19));
    await sync.handle(event('work_request.completed', sequence: 20));
    expect(source.gets, ['r']);
    expect(cache.request('w', 'r')!.status, 'completed');
  });
  test('a Space stream has its own sequence after a Workspace stream',
      () async {
    await seed();
    await sync
        .handle(event('work_request.started', status: 'running', sequence: 20));
    final completion = event('work_request.completed', sequence: 1)
      ..remove('workspaceId')
      ..['stream'] = {'kind': 'space', 'id': 'space-1'};
    await sync.handle(completion);
    expect(cache.request('w', 'r')!.status, 'completed');
  });
  test('event bursts share the read and fence an obsolete response', () async {
    await seed();
    final old = Completer<AxWorkRequestStatus>(),
        latest = Completer<AxWorkRequestStatus>();
    source.queuedDetails.addAll([old, latest]);
    final first = sync.handle(event('work_request.completed', sequence: 1));
    final next = sync
        .handle(event('work_request.failed', status: 'failed', sequence: 2));
    expect(source.gets, ['r']);
    old.complete(detail('r', status: 'running'));
    await drain();
    expect(source.gets, ['r', 'r']);
    expect(cache.request('w', 'r')!.status, 'running');
    latest.complete(detail('r', status: 'failed'));
    await Future.wait([first, next]);
    expect(cache.request('w', 'r')!.status, 'failed');
  });
  test('a late head page cannot overwrite an event patch', () async {
    await seed();
    final page = Completer<AxWorkRequestPage>();
    source.queuedPage = page;
    final refresh = cache.refresh('w');
    await sync.handle(event('work_request.completed'));
    page.complete(AxWorkRequestPage(requests: [work('r'), work('other')]));
    await refresh;
    expect(cache.request('w', 'r')!.status, 'completed');
    expect(cache.request('w', 'other'), isNotNull);
    expect(cache.peek('w').initialLoaded, isTrue);
  });
  test('session clear fences a pending entity read', () async {
    await seed();
    final response = Completer<AxWorkRequestStatus>();
    source.queuedDetails.add(response);
    final read = sync.handle(event('work_request.completed'));
    sync.reset();
    cache.clear();
    response.complete(detail('r'));
    await read;
    expect(cache.peek('w').requests, isEmpty);
  });
  test('failed details preserve data and remain available for targeted retry',
      () async {
    await seed();
    final response = Completer<AxWorkRequestStatus>();
    source.queuedDetails.add(response);
    final read = sync.handle(event('work_request.completed'));
    final check = expectLater(read, throwsStateError);
    response.completeError(StateError('offline'));
    await check;
    expect(cache.request('w', 'r')!.status, 'running');
    expect(cache.dirtyIds('w'), {'r'});
    await cache.refreshRequest('w', 'r');
    expect(cache.error('w'), isNull);
  });
  test('mismatched detail identity is rejected', () async {
    await seed();
    final response = Completer<AxWorkRequestStatus>();
    source.queuedDetails.add(response);
    final read = sync.handle(event('work_request.completed'));
    final check = expectLater(read, throwsA(isA<AxApiException>()));
    response.complete(detail('wrong'));
    await check;
    expect(cache.request('w', 'r')!.status, 'running');
  });
  test(
      'shared stream leases process each event once and keep cache after view disposal',
      () async {
    await seed();
    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);
    final root = sync.listen(events.stream);
    final view = sync.listen(events.stream, threadId: 'w');
    events.add(event('work_request.completed'));
    await drain();
    expect(source.gets, ['r']);
    view();
    expect(sync.polling, isFalse);
    events.add(event('work_request.completed', id: 'other'));
    await drain();
    expect(source.gets, ['r', 'other']);
    expect(cache.request('w', 'other'), isNotNull);
    root();
  });
  testWidgets('brief interruptions are not displayed; lasting ones are',
      (tester) async {
    await seed();
    final cancel = sync.listen(null, threadId: 'w');
    await sync.handle({'type': 'realtime.connection', 'status': 'connected'});
    await sync
        .handle({'type': 'realtime.connection', 'status': 'reconnecting'});
    expect(sync.checkingExecution, isTrue);
    expect(sync.displayStatus, AxWorkRealtimeStatus.available);
    await tester.pump(const Duration(seconds: 1));
    await sync.handle({'type': 'realtime.connection', 'status': 'connected'});
    await tester.pump(const Duration(seconds: 5));
    expect(sync.displayStatus, AxWorkRealtimeStatus.available);
    await sync
        .handle({'type': 'realtime.connection', 'status': 'reconnecting'});
    await tester.pump(const Duration(seconds: 3));
    expect(sync.displayStatus, AxWorkRealtimeStatus.checking);
    await sync.handle({'type': 'realtime.connection', 'status': 'connected'});
    expect(sync.displayStatus, AxWorkRealtimeStatus.available);
    cancel();
  });
  testWidgets(
      'healthy realtime disables polling; disconnection polls every 15 seconds and restoration stops it',
      (tester) async {
    await seed();
    final cancel = sync.listen(null, threadId: 'w');
    await sync.handle({'type': 'realtime.connection', 'status': 'connected'});
    expect(sync.polling, isFalse);
    expect(sync.checkingExecution, isFalse);
    await tester.pump(const Duration(seconds: 45));
    expect(source.pages, [false]);
    expect(source.gets, ['r']);
    await sync
        .handle({'type': 'realtime.connection', 'status': 'reconnecting'});
    expect(sync.polling, isTrue);
    expect(sync.checkingExecution, isTrue);
    await tester.pump(const Duration(seconds: 14));
    expect(source.pages.length, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(source.pages, [false, true]);
    source.records = [
      work('r', status: 'completed'),
      work('missed', status: 'completed')
    ];
    await sync.handle({'type': 'realtime.connection', 'status': 'connected'});
    expect(sync.healthy, isTrue);
    expect(sync.polling, isFalse);
    expect(sync.checkingExecution, isFalse);
    expect(cache.request('w', 'missed'), isNotNull);
    final pages = source.pages.length, gets = source.gets.length;
    await tester.pump(const Duration(seconds: 45));
    expect(source.pages.length, pages);
    expect(source.gets.length, gets);
    cancel();
  });
  test('progress-only execution bursts perform no history or detail reads',
      () async {
    await seed();
    source.pages.clear();
    for (var i = 0; i < 100; i++) {
      await sync.handle(event('assignment.activity'));
      await sync.handle(event('task.progress'));
    }
    expect(source.gets, isEmpty);
    expect(source.pages, isEmpty);
  });

  test(
      'execution signals reconcile their request without reading any history page',
      () async {
    await seed();
    source.pages.clear();
    for (final type in [
      'run.completed',
      'task.completed',
      'attempt.failed',
      'assignment.completed',
      'artifact.created',
      'finding.created',
      'verification.completed'
    ]) {
      await sync.handle(event(type));
    }
    expect(source.gets, List.filled(7, 'r'));
    expect(source.pages, isEmpty);
    expect(cache.request('w', 'r')!.status, 'completed');
  });
  testWidgets(
      'disconnected fallback only reads visible scopes and stops after release',
      (tester) async {
    await cache.refresh('w');
    await cache.refresh('background');
    source.pages.clear();
    source.pageScopes.clear();
    final release = sync.listen(null, threadId: 'w');
    await sync
        .handle({'type': 'realtime.connection', 'status': 'reconnecting'});
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(source.pageScopes, ['w']);
    release();
    expect(sync.polling, isFalse);
    await tester.pump(const Duration(seconds: 60));
    expect(source.pageScopes, ['w']);
  });

  testWidgets(
      'recovery removes only a missing retained request and stops retrying it',
      (tester) async {
    source.records = [work('r'), work('keep', status: 'completed')];
    await seed();
    source.records = [];
    final missing = Completer<AxWorkRequestStatus>();
    source.queuedDetails.add(missing);
    final release = sync.listen(null, threadId: 'w');
    await sync
        .handle({'type': 'realtime.connection', 'status': 'reconnecting'});
    await tester.pump(const Duration(seconds: 15));
    missing.completeError(const AxApiException('Not found', statusCode: 404));
    await tester.pump();
    expect(cache.request('w', 'r'), isNull);
    expect(cache.request('w', 'keep'), isNotNull);
    expect(cache.dirtyIds('w'), isEmpty);
    expect(source.gets, ['r']);
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(source.gets, ['r']);
    await sync.handle({'type': 'realtime.connection', 'status': 'connected'});
    expect(sync.healthy, isTrue);
    expect(sync.polling, isFalse);
    release();
  });

  test('a superseded 404 triggers the newer detail read', () async {
    await seed();
    final stale = Completer<AxWorkRequestStatus>();
    source.queuedDetails.add(stale);
    final first = cache.refreshRequest('w', 'r');
    final newer = cache.refreshRequest('w', 'r', supersede: true);
    stale.completeError(const AxApiException('Not found', statusCode: 404));
    await Future.wait([first, newer]);
    expect(source.gets, ['r', 'r']);
    expect(cache.request('w', 'r')!.status, 'completed');
    expect(cache.dirtyIds('w'), isEmpty);
  });

  test('Step events notify only their own Thread', () async {
    await seed();
    var a = 0, b = 0;
    cache.watch('w', () => a++);
    cache.watch('other', () => b++);
    await sync.handle(event('step.running', status: 'running'));
    expect(a, 1);
    expect(b, 0);
  });
  testWidgets(
      'a failed detail read does not enable polling while the socket is healthy',
      (tester) async {
    await seed();
    final cancel = sync.listen(null, threadId: 'w');
    await sync.handle({'type': 'realtime.connection', 'status': 'connected'});
    final failed = Completer<AxWorkRequestStatus>();
    source.queuedDetails.add(failed);
    final read = sync.handle(event('work_request.failed', status: 'failed'));
    final check = expectLater(read, throwsStateError);
    failed.completeError(StateError('temporary HTTP error'));
    await check;
    expect(sync.healthy, isTrue);
    expect(sync.polling, isFalse);
    await tester.pump(const Duration(seconds: 45));
    expect(source.pages, [false]);
    expect(cache.dirtyIds('w'), {'r'});
    cancel();
  });
  test(
      'restoration discovers new requests and fetches older active entities by ID',
      () async {
    await seed();
    final cancel = sync.listen(null, threadId: 'w');
    await sync.handle({'type': 'realtime.connection', 'status': 'connected'});
    cache.patchRequest('w', work('r'));
    source.records = [work('missed', status: 'completed')];
    await sync
        .handle({'type': 'realtime.connection', 'status': 'reconnecting'});
    await sync.handle({'type': 'realtime.connection', 'status': 'connected'});
    expect(source.pages, [false, false]);
    expect(source.gets, ['r', 'r']);
    expect(cache.request('w', 'r')!.status, 'completed');
    expect(cache.request('w', 'missed'), isNotNull);
    expect(sync.polling, isFalse);
    cancel();
  });
  testWidgets(
      'slow fallback reads never accumulate polling requests and restoration follows them',
      (tester) async {
    await seed();
    final cancel = sync.listen(null, threadId: 'w');
    final delayed = Completer<AxWorkRequestPage>();
    source.queuedPage = delayed;
    await tester.pump(const Duration(seconds: 15));
    expect(source.pages, [false, true]);
    await tester.pump(const Duration(seconds: 30));
    expect(source.pages.length, 2);
    final restored =
        sync.handle({'type': 'realtime.connection', 'status': 'connected'});
    delayed.complete(AxWorkRequestPage(requests: [work('r')]));
    await tester.pump();
    await restored;
    expect(sync.healthy, isTrue);
    expect(sync.polling, isFalse);
    expect(source.pages, [false, true, false]);
    cancel();
  });
  test(
      'a late head read cannot overwrite a newer detail response even when it started after that detail read',
      () async {
    await seed();
    final response = Completer<AxWorkRequestStatus>();
    source.queuedDetails.add(response);
    final entity = cache.refreshRequest('w', 'r');
    final page = Completer<AxWorkRequestPage>();
    source.queuedPage = page;
    final head = cache.refresh('w');
    response.complete(detail('r'));
    await entity;
    page.complete(AxWorkRequestPage(requests: [work('r')]));
    await head;
    expect(cache.request('w', 'r')!.status, 'completed');
  });
}
