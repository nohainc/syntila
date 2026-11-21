import 'dart:async';

import 'package:flutter/foundation.dart';
import 'ax_render_diagnostics.dart';

import 'ax_work_models.dart';

String _activityTitle(String title, Map<String, Object?> details) {
  if (details['source'] != 'profile.milestone') return title;
  return switch (title) {
    'provider_working' => 'Working',
    'provider_tool_started' => 'Using a tool',
    'provider_response_received' => 'Response received',
    'provider_finalizing' => 'Finishing up',
    _ when RegExp(r'^[a-z0-9]+(?:_[a-z0-9]+)+$').hasMatch(title) => 'Working',
    _ => title,
  };
}

/// Safe, provider-neutral activity projected from a realtime Worker event.
///
/// The Cloud contract already strips raw provider output. The AX model keeps
/// only fields intended for the operational timeline and never treats a
/// percentage as completion progress.
class AxWorkActivity {
  const AxWorkActivity({
    required this.eventId,
    required this.assignmentId,
    required this.attemptId,
    required this.executionId,
    required this.workerId,
    required this.activitySequence,
    required this.streamSequence,
    required this.type,
    required this.status,
    required this.title,
    required this.timestamp,
    this.activityId,
    this.durationMs,
    this.toolId,
    this.toolName,
    this.details = const <String, Object?>{},
  });

  final String eventId;
  final String assignmentId;
  final String attemptId;
  final String executionId;
  final String workerId;
  final int activitySequence;
  final int streamSequence;
  final String type;
  final String status;
  final String title;
  final DateTime timestamp;
  final String? activityId;
  final int? durationMs;
  final String? toolId;
  final String? toolName;
  final Map<String, Object?> details;

  bool get isRunning => status == 'running' || status == 'updated';

  bool get isFinished =>
      status == 'completed' ||
      status == 'failed' ||
      status == 'cancelled' ||
      status == 'interrupted' ||
      type == 'tool.completed' ||
      type == 'tool.failed' ||
      type == 'execution.completed' ||
      type == 'execution.failed' ||
      type == 'execution.cancelled';

  bool get isTerminalExecution =>
      type == 'execution.completed' ||
      type == 'execution.failed' ||
      type == 'execution.cancelled';

  bool get isError =>
      status == 'failed' || status == 'interrupted' || type == 'tool.failed';

  bool get isReplaceable => type == 'model.status' || type == 'message.updated';

  AxWorkActivity copyWith({
    String? type,
    String? status,
    String? title,
    Map<String, Object?>? details,
  }) =>
      AxWorkActivity(
        eventId: eventId,
        assignmentId: assignmentId,
        attemptId: attemptId,
        executionId: executionId,
        workerId: workerId,
        activitySequence: activitySequence,
        streamSequence: streamSequence,
        type: type ?? this.type,
        status: status ?? this.status,
        title: title ?? this.title,
        timestamp: timestamp,
        activityId: activityId,
        durationMs: durationMs,
        toolId: toolId,
        toolName: toolName,
        details: details ?? this.details,
      );

  AxWorkActivity merge(AxWorkActivity update) => AxWorkActivity(
        eventId: update.eventId,
        assignmentId: assignmentId,
        attemptId: update.attemptId,
        executionId: update.executionId,
        workerId: update.workerId,
        activitySequence: update.activitySequence,
        streamSequence: update.streamSequence,
        type: update.type,
        status: update.status,
        title: update.title,
        timestamp: update.timestamp,
        activityId: update.activityId ?? activityId,
        durationMs: update.durationMs ?? durationMs,
        toolId: update.toolId ?? toolId,
        toolName: update.toolName ?? toolName,
        details: update.details.isEmpty ? details : update.details,
      );

