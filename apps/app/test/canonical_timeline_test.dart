import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/sync/ax_discussion_cache.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/ax/sync/ax_work_history.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';

import 'ax_fixture_data.dart';

class _CanonicalTimelineDataSource extends AxFixtureDataSource {
  _CanonicalTimelineDataSource({
    required this.timelineMessages,
    required this.workRequests,
  });

  final List<AxDiscussionMessage> timelineMessages;
  final List<AxWorkRequest> workRequests;

  @override
  Future<AxDiscussionPage> loadDiscussionPage({
    required String threadId,
    int limit = 50,
    String? before,
    String? after,
  }) async =>
      AxDiscussionPage(
        messages: timelineMessages,
        nextCursor: null,
        newestCursor: timelineMessages.isEmpty ? null : 'cur-newest',
      );

  @override
  Future<AxWorkRequestPage> loadThreadWorkRequestPage({
    required String threadId,
    int limit = 50,
    String? beforeCreatedAt,
    String? beforeId,
    bool activeOnly = false,
  }) async =>
      AxWorkRequestPage(
        requests: workRequests,
        nextCursor: null,
      );
}

void main() {
  testWidgets(
      'canonical timeline renders completed, failed, retried, and live requests once without duplicates',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const space = AxSpace(
      id: 'space-1',
      name: 'Engineering',
      branch: 'main',
      lastActivity: 'now',
      role: 'owner',
    );
    const thread = AxThread(
      id: 'thread-1',
      spaceId: 'space-1',
      name: 'General',
      lead: 'Alice',
      status: 'active',
      brief: '',
      primaryWorkspace: '',
      queueStatus: 'Idle',
      canExecuteWork: true,
    );

    final timelineMessages = [
      const AxDiscussionMessage(
        id: 'msg-1',
        threadId: 'thread-1',
        authorUserId: 'user-1',
        authorName: 'Alice',
        body: 'Starting the release check.',
        createdAt: '2026-11-24T10:00:00Z',
        isMe: true,
      ),
      // 1. Completed request + answer
      const AxDiscussionMessage(
        id: 'ai-req-completed',
        threadId: 'thread-1',
        authorUserId: 'user-1',
        authorName: 'Alice',
        body: 'Summarize the changelog',
        createdAt: '2026-11-24T10:01:00Z',
        isMe: true,
        kind: 'ai_request',
        workRequestId: 'wr-completed',
      ),
      const AxDiscussionMessage(
        id: 'ai-ans-completed',
        threadId: 'thread-1',
        authorUserId: 'actor-worker-1',
        authorName: 'Codex',
        body: 'Changelog summary ready.',
        createdAt: '2026-11-24T10:01:10Z',
        kind: 'ai_answer',
        workRequestId: 'wr-completed',
        workerDisplayName: 'Codex',
      ),
      // 2. Failed request + outcome
      const AxDiscussionMessage(
        id: 'ai-req-failed',
        threadId: 'thread-1',
        authorUserId: 'user-1',
        authorName: 'Alice',
        body: 'Deploy to staging',
        createdAt: '2026-11-24T10:02:00Z',
        isMe: true,
        kind: 'ai_request',
        workRequestId: 'wr-failed',
      ),
      const AxDiscussionMessage(
        id: 'ai-out-failed',
        threadId: 'thread-1',
        authorUserId: 'actor-worker-1',
        authorName: 'Codex',
        body: 'Staging deploy failed: missing secret.',
        createdAt: '2026-11-24T10:02:05Z',
        kind: 'ai_answer',
        workRequestId: 'wr-failed',
        workerDisplayName: 'Codex',
      ),
      // 3. Retried request + final answer
      const AxDiscussionMessage(
        id: 'ai-req-retried',
        threadId: 'thread-1',
        authorUserId: 'user-1',
        authorName: 'Alice',
        body: 'Run integration tests',
        createdAt: '2026-11-24T10:03:00Z',
        isMe: true,
        kind: 'ai_request',
        workRequestId: 'wr-retried',
      ),
      const AxDiscussionMessage(
        id: 'ai-ans-retried',
        threadId: 'thread-1',
        authorUserId: 'actor-worker-1',
        authorName: 'Codex',
        body: 'Integration tests passed on retry.',
        createdAt: '2026-11-24T10:03:20Z',
        kind: 'ai_answer',
        workRequestId: 'wr-retried',
        workerDisplayName: 'Codex',
      ),
      // 4. Live running request
      const AxDiscussionMessage(
        id: 'ai-req-live',
        threadId: 'thread-1',
        authorUserId: 'user-1',
        authorName: 'Alice',
        body: 'Check bundle size',
        createdAt: '2026-11-24T10:04:00Z',
        isMe: true,
        kind: 'ai_request',
        workRequestId: 'wr-live',
      ),
    ];

    final workRequests = [
      AxWorkRequest.fromJson(const {
        'id': 'wr-completed',
        'workflowId': 'chat',
        'prompt': 'Summarize the changelog',
        'status': 'completed',
        'createdAt': '2026-11-24T10:01:00Z',
        'updatedAt': '2026-11-24T10:01:10Z',
        'responseText': 'Changelog summary ready.',
      }),
      AxWorkRequest.fromJson(const {
        'id': 'wr-failed',
        'workflowId': 'direct',
        'prompt': 'Deploy to staging',
        'status': 'failed',
        'createdAt': '2026-11-24T10:02:00Z',
        'updatedAt': '2026-11-24T10:02:05Z',
        'errorMessage': 'Staging deploy failed: missing secret.',
      }),
      AxWorkRequest.fromJson(const {
        'id': 'wr-retried',
        'workflowId': 'direct',
        'prompt': 'Run integration tests',
        'status': 'completed',
        'createdAt': '2026-11-24T10:03:00Z',
        'updatedAt': '2026-11-24T10:03:20Z',
        'responseText': 'Integration tests passed on retry.',
      }),
      AxWorkRequest.fromJson(const {
        'id': 'wr-live',
        'workflowId': 'direct',
        'prompt': 'Check bundle size',
        'status': 'running',
        'createdAt': '2026-11-24T10:04:00Z',
        'updatedAt': '2026-11-24T10:04:02Z',
      }),
    ];

    final dataSource = _CanonicalTimelineDataSource(
      timelineMessages: timelineMessages,
      workRequests: workRequests,
    );
    final engine = AxSyncEngine();
    final discussionCache = AxDiscussionCache(dataSource, engine: engine);
    final workHistoryCache = AxWorkHistoryCache(dataSource, engine: engine);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThreadPage(
          space: space,
          thread: thread,
          dataSource: dataSource,
          discussionCache: discussionCache,
          workHistoryCache: workHistoryCache,
          currentUserId: 'user-1',
          currentUserName: 'Alice',
          onBackToSpace: () {},
          onArchive: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Human message renders once.
    expect(find.text('Starting the release check.'), findsOneWidget);
    // Completed request + answer render once each (not duplicated by work history).
    expect(find.text('Summarize the changelog'), findsOneWidget);
    expect(find.text('Changelog summary ready.'), findsOneWidget);
    // Failed request + outcome render once each.
    expect(find.text('Deploy to staging'), findsOneWidget);
    expect(find.text('Staging deploy failed: missing secret.'), findsOneWidget);
    // Retried request + answer render once each.
    expect(find.text('Run integration tests'), findsOneWidget);
    expect(find.text('Integration tests passed on retry.'), findsOneWidget);
    // Running request renders its live status card once at its ai_request item.
    expect(find.text('Check bundle size'), findsOneWidget);
  });
}
