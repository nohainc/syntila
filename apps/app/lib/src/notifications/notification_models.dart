enum AxNotificationKind {
  // Thread
  threadNeedsInput,
  threadCompleted,
  threadFailed,

  // Workflow Run
  workflowRunCompleted,
  workflowRunFailed,
  workflowRunNeedsApproval,

  // Worker
  workerCredentialProblem,
  workerInstallFailed,

  // Workspace
  workspaceOffline,

  // Space
  spaceInvitationReceived,

  // Backwards-compatibility aliases
  completed,
  failed,
  approvalRequired,
  invitationReceived,
}

enum AxNotificationPriority { high, normal, low }

enum AxNotificationTarget {
  thread,
  space,
  workflowRun,
  run,
  workspaces,
  workspace,
}

/// Filters realtime noise from actionable team notifications. Progress,
/// discussion, queue, and lease updates update read models but do
/// not interrupt the user.
bool isMeaningfulRealtimeNotification(String type) => {
      'run.input_required',
      'run.approval_required',
      'workflow_run.input_required',
      'workflow_run.approval_required',
      'work_request.completed',
      'work_request.failed',
      'thread.needs_input',
      'thread.completed',
      'thread.failed',
      'thread.account.problem',
      'thread.grant.problem',
      'thread.recovery.required',
      'run.completed',
      'run.failed',
      'workflow_run.completed',
      'workflow_run.failed',
      'assignment.failed',
      'assignment.completed',
      'account.expired',
      'credential.expired',
      'worker.credential.expired',
      'worker.install.failed',
      'worker.install_failed',
      'workspace.offline',
      'workspace.stale',
      'workspace.invitation.received',
      'space.invitation.received',
      'invitation.received',
    }.contains(type);

class AxNotification {
  const AxNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.message,
    required this.createdAt,
    required this.priority,
    this.spaceId,
    this.threadId,
    this.runId,
    this.workspaceId,
    this.workerId,
    this.target,
    this.read = false,
  });

  final String id;
  final AxNotificationKind kind;
  final String title;
  final String message;
  final DateTime createdAt;
  final AxNotificationPriority priority;
  final String? spaceId;
  final String? threadId;
  final String? runId;
  final String? workspaceId;
  final String? workerId;
  final AxNotificationTarget? target;
  final bool read;

  /// Prefixes the message with where this happened (e.g. "Space › Thread"), so
  /// a generic "failed" says which Space and Thread it concerns.
  AxNotification withPlace(String? place) {
    if (place == null ||
        place.isEmpty ||
        message == place ||
        message.startsWith('$place · ')) {
      return this;
    }
    return AxNotification(
      id: id,
      kind: kind,
      title: title,
      message: message.isEmpty ? place : '$place · $message',
      createdAt: createdAt,
      priority: priority,
      spaceId: spaceId,
      threadId: threadId,
      runId: runId,
      workspaceId: workspaceId,
      workerId: workerId,
      target: target,
      read: read,
    );
  }

  AxNotification markRead() => AxNotification(
        id: id,
        kind: kind,
        title: title,
        message: message,
        createdAt: createdAt,
        priority: priority,
        spaceId: spaceId,
        threadId: threadId,
        runId: runId,
        workspaceId: workspaceId,
        workerId: workerId,
        target: target,
        read: true,
      );
}

