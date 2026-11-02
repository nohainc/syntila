import '../ax_execution_phase.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../ax_data.dart';
import '../ax_render_diagnostics.dart';
import '../ax_work_latency_trace.dart';
import 'ax_work_history.dart';
import 'ax_sync_scope.dart';

class _RecoveryRead {
  final completer = Completer<void>();
  bool again = false;
  bool discover = false;
  bool recent = false;
  bool allScopes = false;
  final targets = <String>{};
}

class _StreamLease {
  _StreamLease(this.subscription);
  final StreamSubscription<Map<String, dynamic>> subscription;
  int references = 1;
}

/// One event router per session cache. Stream leases prevent shell/page duplicate
/// delivery; visible scopes own the disconnected fallback, not individual widgets.
enum AxWorkRealtimeStatus { available, checking }

class AxWorkRealtimeSync extends ChangeNotifier {
  AxWorkRealtimeSync(this.cache,
      {this.fallbackInterval = const Duration(seconds: 15),
      this.checkingGrace = const Duration(seconds: 3)});
  final AxWorkHistoryCache cache;
  final Duration fallbackInterval;

  /// How long an interruption must last before the UI reports it. Reconnects
  /// and recovery reads right after a request is sent routinely finish within
  /// a second or two and would otherwise flash "Connection interrupted".
  final Duration checkingGrace;
  Timer? _graceTimer;
  bool _displayChecking = false;
  static final _instances = Expando<AxWorkRealtimeSync>();
  static AxWorkRealtimeSync forCache(AxWorkHistoryCache cache) =>
      _instances[cache] ??= AxWorkRealtimeSync(cache);
  final _streams = <Stream<Map<String, dynamic>>, _StreamLease>{};
  final _scopes = <String, int>{};
  final _sequences = <String, int>{};
  final _eventIds = <String>{};
  Timer? _fallback;
  bool _healthy = false;
  bool _transportHealthy = false;
  bool _needsRecovery = false;
  bool _gapStale = false;
  bool _disposed = false;
  bool _connectionInterrupted = false;
  int _generation = 0;
  _RecoveryRead? _recovery;
  int _sessionEpoch = 0;
  bool get healthy => _healthy;
  AxWorkRealtimeStatus get status =>
      _connectionInterrupted || _gapStale || _recovery != null
          ? AxWorkRealtimeStatus.checking
          : AxWorkRealtimeStatus.available;

  /// Debounced [status] for display; [status] itself stays immediate.
  AxWorkRealtimeStatus get displayStatus => _displayChecking
      ? AxWorkRealtimeStatus.checking
      : AxWorkRealtimeStatus.available;
  bool get checkingExecution => status == AxWorkRealtimeStatus.checking;
  Future<void> get pendingRecovery =>
      _recovery?.completer.future ?? Future.value();
  bool get polling => _fallback?.isActive == true;