  factory AxWorkActivity.fromRealtimeEvent(
    Map<String, dynamic> event, {
    required String threadId,
  }) {
    if (event['type'] != 'assignment.activity') {
      throw const FormatException('Not a Worker Activity event');
    }
    final eventThreadId = event['threadId'];
    if (eventThreadId != threadId) {
      throw const FormatException('Worker Activity belongs to another Thread');
    }
    final payload = event['payload'];
    if (payload is! Map) {
      throw const FormatException('Worker Activity payload is invalid');
    }
    final values = Map<String, dynamic>.from(payload);
    String requiredString(String key) {
      final value = values[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Worker Activity $key is required');
      }
      return value.trim();
    }

    final eventId = event['eventId'];
    final streamSequence = event['sequence'];
    final activitySequence = values['activitySequence'];
    final timestamp = event['timestamp'];
    final assignmentId = event['assignmentId'] ?? values['entityId'];
    final attemptId = event['attemptId'];
    if (eventId is! String || eventId.trim().isEmpty) {
      throw const FormatException('Worker Activity eventId is required');
    }
    if (assignmentId is! String || assignmentId.trim().isEmpty) {
      throw const FormatException('Worker Activity assignmentId is required');
    }
    if (attemptId is! String || attemptId.trim().isEmpty) {
      throw const FormatException('Worker Activity attemptId is required');
    }
    if (activitySequence is! int || activitySequence < 1) {
      throw const FormatException('Worker Activity sequence is invalid');
    }
    if (streamSequence is! int || streamSequence < 0) {
      throw const FormatException('Worker Activity stream sequence is invalid');
    }
    if (timestamp is! String) {
      throw const FormatException('Worker Activity timestamp is required');
    }
    final parsedTimestamp = DateTime.tryParse(timestamp);
    if (parsedTimestamp == null) {
      throw const FormatException('Worker Activity timestamp is invalid');
    }
    final rawDetails = values['details'];
    final details = <String, Object?>{};
    if (rawDetails is Map) {
      for (final entry in rawDetails.entries) {
        if (entry.key is String &&
            (entry.value == null ||
                entry.value is String ||
                entry.value is num ||
                entry.value is bool)) {
          details[entry.key as String] = entry.value;
        }
      }
    }
    return AxWorkActivity(
      eventId: eventId.trim(),
      assignmentId: assignmentId.trim(),
      attemptId: attemptId.trim(),
      executionId: requiredString('executionId'),
      workerId: requiredString('workerId'),
      activitySequence: activitySequence,
      streamSequence: streamSequence,
      type: requiredString('activityType'),
      status: requiredString('activityStatus'),
      title: _activityTitle(requiredString('title'), details),
      timestamp: parsedTimestamp.toLocal(),
      activityId: values['activityId'] is String
          ? (values['activityId'] as String).trim()
          : null,
      durationMs:
          values['durationMs'] is int ? values['durationMs'] as int : null,
      toolId: values['toolId'] is String
          ? (values['toolId'] as String).trim()
          : null,
      toolName: values['toolName'] is String
          ? (values['toolName'] as String).trim()
          : null,
      details: Map.unmodifiable(details),
    );
  }

  factory AxWorkActivity.fromHistory(Map<String, dynamic> values) {
    String requiredString(String key) {
      final value = values[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Worker Activity $key is required');
      }
      return value.trim();
    }

    final activitySequence = values['activitySequence'];
    final timestamp = values['timestamp'];
    if (activitySequence is! int ||
        activitySequence < 1 ||
        timestamp is! String) {
      throw const FormatException('Worker Activity history is invalid');
    }
    final parsedTimestamp = DateTime.tryParse(timestamp);
    if (parsedTimestamp == null) {
      throw const FormatException(
          'Worker Activity history timestamp is invalid');
    }
    final details = <String, Object?>{};
    final rawDetails = values['details'];
    if (rawDetails is Map) {
      for (final entry in rawDetails.entries) {
        if (entry.key is String &&
            (entry.value == null ||
                entry.value is String ||
                entry.value is num ||
                entry.value is bool)) {
          details[entry.key as String] = entry.value;
        }
      }
    }
    return AxWorkActivity(
      eventId: requiredString('eventId'),
      assignmentId: requiredString('assignmentId'),
      attemptId: requiredString('attemptId'),
      executionId: requiredString('executionId'),
      workerId: requiredString('workerId'),
      activitySequence: activitySequence,
      streamSequence: 0,
      type: requiredString('activityType'),
      status: requiredString('activityStatus'),
      title: _activityTitle(requiredString('title'), details),
      timestamp: parsedTimestamp.toLocal(),
      activityId: values['activityId'] is String
          ? (values['activityId'] as String).trim()
          : null,
      durationMs:
          values['durationMs'] is int ? values['durationMs'] as int : null,
      toolId: values['toolId'] is String
          ? (values['toolId'] as String).trim()
          : null,
      toolName: values['toolName'] is String
          ? (values['toolName'] as String).trim()
          : null,
      details: Map.unmodifiable(details),
    );
  }
}

