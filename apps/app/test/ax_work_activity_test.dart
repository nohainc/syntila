import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syntila_app/src/ax/ax_work_activity.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';

Map<String, dynamic> activityEvent({
  required String eventId,
  required int streamSequence,
  required int activitySequence,
  required String type,
  required String status,
  String activityId = 'tool-1',
  String title = 'Running repository checks',
  String attemptId = 'attempt-1',
  String? preview,
}) =>
    {
      'eventId': eventId,
      'type': 'assignment.activity',
      'version': '1.0',
      'timestamp': DateTime.utc(2026, 10, 12, 18)
          .add(Duration(seconds: activitySequence))
          .toIso8601String(),
      'workspaceId': 'workspace-1',
      'threadId': 'thread-1',
      'attemptId': attemptId,
      'assignmentId': 'assignment-1',
      'workspaceRuntimeId': 'runtime-1',
      'sequence': streamSequence,
      'payload': {
        'entityId': 'assignment-1',
        'workerId': 'chatgpt',
        'sourceEventId': eventId,
        'executionId': 'execution-1',
        'activityId': activityId,
        'activitySequence': activitySequence,
        'activityType': type,
        'activityStatus': status,
        'title': title,
        if (type == 'tool.started') 'details': {'toolName': 'shell'},
        if (preview != null) 'details': {'preview': preview},
      },
    };

