import 'dart:async';

import '../ax_models.dart';
import 'ax_sync_engine.dart';

/// Routes shared transport events without reading navigation state.
/// Work Request and Step events use AxWorkRealtimeSync's single-entity router.
class AxRealtimeCacheRouter {
  AxRealtimeCacheRouter(this.engine,
      {this.discussionChanged,
      this.discussionResynchronize,
      this.discussionFullResynchronize,
      this.discussionObserved,
      this.viewedThreadActivity,
      this.activityDebounce = const Duration(milliseconds: 400),
      this.initialReadyFreshness = const Duration(seconds: 2)});

  /// Returns true when the Thread is open in a visible tab. Such activity is
  /// read on arrival. Ordering still needs to refresh for this activity.
  final bool Function(String threadId)? viewedThreadActivity;
  final Duration activityDebounce;

  /// The first realtime.ready of a scope follows the bootstrap reads that
  /// populated the cache. Reads that are loading or this recent are kept.
  final Duration initialReadyFreshness;
  final Future<void> Function(String threadId, String type, String entityId)?
      discussionChanged;
  final Future<void> Function(String threadId)? discussionResynchronize;
  final Future<void> Function(String threadId)? discussionFullResynchronize;
  final bool Function(String threadId)? discussionObserved;
  final AxSyncEngine engine;
  final _eventIds = <String>{};
  final _recoveries = <(String, String?), Future<void>>{};
  final _readyScopes = <(String, String?)>{};

  Timer? _activityTimer;
  final _activitySpaces = <String>{};
  final _activityThreads = <String>{};
  bool _activitySpacesList = false;
  Completer<void>? _activityFlush;

  void reset() {
    _eventIds.clear();
    _recoveries.clear();
    _readyScopes.clear();
    _activitySpacesList = false;
    _activityTimer?.cancel();
    _activityTimer = null;
    final flush = _activityFlush;
    _activityFlush = null;
    if (flush != null && !flush.isCompleted) flush.complete();
    _activitySpaces.clear();
    _activityThreads.clear();
  }

  /// Sidebar indicators come from the Space and Thread lists. A burst of
  /// Discussion, Work and Thread metadata events shares one trailing refresh.
  /// With [awaitRefresh] the returned future completes after that refresh.
  Future<void> _activityChanged(
    String threadId,
    String? spaceId, {
    bool spacesList = true,
    bool viewed = true,
    bool awaitRefresh = false,
  }) {
    if (viewed) viewedThreadActivity?.call(threadId);
    _activityThreads.add(threadId);
    if (spaceId != null) _activitySpaces.add(spaceId);
    _activitySpacesList |= spacesList;
    final flush = _activityFlush ??= Completer<void>();
    _activityTimer ??= Timer(activityDebounce, () {
      _activityTimer = null;
      _activityFlush = null;
      final threads = Set.of(_activityThreads);
      final spaces = Set.of(_activitySpaces);
      final includeSpacesList = _activitySpacesList;
      _activityThreads.clear();
      _activitySpaces.clear();
      _activitySpacesList = false;
      for (final collection in engine.cachedValues<List<AxThread>>().entries) {
        final parts = collection.key.parts;
        if (parts.length == 3 &&
            parts[0] == 'space' &&
            parts[2] == 'threads' &&
            collection.value.any((item) => threads.contains(item.id))) {
          spaces.add(parts[1]);
        }
      }
      engine
          .revalidateWhere((key) =>
              (includeSpacesList && key == AxQueryKey(['spaces'])) ||
              (key.parts.length == 3 &&
                  key.parts[0] == 'space' &&
                  key.parts[2] == 'threads' &&
                  spaces.contains(key.parts[1])))
          .catchError((Object _) {})
          .whenComplete(() {
        if (!flush.isCompleted) flush.complete();
      });
    });
    return awaitRefresh ? flush.future : Future.value();
  }

