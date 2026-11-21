import 'dart:async';

import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_design/syntila_design.dart';

import 'ax_fixture_data.dart';

Map<String, dynamic> activity(
  String thread,
  int sequence, {
  String? title,
  String? toolName,
  String type = 'tool.completed',
  String status = 'completed',
  String? activityId,
}) =>
    {
      'eventId': '$thread-event-$sequence',
      'assignmentId': '$thread-assignment',
      'attemptId': '$thread-attempt',
      'executionId': '$thread-execution',
      'workerId': 'worker',
      'activityId': activityId ?? 'call-$thread-$sequence',
      'activitySequence': sequence,
      'activityType': type,
      'activityStatus': status,
      'title': title ?? '$thread operation $sequence',
      if (toolName != null) 'toolName': toolName,
      if (toolName != null) 'details': {'toolName': toolName},
      'timestamp': '2026-10-17T10:00:0${sequence}Z',
    };

class ActivitySource extends AxFixtureDataSource {
  final histories = <String, List<Map<String, dynamic>>>{'a': [], 'b': []};
  final details = <String>[];

  AxWorkRequest request(String thread) => AxWorkRequest(
        id: thread,
        requestedByName: 'You',
        prompt: 'Work in $thread',
        workflowId: 'direct',
        workflowVersion: 2,
        status: 'running',
        createdAt: '2026-10-17T10:00:00Z',
        steps: [
          AxWorkRequestStep(
              kind: 'implement',
              status: 'running',
              workerId: 'worker',
              assignmentId: '$thread-assignment'),
        ],
      );

  @override
  Future<List<AxWorkRequest>> workRequestRows(
          {required String threadId, bool activeOnly = false}) async =>
      [request(threadId)];

  @override
  Future<AxWorkRequestStatus> loadWorkRequest(
      {required String workRequestId}) async {
    details.add(workRequestId);
    return AxWorkRequestStatus(
        id: workRequestId,
        threadId: workRequestId,
        status: 'running',
        steps: request(workRequestId).steps,
        activityHistory: List.of(histories[workRequestId]!));
  }
}

void main() {
  testWidgets('shows a transient Space activity action in the conversation',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'space',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'a',
          spaceId: 'space',
          name: 'a',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: ActivitySource(),
      realtimeEvents: events.stream,
      onBackToSpace: () {},
      onArchive: () {},
    ))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    events.add({
      'eventId': 'live-event',
      'type': 'assignment.activity',
      'version': '1.1',
      'timestamp': '2026-10-17T10:00:01Z',
      'sequence': 0,
      'spaceId': 'space',
      'threadId': 'a',
      'stream': {'kind': 'space', 'id': 'space'},
      'assignmentId': 'a-assignment',
      'attemptId': 'a-attempt',
      'payload': {
        'entityId': 'a-assignment',
        'workerId': 'chatgpt',
        'sourceEventId': 'source',
        'executionId': 'execution',
        'activitySequence': 1,
        'activityType': 'tool.started',
        'activityStatus': 'running',
        'title': 'Searching the web',
        'toolName': 'web_search',
      },
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Searching the web · Web search'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'Conversation shows live Worker activity and keeps own requests right',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = ActivitySource();
    data.histories['a']!.add(activity('a', 1));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'p', name: 'Space', branch: '', lastActivity: '', role: 'owner'),
      thread: const AxThread(
          id: 'a',
          spaceId: 'p',
          name: 'a',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: data,
      // List rows identify the requester by name only.
      currentUserName: 'You',
      onBackToSpace: () {},
      onArchive: () {},
    ))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final conversation = find.byKey(const ValueKey('chat-history-scroll'));
    expect(find.byKey(const ValueKey('work-history-scroll')), findsNothing);
    // The live Work card, with its activity trail, is in the Conversation.
    expect(
        find.descendant(of: conversation, matching: find.text('a operation 1')),
        findsOneWidget);
    final prompt = find.descendant(
        of: conversation,
        matching: find.textContaining('Work in a', findRichText: true));
    // Own requests sit in a right-aligned bubble; the text inside it reads
    // left to right.
    final bubble = find
        .ancestor(
            of: prompt.first,
            matching: find.byWidgetPredicate((widget) =>
                widget is DecoratedBox &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).color ==
                    SyntilaColors.ownMessageBackground(false)))
        .first;
    final bubbleRect = tester.getRect(bubble);
    final conversationRect = tester.getRect(conversation);
    expect(bubbleRect.right, greaterThan(conversationRect.center.dx));
    expect(conversationRect.right - bubbleRect.right,
        lessThan(bubbleRect.left - conversationRect.left));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('switching concurrent running threads restores prior operations',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = ActivitySource();
    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);

    Future<void> open(String id, {bool replacePage = false}) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
        key: replacePage ? ValueKey(id) : null,
        space: const AxSpace(
            id: 'space',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: AxThread(
            id: id,
            spaceId: 'space',
            name: id,
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: ''),
        dataSource: data,
        realtimeEvents: events.stream,
        onBackToSpace: () {},
        onArchive: () {},
      ))));
      // Running activity animates continuously, so pump fixed frames.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    Finder inConversation(Finder finder) => find.descendant(
        of: find.byKey(const ValueKey('chat-history-scroll')),
        matching: finder);

    void completeOperation(
      String id,
      int sequence, {
      String? title,
      String? toolName,
    }) {
      final rows = [
        if (toolName != null)
          activity(
            id,
            sequence * 2 - 1,
            title: 'Using a tool',
            toolName: toolName,
            type: 'tool.started',
            status: 'running',
            activityId: 'call-$id-$sequence',
          ),
        activity(
          id,
          sequence * 2,
          title: title ?? '$id operation $sequence',
          activityId: 'call-$id-$sequence',
        ),
      ];
      data.histories[id]!.addAll(rows);
      for (final row in rows) {
        events.add({
          'type': 'assignment.activity',
          'threadId': id,
          'assignmentId': row['assignmentId'],
          'attemptId': row['attemptId'],
          'eventId': row['eventId'],
          'sequence': row['activitySequence'],
          'timestamp': row['timestamp'],
          'payload': row,
        });
      }
    }

    await open('a');
    completeOperation('a', 1, title: 'Tool finished', toolName: 'view');
    await tester.pump();
    expect(inConversation(find.text('Tool finished · view')), findsOneWidget);
    await open('b');
    expect(inConversation(find.text('Tool finished · view')), findsNothing);
    completeOperation('b', 1);
    completeOperation('a', 2); // Arrives while the other Thread is visible.
    await tester.pump();
    expect(inConversation(find.text('b operation 1')), findsOneWidget);
    await open('a');
    expect(inConversation(find.text('Tool finished · view')), findsOneWidget);
    expect(inConversation(find.text('a operation 2')), findsOneWidget);
    expect(inConversation(find.text('b operation 1')), findsNothing);
    await open('b', replacePage: true); // Also cover disposed/recreated pages.
    expect(inConversation(find.text('b operation 1')), findsOneWidget);
    expect(inConversation(find.text('a operation 1')), findsNothing);
    await open('a', replacePage: true);
    expect(inConversation(find.text('Tool finished · view')), findsOneWidget);
    expect(inConversation(find.text('Using a tool · view')), findsNothing);
    expect(inConversation(find.text('a operation 2')), findsOneWidget);
    expect(data.details, containsAll(['a', 'b']));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
