import 'package:flutter_test/flutter_test.dart';

import 'package:syntila_app/src/notifications/notification_models.dart';

void main() {
  test('only the latest failure per Thread survives out of order events', () {
    AxNotification event(String id, String? thread, String time,
            {String type = 'thread.failed'}) =>
        notificationFromRealtimeEvent({
          'eventId': id,
          'type': type,
          'threadId': thread,
          'timestamp': time,
        })!;
    final result = latestThreadFailures([
      event('new', 't1', '2026-10-03T00:00:00Z'),
      event('old', 't1', '2026-10-01T00:00:00Z'),
      event('other', 't2', '2026-10-02T00:00:00Z'),
      event('input', 't1', '2026-10-01T00:00:00Z', type: 'thread.needs_input'),
      event('unknown1', null, '2026-10-01T00:00:00Z'),
      event('unknown2', null, '2026-10-02T00:00:00Z'),
    ]);
    expect(result.map((n) => n.id),
        containsAll(['new', 'other', 'input', 'unknown1', 'unknown2']));
    expect(result.map((n) => n.id), isNot(contains('old')));
  });

  test('only meaningful realtime states create notifications', () {
    expect(isMeaningfulRealtimeNotification('thread.needs_input'), isTrue);
    expect(isMeaningfulRealtimeNotification('thread.completed'), isTrue);
    expect(
        isMeaningfulRealtimeNotification('thread.recovery.required'), isTrue);
    expect(isMeaningfulRealtimeNotification('workflow_run.completed'), isTrue);
    expect(
        isMeaningfulRealtimeNotification('space.invitation.received'), isTrue);
    expect(isMeaningfulRealtimeNotification('discussion.message.created'),
        isFalse);
    expect(isMeaningfulRealtimeNotification('thread.lease.status'), isFalse);
  });

  test('completed Workflow Runs and Threads are not announced', () {
    for (final type in [
      'workflow_run.completed',
      'run.completed',
      'assignment.completed',
      'thread.completed',
      'work_request.completed',
    ]) {
      expect(
        notificationFromRealtimeEvent({
          'eventId': 'e-$type',
          'type': type,
          'spaceId': 'space-1',
          'payload': {'summary': 'Done.', 'threadId': 't'},
        }),
        isNull,
        reason: type,
      );
    }
  });

  test('maps Thread input events to normalized thread notification', () {
    final notification = notificationFromRealtimeEvent({
      'eventId': 'event-ws-1',
      'type': 'thread.needs_input',
      'spaceId': 'space-1',
      'threadId': 'ws-auth',
      'payload': {'prompt': 'Approve OAuth provider selection.'},
    });

    expect(notification, isNotNull);
    expect(notification!.kind, AxNotificationKind.threadNeedsInput);
    expect(notification.title, 'Thread needs input');
    expect(notification.message, 'Approve OAuth provider selection.');
    expect(notification.spaceId, 'space-1');
    expect(notification.threadId, 'ws-auth');
    expect(notification.target, AxNotificationTarget.thread);
    expect(notification.priority, AxNotificationPriority.high);
  });

  test('maps approval events and ignores progress', () {
    final notification = notificationFromRealtimeEvent({
      'eventId': 'event-2',
      'type': 'workflow_run.approval_required',
      'runId': 'run-2',
      'payload': {'prompt': 'Choose the deployment target.'},
    });
    expect(notification?.kind, AxNotificationKind.workflowRunNeedsApproval);
    expect(notification?.message, 'Choose the deployment target.');
    expect(
      notificationFromRealtimeEvent({'type': 'assignment.activity'}),
      isNull,
    );
  });

  test(
      'maps operational attention events to prioritized normalized destinations',
      () {
    final events = <Map<String, dynamic>>[
      {'type': 'workspace.offline'},
      {
        'type': 'worker.credential.expired',
        'payload': {'workspaceId': 'workspace-1', 'workerId': 'worker-1'},
      },
      {
        'type': 'worker.install.failed',
        'payload': {'workspace_id': 'workspace-2', 'worker_id': 'worker-2'},
      },
      {'type': 'space.invitation.received'},
    ];
    final notifications = events
        .map(notificationFromRealtimeEvent)
        .whereType<AxNotification>()
        .toList();

    expect(notifications.map((item) => item.title), [
      'Workspace offline',
      'Worker connection expired',
      'Worker connection failed',
      'Invitation received',
    ]);
    expect(notifications[0].target, AxNotificationTarget.workspaces);
    expect(notifications[0].kind, AxNotificationKind.workspaceOffline);

    expect(notifications[1].priority, AxNotificationPriority.high);
    expect(notifications[1].target, AxNotificationTarget.workspace);
    expect(notifications[1].kind, AxNotificationKind.workerCredentialProblem);
    expect(notifications[1].workspaceId, 'workspace-1');
    expect(notifications[1].workerId, 'worker-1');

    expect(notifications[2].target, AxNotificationTarget.workspace);
    expect(notifications[2].kind, AxNotificationKind.workerInstallFailed);
    expect(notifications[2].workspaceId, 'workspace-2');
    expect(notifications[2].workerId, 'worker-2');

    expect(notifications[3].target, AxNotificationTarget.space);
    expect(notifications[3].kind, AxNotificationKind.spaceInvitationReceived);
  });

  test('failed Work Requests notify on their Thread', () {
    final done = notificationFromRealtimeEvent({
      'eventId': 'e-done',
      'type': 'work_request.completed',
      'spaceId': 'space-1',
      'payload': {'workRequestId': 'wr-1', 'threadId': 'thread-1'},
    });
    expect(done, isNull);
    final failed = notificationFromRealtimeEvent({
      'eventId': 'e-fail',
      'type': 'work_request.failed',
      'spaceId': 'space-1',
      'payload': {'threadId': 'thread-1'},
    });
    expect(failed!.kind, AxNotificationKind.threadFailed);
    expect(failed.priority, AxNotificationPriority.high);
    expect(isMeaningfulRealtimeNotification('work_request.completed'), isTrue);
    expect(notificationFromRealtimeEvent({'type': 'work_request.started'}),
        isNull);
  });

  test('feed items share ids with live events and keep read state', () {
    final feed = notificationsFromFeed([
      {
        'id': 'wr-1',
        'type': 'work_request.completed',
        'spaceId': 'space-1',
        'threadId': 'thread-1',
        'timestamp': '2026-10-01T10:00:00Z',
        'read': true,
      },
      {
        'id': 'wr-2',
        'type': 'work_request.failed',
        'spaceId': 'space-1',
        'threadId': 'thread-2',
        'timestamp': '2026-10-01T11:00:00Z',
        'read': false,
      },
    ]);
    expect(feed.map((n) => n.id), ['work-request:wr-2']);
    expect(feed.map((n) => n.read), [false]);
    final live = notificationFromRealtimeEvent({
      'eventId': 'other',
      'type': 'work_request.failed',
      'payload': {'workRequestId': 'wr-2', 'threadId': 'thread-2'},
    });
    expect(live!.id, feed.first.id);
  });

  test('withPlace names the Space and Thread once', () {
    final n = notificationFromRealtimeEvent({
      'type': 'thread.failed',
      'spaceId': 's',
      'threadId': 't',
      'timestamp': '2026-01-01T00:00:00Z',
    })!;
    final placed = n.withPlace('Docs › Fix login');
    expect(n.message, isEmpty);
    expect(placed.message, 'Docs › Fix login');
    expect(placed.withPlace('Docs › Fix login').message, placed.message);
    expect(n.withPlace(null).message, n.message);
  });
}