void main() {
  test('renders profile milestone keys as readable activity titles', () {
    for (final (key, expected) in [
      ('provider_working', 'Working'),
      ('provider_tool_started', 'Using a tool'),
      ('provider_response_received', 'Response received'),
      ('provider_finalizing', 'Finishing up'),
      ('provider_unknown_milestone', 'Working'),
    ]) {
      final event = activityEvent(
          eventId: key,
          streamSequence: 0,
          activitySequence: 1,
          type: 'message.updated',
          status: 'updated',
          title: key);
      (event['payload'] as Map<String, dynamic>)['details'] = {
        'source': 'profile.milestone'
      };
      expect(
          AxWorkActivity.fromRealtimeEvent(event, threadId: 'thread-1').title,
          expected);
    }
    final regular = activityEvent(
        eventId: 'regular',
        streamSequence: 0,
        activitySequence: 1,
        type: 'tool.started',
        status: 'running',
        title: 'Search the web');
    expect(
        AxWorkActivity.fromRealtimeEvent(regular, threadId: 'thread-1').title,
        'Search the web');
  });
  test('accepts activity from a Worker-first Space stream', () {
    final store = AxWorkActivityStore();
    final event = activityEvent(
        eventId: 'worker-event',
        streamSequence: 0,
        activitySequence: 1,
        type: 'tool.started',
        status: 'running')
      ..remove('workspaceId')
      ..remove('workspaceRuntimeId')
      ..['version'] = '1.1'
      ..['spaceId'] = 'space-1'
      ..['stream'] = {'kind': 'space', 'id': 'space-1'};
    expect(store.handle(event, threadId: 'thread-1'), isTrue);
    expect(store.forAssignment('assignment-1').single.title,
        'Running repository checks');
  });
  test('deduplicates replay and updates the matching tool row', () {
    final store = AxWorkActivityStore();
    expect(
      store.handle(
        activityEvent(
          eventId: 'started',
          streamSequence: 4,
          activitySequence: 1,
          type: 'tool.started',
          status: 'running',
        ),
        threadId: 'thread-1',
      ),
      isTrue,
    );
    expect(
      store.handle(
        activityEvent(
          eventId: 'completed',
          streamSequence: 5,
          activitySequence: 2,
          type: 'tool.completed',
          status: 'completed',
          title: 'Repository checks completed',
        ),
        threadId: 'thread-1',
      ),
      isTrue,
    );
    expect(
      store.handle(
        activityEvent(
          eventId: 'completed',
          streamSequence: 5,
          activitySequence: 2,
          type: 'tool.completed',
          status: 'completed',
          title: 'Repository checks completed',
        ),
        threadId: 'thread-1',
      ),
      isFalse,
    );

    final activities = store.forAssignment('assignment-1');
    expect(activities, hasLength(1));
    expect(activities.single.status, 'completed');
    expect(activities.single.title, 'Repository checks completed');
  });

  test('drops reordered older realtime updates without regressing activity',
      () {
    final store = AxWorkActivityStore();
    expect(
      store.handle(
        activityEvent(
          eventId: 'completed-first',
          streamSequence: 5,
          activitySequence: 2,
          type: 'tool.completed',
          status: 'completed',
          title: 'Repository checks completed',
        ),
        threadId: 'thread-1',
      ),
      isTrue,
    );
    expect(
      store.handle(
        activityEvent(
          eventId: 'started-late',
          streamSequence: 4,
          activitySequence: 1,
          type: 'tool.started',
          status: 'running',
        ),
        threadId: 'thread-1',
      ),
      isFalse,
    );
    expect(store.forAssignment('assignment-1'), hasLength(1));
    expect(store.forAssignment('assignment-1').single.status, 'completed');
  });

  test('fences delayed activity from a previous retry', () {
    final store = AxWorkActivityStore();
    expect(
      store.handle(
        activityEvent(
          eventId: 'attempt-1-start',
          streamSequence: 1,
          activitySequence: 1,
          type: 'execution.started',
          status: 'running',
          attemptId: 'attempt-1',
        ),
        threadId: 'thread-1',
      ),
      isTrue,
    );
    expect(
      store.handle(
        activityEvent(
          eventId: 'attempt-2-start',
          streamSequence: 2,
          activitySequence: 1,
          type: 'execution.started',
          status: 'running',
          attemptId: 'attempt-2',
          title: 'Retry started',
        ),
        threadId: 'thread-1',
      ),
      isTrue,
    );
    expect(
      store.handle(
        activityEvent(
          eventId: 'late-old-tool',
          streamSequence: 3,
          activitySequence: 2,
          type: 'tool.started',
          status: 'running',
          attemptId: 'attempt-1',
          title: 'Old attempt tool',
        ),
        threadId: 'thread-1',
      ),
      isFalse,
    );
    expect(store.forAssignment('assignment-1').map((item) => item.attemptId),
        ['attempt-2']);
  });

  test('ignores activity from another Thread and keeps a bounded timeline', () {
    final store = AxWorkActivityStore();
    expect(
      store.handle(
        activityEvent(
          eventId: 'other-thread',
          streamSequence: 1,
          activitySequence: 1,
          type: 'tool.started',
          status: 'running',
        )..['threadId'] = 'thread-2',
        threadId: 'thread-1',
      ),
      isFalse,
    );
    for (var index = 0; index < 520; index++) {
      store.handle(
        activityEvent(
          eventId: 'event-$index',
          streamSequence: index + 1,
          activitySequence: index + 1,
          type: 'model.started',
          status: 'running',
          activityId: 'activity-$index',
          title: 'Worker update $index',
        ),
        threadId: 'thread-1',
      );
    }
    expect(store.forAssignment('assignment-1'), hasLength(512));
  });

  test('projects bounded Cloud history for the matching Work assignment', () {
    final store = AxWorkActivityStore();
    final request = AxWorkRequest.fromJson({
      'id': 'request-1',
      'prompt': 'inspect the repository',
      'workflowId': 'direct',
      'workflowVersion': 1,
      'status': 'running',
      'createdAt': '2026-10-12T18:00:00Z',
      'requestedByName': 'Team member',
      'steps': [
        {
          'kind': 'implement',
          'status': 'running',
          'assignmentId': 'assignment-1',
          'workerId': 'worker-1',
        },
      ],
      'activities': [
        {
          'eventId': 'history-1',
          'assignmentId': 'assignment-1',
          'attemptId': 'attempt-1',
          'executionId': 'execution-1',
          'workerId': 'worker-1',
          'activitySequence': 1,
          'activityType': 'tool.started',
          'activityStatus': 'running',
          'activityId': 'call-view',
          'toolName': 'view',
          'details': {'toolName': 'view'},
          'title': 'Using a tool',
          'timestamp': '2026-10-12T18:00:01Z',
        },
        {
          'eventId': 'history-2',
          'assignmentId': 'assignment-1',
          'attemptId': 'attempt-1',
          'executionId': 'execution-1',
          'workerId': 'worker-1',
          'activitySequence': 2,
          'activityType': 'tool.completed',
          'activityStatus': 'completed',
          'activityId': 'call-view',
          'title': 'Tool finished',
          'timestamp': '2026-10-12T18:00:02Z',
        },
      ],
    });

    final activities = store.forRequest(request);
    expect(activities, hasLength(1));
    expect(activities.single.eventId, 'history-2');
    expect(activities.single.title, 'Tool finished');
    expect(activities.single.toolName, 'view');
    expect(activities.single.details, {'toolName': 'view'});
  });

  testWidgets('ticks the current time once a second only while active',
      (tester) async {
    var now = DateTime.utc(2026, 10, 13, 12);
    var active = true;
    late StateSetter setOuter;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return AxLiveTicker(
              active: active,
              clock: () => now,
              builder: (context, value) => Text('t=${value.second}'),
            );
          },
        ),
      ),
    );
    expect(find.text('t=0'), findsOneWidget);

    now = now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('t=3'), findsOneWidget);

    setOuter(() => active = false);
    await tester.pump();
    now = now.add(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 2));
    // Inactive tickers no longer follow the clock.
    expect(find.text('t=3'), findsOneWidget);
    expect(find.text('t=8'), findsNothing);
  });

  AxWorkRequest requestFor(String assignmentId) => AxWorkRequest(
        id: 'request-$assignmentId',
        requestedByName: 'Team member',
        prompt: 'inspect',
        workflowId: 'direct',
        workflowVersion: 1,
        status: 'running',
        createdAt: '2026-10-12T18:00:00Z',
        steps: [
          AxWorkRequestStep(
            kind: 'implement',
            status: 'running',
            workerId: 'worker-1',
            assignmentId: assignmentId,
          ),
        ],
      );

  test('notifies only the request whose assignment received activity', () {
    final store = AxWorkActivityStore();
    var first = 0;
    var second = 0;
    store.listenableForRequest(requestFor('assignment-1')).addListener(
          () => first++,
        );
    store.listenableForRequest(requestFor('assignment-2')).addListener(
          () => second++,
        );

    store.handle(
      activityEvent(
        eventId: 'a',
        streamSequence: 1,
        activitySequence: 1,
        type: 'tool.started',
        status: 'running',
      ),
      threadId: 'thread-1',
    );

    expect(first, 1);
    expect(second, 0);
  });

  testWidgets('coalesces bursts of replaceable status updates', (tester) async {
    final store = AxWorkActivityStore();
    var notified = 0;
    store.listenableForRequest(requestFor('assignment-1')).addListener(
          () => notified++,
        );
    for (var index = 1; index <= 5; index++) {
      store.handle(
        activityEvent(
          eventId: 'status-$index',
          streamSequence: index,
          activitySequence: index,
          type: 'model.status',
          status: 'updated',
          activityId: 'status',
          title: 'Thinking $index',
        ),
        threadId: 'thread-1',
      );
    }
    expect(notified, 1);
    await tester.pump(const Duration(milliseconds: 300));
    expect(notified, 2);
    expect(store.forAssignment('assignment-1').single.title, 'Thinking 5');
  });

  test('keeps the narration row when a thinking status follows it', () {
    final store = AxWorkActivityStore();
    store.handle(
      activityEvent(
        eventId: 'narration-1',
        streamSequence: 1,
        activitySequence: 1,
        type: 'message.updated',
        status: 'updated',
        activityId: 'claude-msg-1',
        title: 'Step 1: listing files',
      ),
      threadId: 'thread-1',
    );
    store.handle(
      activityEvent(
        eventId: 'thinking-1',
        streamSequence: 2,
        activitySequence: 2,
        type: 'model.status',
        status: 'updated',
        activityId: 'thinking',
        title: 'Thinking',
      ),
      threadId: 'thread-1',
    );
    store.handle(
      activityEvent(
        eventId: 'narration-2',
        streamSequence: 3,
        activitySequence: 3,
        type: 'message.updated',
        status: 'updated',
        activityId: 'claude-msg-2',
        title: 'Step 2: reading the README',
      ),
      threadId: 'thread-1',
    );
    final rows = store.forAssignment('assignment-1');
    expect(rows.map((row) => row.title), [
      'Thinking',
      'Step 2: reading the README',
    ]);
  });

  test('a profile milestone does not overwrite a narration row', () {
    final store = AxWorkActivityStore();
    store.handle(
      activityEvent(
        eventId: 'narration-1',
        streamSequence: 0,
        activitySequence: 1,
        type: 'message.updated',
        status: 'updated',
        activityId: 'codex-msg-1',
        title: 'Reading the config',
        preview: 'Reading the config',
      ),
      threadId: 'thread-1',
    );
    store.handle(
      activityEvent(
        eventId: 'milestone-1',
        streamSequence: 0,
        activitySequence: 2,
        type: 'message.updated',
        status: 'updated',
        activityId: 'milestone',
        title: 'provider_response_received',
      ),
      threadId: 'thread-1',
    );
    expect(
      store.forAssignment('assignment-1').map((row) => row.title).toSet(),
      {'Reading the config', 'provider_response_received'},
    );
  });

  test('estimates clock skew from live events and ignores late replays', () {
    // Event timestamp is 18:00:01 UTC; the device clock reads 18:00:04.
    final skewed = AxWorkActivityStore(
      clock: () => DateTime.utc(2026, 10, 12, 18, 0, 4),
    );
    skewed.handle(
      activityEvent(
        eventId: 'live',
        streamSequence: 1,
        activitySequence: 1,
        type: 'tool.started',
        status: 'running',
      ),
      threadId: 'thread-1',
    );
    expect(
      skewed.clockOffsetForRequest(requestFor('assignment-1')),
      const Duration(seconds: 3),
    );

    final replayed = AxWorkActivityStore(
      clock: () => DateTime.utc(2026, 10, 12, 19),
    );
    replayed.handle(
      activityEvent(
        eventId: 'replay',
        streamSequence: 1,
        activitySequence: 1,
        type: 'tool.started',
        status: 'running',
      ),
      threadId: 'thread-1',
    );
    expect(
      replayed.clockOffsetForRequest(requestFor('assignment-1')),
      Duration.zero,
    );
  });
}