/// Thread-local activity projection. It is intentionally separate from Work
/// request/result state so operational events cannot mutate conversation text.
class _AssignmentSignal extends ChangeNotifier {
  void fire() {
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'AxWorkActivityStore.assignment',
      operation: 'activity.changed',
    );
    notifyListeners();
  }
}

class AxWorkActivityStore extends ChangeNotifier {
  AxWorkActivityStore({
    DateTime Function()? clock,
    Duration notifyInterval = const Duration(milliseconds: 250),
  })  : _clock = clock ?? DateTime.now,
        _notifyInterval = notifyInterval;

  static const maxActivitiesPerAssignment = 512;
  static const maxRememberedEventIds = 4096;

  /// Clock offsets larger than this are treated as late delivery (a replay on
  /// reconnect), not as clock skew, and are never used to shift timestamps.
  static const maxTrustedClockOffset = Duration(minutes: 2);

  final DateTime Function() _clock;
  final Duration _notifyInterval;
  final _activities = <String, List<AxWorkActivity>>{};
  // The newest accepted execution.started event fences delayed events from a
  // previous retry. Cloud stream order is not sufficient on its own because a
  // reconnect can deliver an old attempt after a newer attempt has started.
  final _latestAttempts = <String, String>{};
  final _eventIds = <String>{};
  final _signals = <String, _AssignmentSignal>{};
  final _clockOffsets = <String, Duration>{};
  final _lastNotified = <String, DateTime>{};
  final _pendingNotifications = <String, Timer>{};
  bool _disposed = false;

  static Set<String> assignmentIdsFor(AxWorkRequest request) => {
        ...request.steps.map((step) => step.assignmentId).whereType<String>(),
        ...request.turns.map((turn) => turn.assignmentId).whereType<String>(),
        // Persisted history names its assignment, so it still resolves when a
        // detail read returns steps without one.
        ...request.activityHistory
            .map((item) => item['assignmentId'])
            .whereType<String>(),
      };

  /// Fires only when activity for one of this request's assignments changes,
  /// so a live progress line does not rebuild every card in the timeline.
  Listenable listenableForRequest(AxWorkRequest request) => Listenable.merge([
        for (final id in assignmentIdsFor(request)) _signal(id),
      ]);

  _AssignmentSignal _signal(String assignmentId) =>
      _signals.putIfAbsent(assignmentId, _AssignmentSignal.new);

  /// Estimated `local clock - event clock` for the request's assignments, from
  /// the least-delayed live event seen. Applied to event timestamps so elapsed
  /// time is not skewed by a differing device clock.
  Duration clockOffsetForRequest(AxWorkRequest request) {
    Duration? best;
    for (final id in assignmentIdsFor(request)) {
      final offset = _clockOffsets[id];
      if (offset != null && (best == null || offset < best)) best = offset;
    }
    return best ?? Duration.zero;
  }