  void _notifyDiagnostics([String? operation]) {
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'AxWorkRealtimeSync',
      operation: operation,
    );
    if (_disposed) return;
    _syncDisplayStatus();
    notifyListeners();
  }

  void _syncDisplayStatus() {
    if (!checkingExecution) {
      _graceTimer?.cancel();
      _graceTimer = null;
      _displayChecking = false;
    } else if (!_displayChecking && _graceTimer == null) {
      _graceTimer = Timer(checkingGrace, () {
        _graceTimer = null;
        if (_disposed || !checkingExecution) return;
        _displayChecking = true;
        notifyListeners();
      });
    }
  }

  void Function() listen(Stream<Map<String, dynamic>>? events,
      {String? threadId}) {
    if (_disposed) return () {};
    if (events != null) {
      final existing = _streams[events];
      if (existing != null) {
        existing.references++;
      } else {
        _streams[events] = _StreamLease(events.listen((event) {
          unawaited(handle(event).catchError((Object _) {}));
        },
            onError: (Object _, StackTrace __) => _disconnected(),
            onDone: _disconnected));
      }
    }
    if (threadId != null) {
      _scopes[threadId] = (_scopes[threadId] ?? 0) + 1;
    }
    _scheduleFallback();
    if (threadId != null && _healthy) {
      unawaited(_resync(discover: false).catchError((Object _) {}));
    }
    var cancelled = false;
    return () {
      if (cancelled) return;
      cancelled = true;
      if (threadId != null) {
        final count = (_scopes[threadId] ?? 1) - 1;
        if (count <= 0) {
          _scopes.remove(threadId);
        } else {
          _scopes[threadId] = count;
        }
      }
      if (events != null) {
        final lease = _streams[events];
        if (lease != null && --lease.references <= 0) {
          _streams.remove(events);
          unawaited(lease.subscription.cancel());
        }
      }
      _scheduleFallback();
    };
  }

  void _scheduleFallback() {
    if (_disposed || _healthy || _scopes.isEmpty || cache.source == null) {
      _fallback?.cancel();
      _fallback = null;
      return;
    }
    _fallback ??= Timer.periodic(fallbackInterval, (_) {
      if (_recovery == null) {
        _needsRecovery = true;
        unawaited(_resync(discover: true).catchError((Object _) {}));
      }
    });
  }

  void _disconnected() {
    if (_disposed) return;
    _transportHealthy = false;
    _healthy = false;
    _needsRecovery = true;
    _gapStale = true;
    _connectionInterrupted = true;
    ++_generation;
    _notifyDiagnostics('disconnected');
    _scheduleFallback();
  }

  Future<void> _resync(
      {required bool discover, bool recent = false, Set<String>? targets}) {
    final pending = _recovery;
    if (pending != null) {
      if (discover) {
        pending.again = true;
        pending.discover = true;
        pending.recent |= recent;
        if (targets == null) {
          pending.allScopes = true;
        } else {
          pending.targets.addAll(targets);
        }
      }
      return pending.completer.future;
    }
    final read = _RecoveryRead()
      ..discover = discover
      ..recent = recent
      ..allScopes = targets == null
      ..targets.addAll(targets ?? const <String>{});
    _recovery = read;
    final epoch = _sessionEpoch;
    () async {
      try {
        do {
          read.again = false;
          final discover = read.discover;
          final recent = read.recent;
          read.discover = false;
          read.recent = false;
          final generation = _generation;
          final targets = {
            ...read.targets,
            if (read.allScopes) ..._scopes.keys,
          }.toList();
          for (final id in targets) {
            if (epoch != _sessionEpoch || _disposed) break;
            final ids = {...cache.activeIds(id), ...cache.dirtyIds(id)};
            final found = discover
                ? (recent
                    ? await cache.discoverRecent(id)
                    : await cache.discoverActive(id))
                : <String>{};
            if (epoch != _sessionEpoch || _disposed) break;
            await Future.wait(ids.difference(found).map((requestId) => cache
                .refreshRequest(id, requestId, reconcileMissing: discover)));
          }
          if (epoch == _sessionEpoch &&
              generation == _generation &&
              _transportHealthy &&
              !read.again) {
            _healthy = true;
            _gapStale = false;
            _needsRecovery = false;
            _connectionInterrupted = false;
            _notifyDiagnostics('recovery.complete');
            _scheduleFallback();
          }
        } while (read.again && epoch == _sessionEpoch && !_disposed);
        read.completer.complete();
      } catch (error, stack) {
        if (epoch == _sessionEpoch) {
          _healthy = _transportHealthy && !_gapStale;
          _notifyDiagnostics('recovery.failed');
          _scheduleFallback();
        }
        read.completer.completeError(error, stack);
      } finally {
        if (identical(_recovery, read)) {
          _recovery = null;
          _notifyDiagnostics('recovery.finally');
        }
      }
    }();
    return read.completer.future;
  }

  Future<void> handle(Map<String, dynamic> event) async {
    if (_disposed) return;
    final type = event['type'];
    if (type is String) {
      AxRenderDiagnostics.instance.cacheMutation(
        component: 'AxWorkRealtimeSync',
        operation: type,
        threadId:
            event['threadId'] is String ? event['threadId'] as String : null,
      );
    }
    if (type == 'realtime.connection') {
      if (event['status'] != 'connected') {
        _disconnected();
        return;
      }
      _transportHealthy = true;
      _healthy = !_gapStale;
      _connectionInterrupted = true;
      ++_generation;
      _notifyDiagnostics('connection.connected');
      _scheduleFallback();
      await _resync(discover: _needsRecovery, recent: _needsRecovery);
      return;
    }
    if (type == 'realtime.ready') {
      _transportHealthy = true;
      _healthy = !_gapStale;
      _connectionInterrupted = true;
      _notifyDiagnostics('realtime.ready');
      _scheduleFallback();
      await _resync(discover: _needsRecovery, recent: _needsRecovery);
      return;
    }
    if (type == 'reconnect.required') {
      final scope = AxSyncScope.fromEvent(event);
      if (scope.kind == 'space' || scope.kind == 'unknown') {
        return;
      }
      if (scope.kind == 'thread') {
        // A scoped gap is not a transport outage. Recover retained active
        // entities in this Thread without polling unrelated views.
        if (!cache.threadIds.contains(scope.id)) return;
        _connectionInterrupted = true;
        _gapStale = true;
        _notifyDiagnostics('reconnect.required');
        await _resync(discover: true, targets: {scope.id!});
        return;
      }
      _healthy = false;
      _needsRecovery = true;
      _gapStale = true;
      _connectionInterrupted = true;
      ++_generation;
      _notifyDiagnostics('realtime.stale');
      _scheduleFallback();
      await _resync(discover: true, recent: true);
      return;
    }
    if (type == 'realtime.stale') {
      _disconnected();
      return;
    }
    final executionChange = type is String &&
        !type.contains('.progress') &&
        type != 'assignment.activity' &&
        const [
          'run.',
          'task.',
          'attempt.',
          'assignment.',
          'artifact.',
          'finding.',
          'verification.'
        ].any(type.startsWith);
    if (!executionChange &&
        !const {
          'work_request.created',
          'work_request.started',
          'work_request.completed',
          'work_request.failed',
          'work_request.cancelled',
          'step.queued',
          'step.running',
          'step.completed',
          'step.failed',
          'step.cancelled',
          'step.phase'
        }.contains(type)) {
      return;
    }
    final raw = event['payload'];
    if (raw is! Map) return;
    final payload = Map<String, dynamic>.from(raw);
    final id = payload['workRequestId'];
    final threadId = payload['threadId'];
    if (id is! String ||
        id.isEmpty ||
        threadId is! String ||
        threadId.isEmpty) {
      return;
    }
    final sequence = event['sequence'];
    final sequenceKey = '${event['workspaceId']}:$threadId:$id';
    if (sequence is int && sequence > 0) {
      if (sequence <= (_sequences[sequenceKey] ?? -1)) return;
      _sequences[sequenceKey] = sequence;
    }
    final eventId = event['eventId'];
    if (eventId is String) {
      if (!_eventIds.add(eventId)) return;
      if (_eventIds.length > 1000) _eventIds.remove(_eventIds.first);
    }
    if (type is String) AxWorkLatencyTrace.instance.realtimeEvent(type, id);
    final submissionId = payload['submissionId'];
    if (type == 'work_request.created' && submissionId is String) {
      cache.acceptSubmission(threadId, submissionId, id);
    }
    final current = cache.request(threadId, id);
    final full = payload['workRequest'];
    if (full is Map &&
        full['id'] == id &&
        full['createdAt'] is String &&
        full['workflowId'] is String &&
        full['workflowVersion'] is int &&
        full['prompt'] is String &&
        full['requestedByName'] is String &&
        full['status'] is String &&
        (full['threadId'] == null ||
            full['threadId'] == threadId ||
            full['threadId'] == null ||
            full['threadId'] == threadId) &&
        full['steps'] is List &&
        (full['steps'] as List).every((v) => v is Map) &&
        (full['status'] != 'completed' || full.containsKey('finalText'))) {
      try {
        final incoming =
            AxWorkRequest.fromJson(Map<String, dynamic>.from(full));
        final regressesStep = current?.steps.any((previous) => incoming.steps
                .any((next) =>
                    next.kind == previous.kind &&
                    next.assignmentId == previous.assignmentId &&
                    next.effectivePhase != previous.effectivePhase &&
                    (AxExecutionPhase.isTerminal(previous.effectivePhase) ||
                        previous.effectivePhase == AxExecutionPhase.uncertain ||
                        AxExecutionPhase.advances(
                            next.effectivePhase, previous.effectivePhase)))) ??
            false;
        if (current != null &&
            ((AxExecutionPhase.isTerminal(current.status) &&
                    !AxExecutionPhase.isTerminal(incoming.status)) ||
                (current.status == 'running' && incoming.status == 'queued') ||
                regressesStep)) {
          await cache.refreshRequest(threadId, id, supersede: true);
          return;
        }
        cache.patchRequest(threadId, incoming);
        return;
      } catch (_) {
        // Incomplete optional metadata falls back to the authoritative detail.
      }
    }
    final status = payload['status'];
    if (current != null &&
        status is String &&
        const {'queued', 'running', 'waiting'}.contains(current.status)) {
      if ((type == 'work_request.started' && status == 'running') ||
          (type == 'work_request.created' &&
              status == 'queued' &&
              current.status == 'queued')) {
        cache.patchRequest(threadId, current.copyWith(status: status));
        return;
      }
      final kind = payload['stepKind'];
      if (type == 'step.phase' && kind is String) {
        // Phase events are notifications. Apply only a strictly forward move
        // on the same assignment; anything else (a delayed older phase, a
        // terminal or uncertain outcome, a different assignment) must not
        // rewrite state from the event, so it is dropped or re-read.
        final step = current.steps.where((s) => s.kind == kind).firstOrNull;
        final eventAssignment = event['assignmentId'];
        final sameAssignment = step != null &&
            step.assignmentId != null &&
            eventAssignment is String &&
            step.assignmentId == eventAssignment;
        if (step != null &&
            sameAssignment &&
            !AxExecutionPhase.advances(step.effectivePhase, status) &&
            AxExecutionPhase.isKnown(status) &&
            !AxExecutionPhase.isTerminal(status) &&
            status != AxExecutionPhase.uncertain) {
          return;
        }
        // The step was read before Cloud created its assignment. The first
        // forward phase names that assignment; adopt it rather than re-read.
        if (step != null &&
            step.assignmentId == null &&
            eventAssignment is String &&
            eventAssignment.isNotEmpty &&
            AxExecutionPhase.advances(step.effectivePhase, status)) {
          cache.patchRequest(
              threadId,
              current.copyWith(steps: [
                for (final s in current.steps)
                  s.kind == kind
                      ? s.withAssignedPhase(eventAssignment, status)
                      : s
              ]));
          return;
        }
        if (step != null &&
            sameAssignment &&
            AxExecutionPhase.advances(step.effectivePhase, status)) {
          cache.patchRequest(
              threadId,
              current.copyWith(steps: [
                for (final s in current.steps)
                  s.kind == kind ? s.withExecutionPhase(status) : s
              ]));
          return;
        }
      } else if ((type == 'step.queued' && status == 'queued' ||
              type == 'step.running' && status == 'running') &&
          kind is String &&
          current.steps.any((s) =>
              s.kind == kind &&
              const {'queued', 'running', 'waiting'}.contains(s.status) &&
              !(s.status == 'running' && status == 'queued'))) {
        cache.patchRequest(
            threadId,
            current.copyWith(steps: [
              for (final step in current.steps)
                step.kind == kind
                    ? step.withStatus(status).withWaitDetail(
                        payload['message'] is String
                            ? payload['message'] as String
                            : null)
                    : step
            ]));
        return;
      }
    }
    // The last Step's terminal event is always followed by the request's own
    // terminal event, which re-reads the request. Mark the Step finished now
    // and let that single read carry the result, instead of reading twice.
    if (current != null &&
        kindIsLastStep(current, payload['stepKind']) &&
        !AxExecutionPhase.isTerminal(current.status) &&
        ((type == 'step.completed' && status == 'completed') ||
            (type == 'step.failed' && status == 'failed') ||
            (type == 'step.cancelled' && status == 'cancelled'))) {
      final kind = payload['stepKind'] as String;
      cache.patchRequest(
          threadId,
          current.copyWith(steps: [
            for (final step in current.steps)
              step.kind == kind ? step.withStatus(status as String) : step
          ]));
      return;
    }
    // Terminal and incomplete events need result/error/Step details.
    try {
      await cache.refreshRequest(threadId, id, supersede: true);
    } catch (_) {
      _needsRecovery = true;
      _scheduleFallback();
      rethrow;
    }
  }

  static bool kindIsLastStep(AxWorkRequest request, Object? kind) =>
      kind is String &&
      request.steps.isNotEmpty &&
      request.steps.last.kind == kind;

  void reset() {
    ++_generation;
    ++_sessionEpoch;
    _recovery = null;
    _sequences.clear();
    _eventIds.clear();
    _healthy = false;
    _transportHealthy = false;
    _needsRecovery = false;
    _gapStale = false;
    _connectionInterrupted = false;
    _fallback?.cancel();
    _fallback = null;
    _notifyDiagnostics('execution.event');
  }

  @override
  void dispose() {
    _disposed = true;
    _graceTimer?.cancel();
    reset();
    for (final lease in _streams.values) {
      unawaited(lease.subscription.cancel());
    }
    _streams.clear();
    _scopes.clear();
    super.dispose();
  }
}