  Future<void> handle(Map<String, dynamic> event) async {
    final type = event['type'];
    if (type is! String) return;
    final eventId = event['eventId'];
    if (eventId is String) {
      if (!_eventIds.add(eventId)) return;
      if (_eventIds.length > 1000) _eventIds.remove(_eventIds.first);
    }
    final payload =
        event['payload'] is Map ? event['payload'] as Map : const {};
    String? id(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    final spaceId = id(event['spaceId']) ?? id(payload['spaceId']);
    final threadId = id(event['threadId']) ?? id(payload['threadId']);
    if (type == 'reconnect.required' || type == 'realtime.ready') {
      final scope = AxSyncScope.fromEvent(event);
      final key = (scope.kind, scope.id);
      final pending = _recoveries[key];
      if (pending != null) return pending;
      late final Future<void> recovery;
      // Replay is bounded and may omit older edits without reporting a gap.
      // Reconcile retained history on every ready signal until replay is complete.
      final initial = type == 'realtime.ready' && _readyScopes.add(key);
      recovery = _recover(scope,
              fullDiscussionReconciliation: true,
              keepFresh: initial ? initialReadyFreshness : null)
          .whenComplete(() {
        if (identical(_recoveries[key], recovery)) _recoveries.remove(key);
      });
      _recoveries[key] = recovery;
      return recovery;
    }
    if (type == 'people.updated') {
      await engine.revalidateWhere((key) =>
          key == AxQueryKey(['people']) || key == AxQueryKey(['spaces']));
      return;
    }
    if (type.startsWith('worker.inventory.')) {
      await engine.revalidateWhere((key) => key == AxQueryKey(['workers']));
      return;
    }
    if (type.startsWith('discussion.') && threadId != null) {
      final changed = discussionChanged;
      final entityId = id(payload['entityId']);
      if (changed == null) {
        await engine.revalidateWhere(
            (key) => key == AxQueryKey(['thread', threadId, 'discussion']));
      } else if (entityId != null) {
        await changed(threadId, type, entityId);
      }
      if (type == 'discussion.created') {
        await _activityChanged(threadId, spaceId);
      }
      return;
    }
    if (type == 'thread.read') {
      // Read receipts only; the Thread list and unread state are unchanged.
      if (threadId != null) {
        await engine.revalidateWhere(
            (key) => key == AxQueryKey(['thread', threadId, 'read-states']));
      }
      return;
    }
    if (threadId != null &&
        const {
          'work_request.created',
          'work_request.started',
          'work_request.completed',
          'work_request.failed',
          'work_request.cancelled',
        }.contains(type)) {
      await _activityChanged(
        threadId,
        spaceId,
      );
      return;
    }
    if (type.startsWith('space.') || type.startsWith('invitation.')) {
      final affected = spaceId ?? id(payload['entityId']);
      if (affected == null) return;
      if (type == 'space.deleted') {
        engine.remove(AxQueryKey(['space', affected]), prefix: true);
        engine.remove(AxQueryKey(['space-workflow-configurations', affected]));
        engine.remove(AxQueryKey(['workflow-workspace', affected]));
        engine.remove(AxQueryKey(['workflow-default', affected]));
        await engine.revalidateWhere((key) =>
            key == AxQueryKey(['spaces']) ||
            key == AxQueryKey(['archived-spaces']));
        return;
      }
      await engine.revalidateWhere((key) =>
          (key.parts[0] == 'space' &&
              key.parts.length >= 2 &&
              key.parts[1] == affected) ||
          key == AxQueryKey(['space-workflow-configurations', affected]) ||
          key == AxQueryKey(['workflow-workspace', affected]) ||
          key == AxQueryKey(['workflow-default', affected]) ||
          key == AxQueryKey(['spaces']) ||
          key == AxQueryKey(['archived-spaces']) ||
          key == AxQueryKey(['me', 'invitations']));
    } else if (type == 'thread.updated' && threadId != null) {
      // Metadata, read and activity changes arrive in bursts (open, read,
      // submit, complete). One trailing refresh of the parent list suffices.
      await _activityChanged(threadId, spaceId,
          spacesList: false, viewed: false, awaitRefresh: true);
    } else if (type.startsWith('thread.')) {
      final affectedThread = threadId ?? id(payload['entityId']);
      final parents = <String>{if (spaceId != null) spaceId};
      if (affectedThread != null) {
        for (final collection
            in engine.cachedValues<List<AxThread>>().entries) {
          final parts = collection.key.parts;
          if (parts.length == 3 &&
              parts[0] == 'space' &&
              parts[2] == 'threads' &&
              collection.value.any((item) => item.id == affectedThread)) {
            parents.add(parts[1]);
          }
        }
      }
      await engine.revalidateWhere((key) =>
          (!type.contains('discussion') &&
              key.parts.length == 3 &&
              key.parts[0] == 'space' &&
              parents.contains(key.parts[1]) &&
              key.parts[2] == 'threads') ||
          (threadId != null &&
              key == AxQueryKey(['thread', threadId, 'discussion']) &&
              type.contains('discussion')));
    }
  }

  Future<void> _recover(AxSyncScope scope,
      {required bool fullDiscussionReconciliation, Duration? keepFresh}) async {
    engine.invalidateScope(scope, keepFresh: keepFresh);
    final discussions = engine.relevantKeys
        .where((key) =>
            scope.matches(key) &&
            key.parts.length == 3 &&
            key.parts[0] == 'thread' &&
            key.parts[2] == 'discussion' &&
            (scope.kind != 'user' || _observed(key)))
        .toList();
    await Future.wait([
      engine.refreshStaleWhere((key) =>
          scope.matches(key) &&
          _managed(key) &&
          (scope.kind != 'user' ||
              key == AxQueryKey(['people']) ||
              key == AxQueryKey(['spaces']) ||
              _observed(key)) &&
          (discussionResynchronize == null || key.parts[0] != 'thread')),
      if (discussionResynchronize != null)
        for (final key in discussions)
          (fullDiscussionReconciliation && discussionFullResynchronize != null
              ? discussionFullResynchronize!(key.parts[1])
              : discussionResynchronize!(key.parts[1])),
    ]);
  }

  bool _observed(AxQueryKey key) => key.parts.length == 3 &&
          key.parts[0] == 'thread' &&
          key.parts[2] == 'discussion' &&
          discussionObserved != null
      ? discussionObserved!(key.parts[1])
      : engine.isObserved(key);

  bool _managed(AxQueryKey key) =>
      key == AxQueryKey(['workers']) ||
      key == AxQueryKey(['people']) ||
      key == AxQueryKey(['spaces']) ||
      (key.parts[0] == 'space' && key.parts.length >= 2) ||
      key.parts[0] == 'space-workflow-configurations' ||
      key.parts[0] == 'workflow-workspace' ||
      key.parts[0] == 'workflow-default' ||
      (key.parts.length == 3 &&
          key.parts[0] == 'thread' &&
          key.parts[2] == 'discussion');
}