  void _recordClockOffset(AxWorkActivity activity) {
    final observed = _clock().difference(activity.timestamp);
    if (observed.abs() > maxTrustedClockOffset) return;
    final known = _clockOffsets[activity.assignmentId];
    if (known == null || observed < known) {
      _clockOffsets[activity.assignmentId] = observed;
    }
  }

  /// Lifecycle and tool changes notify immediately. Replaceable status and
  /// message updates arrive in bursts, so they are limited to one rebuild per
  /// interval with a trailing update that always delivers the latest value.
  void _notify(String assignmentId, {required bool immediate}) {
    if (_disposed) return;
    final now = _clock();
    final last = _lastNotified[assignmentId];
    final elapsed = last == null ? _notifyInterval : now.difference(last);
    if (immediate || elapsed >= _notifyInterval) {
      _pendingNotifications.remove(assignmentId)?.cancel();
      _fire(assignmentId, now);
      return;
    }
    if (_pendingNotifications.containsKey(assignmentId)) return;
    _pendingNotifications[assignmentId] = Timer(_notifyInterval - elapsed, () {
      _pendingNotifications.remove(assignmentId);
      if (_disposed) return;
      _fire(assignmentId, _clock());
    });
  }

  void _fire(String assignmentId, DateTime now) {
    _lastNotified[assignmentId] = now;
    _signals[assignmentId]?.fire();
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'AxWorkActivityStore',
      operation: 'activity.changed',
    );
    notifyListeners();
  }

  List<AxWorkActivity> forRequest(AxWorkRequest request) {
    final assignmentIds = assignmentIdsFor(request);
    if (assignmentIds.isEmpty) return const [];
    final result = <AxWorkActivity>[];
    final requestIsTerminal = const {
      'completed',
      'failed',
      'cancelled',
      'timed_out',
      'lost',
    }.contains(request.status);
    for (final assignmentId in assignmentIds) {
      final activities = _activities[assignmentId] ?? const [];
      final historical = request.activityHistory
          .where((item) => item['assignmentId'] == assignmentId)
          .map((item) {
        try {
          return AxWorkActivity.fromHistory(item);
        } on FormatException {
          return null;
        }
      }).whereType<AxWorkActivity>();
      final merged = <String, AxWorkActivity>{
        for (final activity in historical) activity.eventId: activity,
        for (final activity in activities) activity.eventId: activity,
      };
      final ordered = merged.values.toList()..sort(_compare);
      final projected = <AxWorkActivity>[];
      for (final activity in ordered) {
        final matchingIndex = _matchingIndex(projected, activity);
        if (matchingIndex < 0) {
          projected.add(activity);
          continue;
        }
        final current = projected[matchingIndex];
        if (_compare(current, activity) <= 0) {
          projected[matchingIndex] = current.merge(activity);
        }
      }
      projected.sort(_compare);
      final latestAttempt =
          _latestAttempts[assignmentId] ?? projected.lastOrNull?.attemptId;
      final currentAttempt = latestAttempt == null
          ? projected
          : projected.where((activity) => activity.attemptId == latestAttempt);
      if (!requestIsTerminal) {
        result.addAll(currentAttempt);
        continue;
      }
      result.addAll(currentAttempt.map((activity) {
        if (activity.isFinished) return activity;
        // Lifecycle and status rows ("Execution started", "Thinking", a
        // message in progress) never get their own end event. When the
        // execution is over they are simply done, not failed. A tool that
        // never reported back is only an error if the request did not
        // complete.
        if (!activity.type.startsWith('tool.') ||
            request.status == 'completed') {
          return activity.copyWith(
            status: 'completed',
            details: {...activity.details, 'reconciled': true},
          );
        }
        return activity.copyWith(
          status: 'interrupted',
          title: 'Activity ended when the execution terminated',
          details: {
            ...activity.details,
            'reconciled': true,
          },
        );
      }));
    }
    result.sort(_compare);
    return List.unmodifiable(result);
  }

  List<AxWorkActivity> forAssignment(String assignmentId) =>
      List.unmodifiable(_activities[assignmentId] ?? const []);

  bool handle(Map<String, dynamic> event, {required String threadId}) {
    if (event['type'] != 'assignment.activity') return false;
    AxRenderDiagnostics.instance.cacheMutation(
      component: 'AxWorkActivityStore',
      operation: 'assignment.activity',
      threadId: threadId,
    );
    late final AxWorkActivity activity;
    try {
      activity = AxWorkActivity.fromRealtimeEvent(event, threadId: threadId);
    } on FormatException {
      return false;
    }
    if (!_eventIds.add(activity.eventId)) return false;
    _recordClockOffset(activity);
    if (_eventIds.length > maxRememberedEventIds) {
      _eventIds.remove(_eventIds.first);
    }
    final list = _activities.putIfAbsent(activity.assignmentId, () => []);
    final latestAttempt = _latestAttempts[activity.assignmentId];
    if (latestAttempt != null && latestAttempt != activity.attemptId) {
      // A new attempt is admitted only by its execution.started marker and
      // only when it is newer than the current activity. Every other event
      // from another attempt is stale and must not reopen the card.
      if (activity.type != 'execution.started' ||
          (list.isNotEmpty && _compare(list.last, activity) >= 0)) {
        return false;
      }
      list.clear();
    }
    _latestAttempts[activity.assignmentId] = activity.attemptId;
    final matchingIndex = _matchingIndex(list, activity);
    if (matchingIndex >= 0) {
      final current = list[matchingIndex];
      if (_compare(current, activity) > 0) return false;
      list[matchingIndex] = current.merge(activity);
    } else {
      list.add(activity);
    }
    list.sort(_compare);
    if (list.length > maxActivitiesPerAssignment) {
      list.removeRange(0, list.length - maxActivitiesPerAssignment);
    }
    _notify(activity.assignmentId, immediate: !activity.isReplaceable);
    return true;
  }

  void clear() {
    if (_disposed) return;
    if (_activities.isEmpty && _eventIds.isEmpty) return;
    final affected = _signals.values.toList();
    _activities.clear();
    _latestAttempts.clear();
    _eventIds.clear();
    _clockOffsets.clear();
    _lastNotified.clear();
    for (final timer in _pendingNotifications.values) {
      timer.cancel();
    }
    _pendingNotifications.clear();
    for (final signal in affected) {
      signal.fire();
    }
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'AxWorkActivityStore',
      operation: 'activity.cleared',
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _pendingNotifications.values) {
      timer.cancel();
    }
    _pendingNotifications.clear();
    super.dispose();
  }

  int _matchingIndex(List<AxWorkActivity> list, AxWorkActivity incoming) {
    if (incoming.activityId != null && incoming.activityId!.isNotEmpty) {
      final index = list.indexWhere((item) =>
          item.activityId == incoming.activityId &&
          item.attemptId == incoming.attemptId);
      if (index >= 0) return index;
    }
    if (incoming.isReplaceable) {
      for (var index = list.length - 1; index >= 0; index--) {
        final item = list[index];
        // A status line and the model's narration are separate rows: a later
        // "Thinking" must not overwrite the narration, nor the reverse.
        if (item.attemptId == incoming.attemptId &&
            item.isReplaceable &&
            item.type == incoming.type &&
            // A profile milestone (no narration text) must not overwrite a
            // narration row, nor the reverse.
            _hasNarration(item) == _hasNarration(incoming)) {
          return index;
        }
      }
    }
    return -1;
  }

  static bool _hasNarration(AxWorkActivity activity) =>
      activity.details['preview'] is String;

  int _compare(AxWorkActivity left, AxWorkActivity right) {
    final stream = left.streamSequence.compareTo(right.streamSequence);
    if (stream != 0) return stream;
    final activity = left.activitySequence.compareTo(right.activitySequence);
    if (activity != 0) return activity;
    return left.eventId.compareTo(right.eventId);
  }
}