AxNotification? notificationFromRealtimeEvent(
  Map<String, dynamic> event, {
  String? viewerId,
}) {
  final type = event['type'];
  if (type is! String) return null;
  final kind = switch (type) {
    'thread.needs_input' => AxNotificationKind.threadNeedsInput,
    'thread.completed' ||
    'work_request.completed' =>
      AxNotificationKind.threadCompleted,
    'work_request.failed' ||
    'thread.failed' ||
    'thread.grant.problem' ||
    'thread.recovery.required' =>
      AxNotificationKind.threadFailed,
    'workflow_run.completed' => AxNotificationKind.workflowRunCompleted,
    'run.completed' ||
    'assignment.completed' =>
      AxNotificationKind.workflowRunCompleted,
    'workflow_run.failed' => AxNotificationKind.workflowRunFailed,
    'run.failed' ||
    'task.failed' ||
    'assignment.failed' =>
      AxNotificationKind.workflowRunFailed,
    'workflow_run.approval_required' ||
    'workflow_run.input_required' =>
      AxNotificationKind.workflowRunNeedsApproval,
    'run.input_required' ||
    'run.approval_required' =>
      AxNotificationKind.workflowRunNeedsApproval,
    'thread.account.problem' ||
    'account.expired' ||
    'credential.expired' ||
    'worker.credential.expired' ||
    'worker.credential.problem' ||
    'worker.credential.error' ||
    'worker.problem' ||
    'worker.error' =>
      AxNotificationKind.workerCredentialProblem,
    'workspace.offline' ||
    'workspace.stale' =>
      AxNotificationKind.workspaceOffline,
    'worker.install.failed' ||
    'worker.install_failed' =>
      AxNotificationKind.workerInstallFailed,
    'space.invitation.received' ||
    'workspace.invitation.received' ||
    'invitation.received' =>
      AxNotificationKind.spaceInvitationReceived,
    _ => null,
  };
  if (kind == null) return null;

  final payload = event['payload'];
  final payloadMap = payload is Map
      ? Map<String, dynamic>.from(payload)
      : const <String, dynamic>{};
  // Successful completions are not announced; only input requests, failures
  // and problems reach the Notification Center.
  if (kind == AxNotificationKind.threadCompleted ||
      kind == AxNotificationKind.workflowRunCompleted) {
    return null;
  }
  final runId =
      _optionalString(event['runId']) ?? _optionalString(payloadMap['runId']);
  final spaceId = _optionalString(event['spaceId']) ??
      _optionalString(payloadMap['spaceId']);
  final threadId = _optionalString(event['threadId']) ??
      _optionalString(event['thread_id']) ??
      _optionalString(payloadMap['threadId']) ??
      _optionalString(payloadMap['thread_id']);
  final workspaceId = _optionalString(event['workspaceId']) ??
      _optionalString(event['workspace_id']) ??
      _optionalString(payloadMap['workspaceId']) ??
      _optionalString(payloadMap['workspace_id']);
  final workerId = _optionalString(event['workerId']) ??
      _optionalString(event['worker_id']) ??
      _optionalString(payloadMap['workerId']) ??
      _optionalString(payloadMap['worker_id']);
  final message = _optionalString(payloadMap['prompt']) ??
      _optionalString(payloadMap['summary']) ??
      _optionalString(payloadMap['error']) ??
      '';
  final timestamp =
      DateTime.tryParse(_optionalString(event['timestamp']) ?? '')?.toLocal() ??
          DateTime.now();
  // Live events and the durable feed describe the same Work Request, so both
  // share one id and merge without duplicates.
  final workRequestId = type.startsWith('work_request.')
      ? _optionalString(payloadMap['workRequestId'])
      : null;
  final eventId = (workRequestId == null
          ? null
          : 'work-request:$workRequestId') ??
      _optionalString(event['eventId']) ??
      _optionalString(event['id']) ??
      '$type:${threadId ?? runId ?? spaceId ?? 'workspace'}:${timestamp.microsecondsSinceEpoch}';
  final target = switch (kind) {
    AxNotificationKind.threadNeedsInput ||
    AxNotificationKind.threadCompleted ||
    AxNotificationKind.threadFailed =>
      AxNotificationTarget.thread,
    AxNotificationKind.workflowRunCompleted ||
    AxNotificationKind.workflowRunFailed ||
    AxNotificationKind.workflowRunNeedsApproval ||
    AxNotificationKind.completed ||
    AxNotificationKind.failed ||
    AxNotificationKind.approvalRequired =>
      AxNotificationTarget.workflowRun,
    AxNotificationKind.workspaceOffline => AxNotificationTarget.workspaces,
    AxNotificationKind.workerCredentialProblem =>
      AxNotificationTarget.workspace,
    AxNotificationKind.workerInstallFailed => AxNotificationTarget.workspace,
    AxNotificationKind.spaceInvitationReceived ||
    AxNotificationKind.invitationReceived =>
      AxNotificationTarget.space,
  };

  return AxNotification(
    id: eventId,
    kind: kind,
    title: switch (kind) {
      AxNotificationKind.threadNeedsInput => 'Thread needs input',
      AxNotificationKind.threadCompleted => 'Thread completed',
      AxNotificationKind.threadFailed => 'Thread failed',
      AxNotificationKind.workflowRunCompleted ||
      AxNotificationKind.completed =>
        'Workflow Run completed',
      AxNotificationKind.workflowRunFailed ||
      AxNotificationKind.failed =>
        'Workflow Run failed',
      AxNotificationKind.workflowRunNeedsApproval ||
      AxNotificationKind.approvalRequired =>
        'Action needed',
      AxNotificationKind.workspaceOffline => 'Workspace offline',
      AxNotificationKind.workerCredentialProblem => 'Worker connection expired',
      AxNotificationKind.workerInstallFailed => 'Worker connection failed',
      AxNotificationKind.spaceInvitationReceived ||
      AxNotificationKind.invitationReceived =>
        'Invitation received',
    },
    message: message,
    createdAt: timestamp,
    priority: switch (kind) {
      AxNotificationKind.threadNeedsInput ||
      AxNotificationKind.threadFailed ||
      AxNotificationKind.workflowRunNeedsApproval ||
      AxNotificationKind.workflowRunFailed ||
      AxNotificationKind.approvalRequired ||
      AxNotificationKind.failed ||
      AxNotificationKind.workerCredentialProblem =>
        AxNotificationPriority.high,
      AxNotificationKind.workspaceOffline ||
      AxNotificationKind.workerInstallFailed ||
      AxNotificationKind.spaceInvitationReceived ||
      AxNotificationKind.invitationReceived =>
        AxNotificationPriority.normal,
      AxNotificationKind.threadCompleted ||
      AxNotificationKind.workflowRunCompleted ||
      AxNotificationKind.completed =>
        AxNotificationPriority.low,
    },
    spaceId: spaceId,
    threadId: threadId,
    runId: runId,
    workspaceId: workspaceId,
    workerId: workerId,
    target: target,
  );
}

String? _optionalString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

/// Keep the newest failure for each identifiable Thread, including when live
/// events and the durable feed arrive out of order.
List<AxNotification> latestThreadFailures(Iterable<AxNotification> items) {
  final sorted = items.toList()
    ..sort((a, b) {
      final time = b.createdAt.compareTo(a.createdAt);
      return time != 0 ? time : b.id.compareTo(a.id);
    });
  final seen = <String>{};
  return [
    for (final item in sorted)
      if (item.kind != AxNotificationKind.threadFailed ||
          item.threadId == null ||
          seen.add(item.threadId!))
        item,
  ];
}

/// Builds notifications from the Cloud feed; items already read stay read.
List<AxNotification> notificationsFromFeed(
    Iterable<Map<String, dynamic>> feed) {
  final result = <AxNotification>[];
  for (final item in feed) {
    final notification = notificationFromRealtimeEvent({
      'type': item['type'],
      'spaceId': item['spaceId'],
      'timestamp': item['timestamp'],
      'payload': {
        'workRequestId': item['id'],
        'threadId': item['threadId'],
      },
    });
    if (notification == null) continue;
    result.add(item['read'] == true ? notification.markRead() : notification);
  }
  return result;
}
