import 'ax_idempotency.dart';
import 'dart:async';
import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_sync_engine.dart';

class AxWorkHistoryGap {
  const AxWorkHistoryGap(this.boundary, this.resumeCursor);
  final AxWorkRequest boundary;
  final AxWorkRequestCursor? resumeCursor;
}

class AxWorkHistory {
  AxWorkHistory(
      {Iterable<AxWorkRequest> requests = const [],
      this.olderCursor,
      this.initialLoaded = false,
      this.newestPageRequest,
      Iterable<AxWorkHistoryGap> gaps = const [],
      Iterable<String> confirmedIds = const []})
      : requests = List.unmodifiable(requests),
        _gaps = List.unmodifiable(gaps),
        confirmedIds = Set.unmodifiable(confirmedIds);
  final List<AxWorkRequest> requests;
  final AxWorkRequestCursor? olderCursor;
  final bool initialLoaded;
  final AxWorkRequest? newestPageRequest;
  final Set<String> confirmedIds;
  final List<AxWorkHistoryGap> _gaps;
}

class _RequestRead {
  final completer = Completer<void>();
  bool again = false;
}

class _HistoryContext {
  Future<void>? olderFlight;
  Object? olderError;
  final revisions = <String, int>{};
  final localProgress = <String, String>{};
  final pendingSubmissions = <String, String?>{};
  final details = <String, _RequestRead>{};
  final detailErrors = <String, Object>{};
  final listeners = <void Function()>[];
  final pageKeys = <AxQueryKey>{};
  final consumedCursors = <AxWorkRequestCursor>{};
  void Function()? cancel;
}

/// Session-owned infinite Work history. Head and active refreshes never traverse
/// immutable historical pages; each older cursor has its own cached page.
class AxWorkHistoryCache {
  final _attempts = AxMutationAttempts();
  AxWorkHistoryCache(this.source,
      {AxSyncEngine? engine, bool registerRetention = true})
      : engine = engine ?? AxSyncEngine() {
    if (registerRetention) {
      this
          .engine
          .registerHistoryOwner('work-requests', _protected, _evict, _compact);
    }
  }
  bool _protected(String id) {
    final context = _contexts[id];
    return engine.mutations.isRunning(_creationKey(id)) ||
        (context != null &&
            (context.listeners.isNotEmpty ||
                context.olderFlight != null ||
                context.details.isNotEmpty));
  }

  void _evict(String id) {
    final context = _contexts.remove(id);
    context?.cancel?.call();
  }

  void _compact(String id) {
    final history = engine.cachedValues<AxWorkHistory>()[query(id).key];
    if (history == null ||
        history.requests.length <= engine.maxRetainedHistoryItems) {
      return;
    }
    final recent = history.requests
        .skip(history.requests.length - engine.maxRetainedHistoryItems)
        .toList();
    final context = _contexts[id];
    for (final key in context?.pageKeys.toList() ?? <AxQueryKey>[]) {
      engine.remove(key);
    }
    context?.pageKeys.clear();
    context?.consumedCursors.clear();
    final ids = recent.map((request) => request.id).toSet();
    context?.revisions.removeWhere((id, _) => !ids.contains(id));
    context?.localProgress.removeWhere((id, _) => !ids.contains(id));
    context?.detailErrors.removeWhere((id, _) => !ids.contains(id));
    final oldestServer =
        recent.where((request) => !request.id.startsWith('local-')).firstOrNull;
    final frontier = oldestServer == null
        ? history.olderCursor
        : AxWorkRequestCursor(
            createdAt: oldestServer.createdAt, id: oldestServer.id);
    final gaps = history._gaps
        .where((gap) => _compare(gap.boundary, recent.first) >= 0)
        .toList();
    if (gaps.isNotEmpty) {
      gaps[gaps.length - 1] = AxWorkHistoryGap(gaps.last.boundary, frontier);
    }
    engine.update(
        query(id),
        (_) => AxWorkHistory(
            requests: recent,
            initialLoaded: history.initialLoaded,
            newestPageRequest: recent.last,
            olderCursor: gaps.isNotEmpty ? history.olderCursor : frontier,
            gaps: gaps,
            confirmedIds: history.confirmedIds.intersection(ids)));
  }

  final AxDataSource? source;
  final AxSyncEngine engine;
  static final _sources = Expando<AxWorkHistoryCache>();
  static AxWorkHistoryCache forSource(AxDataSource? source) => source == null
      ? AxWorkHistoryCache(null)
      : _sources[source] ??= AxWorkHistoryCache(source);
  final _contexts = <String, _HistoryContext>{};
  // Older clients used `workstream-*` identifiers. Those records are no
  // longer valid Cloud thread IDs; treating them as empty local history keeps
  // stale persisted navigation from repeatedly polling a route that returns
  // 404.
  static bool _isLegacyThreadId(String id) => id.startsWith('workstream-');
  AxQuery<AxWorkHistory> query(String id, {bool activeOnly = false}) => AxQuery(
      key: AxQueryKey(['thread', id, 'work-requests']),
      load: () => _load(id, activeOnly));
  AxWorkHistory peek(String id) =>
      engine.peek(query(id)).data ?? AxWorkHistory();
  bool loading(String id) => engine.peek(query(id)).isFetching;
  bool loadingOlder(String id) => _contexts[id]?.olderFlight != null;
  Object? error(String id) =>
      _contexts[id]?.olderError ??
      (_contexts[id]?.detailErrors.values.firstOrNull) ??
      engine.peek(query(id)).error;
  _HistoryContext _context(String id) => _contexts.putIfAbsent(id, () {
        final context = _HistoryContext();
        context.cancel = engine.watch(query(id), (_) => _emit(context),
            fireImmediately: false, retain: false);
        return context;
      });
  void _emit(_HistoryContext context) {
    engine.scheduleRetention();
    for (final listener in List.of(context.listeners)) {
      if (context.listeners.contains(listener)) listener();
    }
  }

  void Function() watch(String id, void Function() listener) {
    final context = _context(id);
    context.listeners.add(listener);
    return () {
      context.listeners.remove(listener);
      _contexts[id]?.listeners.remove(listener);
      engine.scheduleRetention();
    };
  }

  int _compare(AxWorkRequest a, AxWorkRequest b) {
    final time = a.createdAt.compareTo(b.createdAt);
    return time == 0 ? a.id.compareTo(b.id) : time;
  }

  List<AxWorkRequest> _merge(
      Iterable<AxWorkRequest> old, Iterable<AxWorkRequest> added) {
    final merged = {for (final item in old) item.id: item};
    for (final item in added) {
      final previous = merged[item.id];
      // Partial updates may omit details already known for this request.
      final activity = item.activityHistory.isEmpty &&
              previous?.activityHistory.isNotEmpty == true
          ? previous!.activityHistory
          : null;
      final reply = item.replyTo == null ? previous?.replyTo : null;
      merged[item.id] = activity != null || reply != null
          ? item.copyWith(activityHistory: activity, replyTo: reply)
          : item;
    }
    return merged.values.toList()..sort(_compare);
  }

  Future<AxWorkHistory> _load(String id, bool activeOnly) async {
    if (_isLegacyThreadId(id)) {
      return AxWorkHistory(initialLoaded: true);
    }
    if (source == null) {
      return AxWorkHistory(requests: peek(id).requests, initialLoaded: true);
    }
    final context = _context(id);
    final revisions = Map.of(context.revisions);
    final first = await source!
        .loadThreadWorkRequestPage(threadId: id, activeOnly: activeOnly);
    // An invalidated read must not overwrite a newer clear's cutoff.
    if (identical(_contexts[id], context)) {
      _aiHistoryClearedAt[id] = first.aiHistoryClearedAt;
    }
    final records = [...first.requests];
    // Active-only pages contain live/recently changed requests, not old history.
    var cursor = activeOnly ? first.nextCursor : null;
    final seen = <AxWorkRequestCursor>{};
    while (cursor != null) {
      if (!seen.add(cursor)) {
        throw const AxApiException('Work history cursor repeated');
      }
      final page = await source!.loadThreadWorkRequestPage(
          threadId: id,
          activeOnly: true,
          beforeCreatedAt: cursor.createdAt,
          beforeId: cursor.id);
      records.addAll(page.requests);
      cursor = page.nextCursor;
    }
    return _historyWithPage(id, records, first, activeOnly, context, revisions);
  }

  AxWorkHistory _historyWithPage(
      String id,
      Iterable<AxWorkRequest> records,
      AxWorkRequestPage first,
      bool activeOnly,
      _HistoryContext context,
      Map<String, int> revisions) {
    for (final r in records) {
      if ((context.revisions[r.id] ?? 0) == (revisions[r.id] ?? 0)) {
        context.localProgress.remove(r.id);
      }
    }
    final current = peek(id);
    var olderCursor =
        current.initialLoaded ? current.olderCursor : first.nextCursor;
    var gaps = current._gaps;
    final boundary = current.newestPageRequest;
    if (!activeOnly &&
        first.nextCursor != null &&
        boundary != null &&
        first.requests.isNotEmpty &&
        _compare(first.requests.first, boundary) > 0) {
      // A long absence may leave a gap between the head and retained history.
      // Traverse only that new gap, then resume the untouched older frontier.
      olderCursor = first.nextCursor;
      gaps = [
        AxWorkHistoryGap(boundary, current.olderCursor),
        ...current._gaps
      ];
    }
    return AxWorkHistory(
        requests: _merge(
            current.requests,
            records.where((r) =>
                (context.revisions[r.id] ?? 0) == (revisions[r.id] ?? 0))),
        initialLoaded: true,
        newestPageRequest: activeOnly
            ? current.newestPageRequest
            : first.requests.lastOrNull ?? current.newestPageRequest,
        olderCursor: olderCursor,
        gaps: gaps,
        confirmedIds: {
          ...current.confirmedIds,
          ...records
              .where((r) =>
                  (context.revisions[r.id] ?? 0) == (revisions[r.id] ?? 0))
              .map((r) => r.id)
        });
  }

  Future<AxWorkHistory> refresh(String id, {bool activeOnly = false}) {
    _context(id);
    // Cold loads always start with a single historical head page.
    return engine
        .refresh(query(id, activeOnly: activeOnly && peek(id).initialLoaded));
  }

  /// [fenceReads] false keeps an in-flight history load alive so it can merge
  /// into the result; submission updates must not discard it.
  void replace(String id, Iterable<AxWorkRequest> requests,
          {bool fenceReads = true}) =>
      engine.update(query(id), (state) {
        final current = state.data ?? AxWorkHistory();
        return AxWorkHistory(
            requests: requests,
            olderCursor: current.olderCursor,
            initialLoaded: current.initialLoaded,
            newestPageRequest: current.newestPageRequest,
            gaps: current._gaps,
            confirmedIds: current.confirmedIds);
      }, fenceReads: fenceReads);
  AxQueryKey _creationKey(String id) =>
      AxQueryKey(['mutation', 'thread', id, 'create-work-request']);
  bool submitting(String id) => engine.mutations.isRunning(_creationKey(id));
  Map<String, String> localProgress(String id) =>
      Map.unmodifiable(_context(id).localProgress);
  void removeLocalProgress(String id, String requestId) {
    final context = _context(id);
    context.localProgress.remove(requestId);
    _emit(context);
  }

  /// Replace the optimistic entry using exact submission identity, never text.
  void acceptSubmission(
      String threadId, String submissionId, String requestId) {
    final context = _context(threadId);
    if (!context.pendingSubmissions.containsKey(submissionId) ||
        requestId.isEmpty ||
        requestId.startsWith('local-')) {
      return;
    }
    final accepted = context.pendingSubmissions[submissionId];
    if (accepted != null && accepted != requestId) return;
    context.pendingSubmissions[submissionId] = requestId;
    final localId = 'local-$submissionId';
    final local = request(threadId, localId);
    if (local == null) return;
    context.localProgress.remove(localId);
    final history = peek(threadId);
    if (!history.requests.any((item) => item.id == requestId)) {
      engine.update(query(threadId), (state) {
        final current = state.data ?? AxWorkHistory();
        return AxWorkHistory(
            requests: _merge(
              current.requests.where((r) => r.id != localId),
              [
                AxWorkRequest(
                    id: requestId,
                    requestedByName: local.requestedByName,
                    requestedByUserId: local.requestedByUserId,
                    prompt: local.prompt,
                    attachments: local.attachments,
                    replyTo: local.replyTo,
                    workflowId: local.workflowId,
                    workflowVersion: local.workflowVersion,
                    workflowName: local.workflowName,
                    status: 'queued',
                    createdAt: local.createdAt,
                    steps: const [])
              ],
            ),
            olderCursor: current.olderCursor,
            initialLoaded: current.initialLoaded,
            newestPageRequest: current.newestPageRequest,
            confirmedIds: current.confirmedIds,
            gaps: current._gaps);
      }, fenceReads: false);
    } else {
      engine.update(query(threadId), (state) {
        final current = state.data ?? AxWorkHistory();
        return AxWorkHistory(
            requests: [
              for (final r in current.requests)
                if (r.id != localId)
                  r.id == requestId && r.replyTo == null
                      ? r.copyWith(replyTo: local.replyTo)
                      : r,
            ],
            olderCursor: current.olderCursor,
            initialLoaded: current.initialLoaded,
            newestPageRequest: current.newestPageRequest,
            confirmedIds: current.confirmedIds,
            gaps: current._gaps);
      }, fenceReads: false);
    }
  }

  /// A local request and progress belong to shared history, not a mounted form.
  /// There is no automatic retry/reconnect replay of the submission POST.
  Future<String> createRequest(
    String id, {
    required String prompt,
    required String workflowId,
    String? idempotencyKey,
    int workflowVersion = 1,
    String? workflowName,
    String? requestedByUserId,
    String? requestedByName,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},

    /// Reply v1: the message this request replies to.
    AxReplyReference? replyTo,
    required Future<String> Function(
            String, String, List<Map<String, dynamic>>, String)
        execute,
    Future<String> Function(String, String, List<Map<String, dynamic>>, String,
            Map<String, dynamic>)?
        executeWithSelection,
  }) async {
    if (submitting(id) ||
        peek(id).requests.any(
            (r) => const {'queued', 'running', 'waiting'}.contains(r.status))) {
      throw StateError('A Work Request is already active');
    }
    final inputs = List<Map<String, dynamic>>.unmodifiable(attachments
        .map((item) => freezeAxMutationInput(item) as Map<String, dynamic>));
    final scope = 'thread:$id:create-work-request';
    final input = {
      'workflowId': workflowId,
      'workflowVersion': workflowVersion,
      'prompt': prompt,
      'attachments': inputs,
      if (executionSelection.isNotEmpty)
        'executionSelection': freezeAxMutationInput(executionSelection),
      if (replyTo != null) 'replyTo': replyTo.target,
    };
    final key = idempotencyKey ?? _attempts.keyFor(scope, input);
    final retrySubmission = _attempts.wasSubmitted(key);
    final context = _context(id);
    final fence = engine.fence(query(id).key);
    final localId = 'local-$key';
    final local = AxWorkRequest(
        id: localId,
        requestedByName: requestedByName ?? 'You',
        requestedByUserId: requestedByUserId,
        prompt: prompt,
        attachments: AxWorkAttachment.fromList(inputs),
        replyTo: replyTo,
        workflowId: workflowId,
        workflowVersion: workflowVersion,
        workflowName: workflowName,
        status: 'queued',
        createdAt: DateTime.now().toUtc().toIso8601String(),
        steps: const []);
    var attemptedPost = false;
    bool current(_HistoryContext value) =>
        identical(_contexts[id], value) && fence();
    void progress(String text) {
      context.localProgress[localId] = text;
      _emit(context);
    }

    try {
      return await engine.mutations
          .run(AxMutationOperation<String, _HistoryContext>(
        key: _creationKey(id),
        optimisticUpdate: () {
          context.localProgress[localId] = 'Preparing your request…';
          replace(
              id, [...peek(id).requests.where((r) => r.id != localId), local],
              fenceReads: false);
          return context;
        },
        isCurrent: current,
        cancel: (context) => context.localProgress.remove(localId),
        execute: (context) async {
          if (source != null && !retrySubmission) {
            progress('Checking that everything is ready…');
            final issues = await source!
                .validateWorkRequestEligibilityWithSelection(
                    threadId: id,
                    workflowId: workflowId,
                    attachments: inputs,
                    executionSelection: executionSelection);
            if (!current(context)) throw const AxMutationSuperseded();
            if (issues.isNotEmpty) {
              throw AxApiException(
                  'Cannot run ${workflowName ?? workflowId}\n${issues.map((issue) => '• $issue').join('\n')}');
            }
          }
          if (!current(context)) throw const AxMutationSuperseded();
          progress('Sending your request…');
          attemptedPost = true;
          _attempts.markSubmitted(key);
          context.pendingSubmissions[key] = null;
          String savedId;
          try {
            // A reply needs the data source's reply field; the positional
            // callbacks predate replies and keep serving every other send.
            savedId = replyTo != null && source != null
                ? await source!.createWorkRequestWithSelection(
                    threadId: id,
                    workflowId: workflowId,
                    prompt: prompt,
                    attachments: inputs,
                    executionSelection: executionSelection,
                    idempotencyKey: key,
                    replyTo: replyTo.target)
                : executeWithSelection == null
                    ? await execute(prompt, workflowId, inputs, key)
                    : await executeWithSelection(
                        prompt, workflowId, inputs, key, executionSelection);
          } catch (_) {
            final accepted = context.pendingSubmissions[key];
            if (accepted == null) rethrow;
            savedId = accepted;
          }
          if (savedId.isEmpty || savedId.startsWith('local-')) {
            throw const AxApiException(
                'Work Request response identity does not match');
          }
          return savedId;
        },
        commit: (savedId, context) {
          _attempts.complete(scope, input, key);
          final history = peek(id);
          context.localProgress.remove(localId);
          if (!history.confirmedIds.contains(savedId)) {
            context.localProgress[savedId] =
                'Request received. Waiting to start…';
          }
          // Realtime may already have delivered a newer, complete server entity.
          replace(
              id,
              [
                for (final request in history.requests)
                  if (request.id != localId)
                    request.id == savedId && request.replyTo == null
                        ? request.copyWith(replyTo: replyTo)
                        : request,
                if (!history.requests.any((r) => r.id == savedId))
                  AxWorkRequest(
                      id: savedId,
                      requestedByName: local.requestedByName,
                      requestedByUserId: local.requestedByUserId,
                      prompt: prompt,
                      attachments: AxWorkAttachment.fromList(inputs),
                      replyTo: replyTo,
                      workflowId: workflowId,
                      workflowVersion: workflowVersion,
                      workflowName: workflowName,
                      status: 'queued',
                      createdAt: local.createdAt,
                      steps: const []),
              ],
              fenceReads: false);
        },
        rollback: (error, _, context) {
          final rejected = error is AxApiException &&
              (error.message.startsWith('Cannot run ') ||
                  (error.statusCode != null &&
                      error.statusCode! >= 400 &&
                      error.statusCode! < 500 &&
                      error.statusCode != 408));
          final message = error is AxApiException &&
                  (error.message.startsWith('Cannot run ') ||
                      error.statusCode == 422)
              ? error.message
              : 'Could not send your request: $error${attemptedPost && !rejected ? '\nSubmission status is unknown. Sending the same request again safely retries this submission.' : ''}';
          context.localProgress[localId] = message;
          // Keep the failed local row for correction/history; no automatic replay.
          replace(
              id,
              [
                for (final r in peek(id).requests)
                  if (r.id == localId)
                    AxWorkRequest(
                        id: localId,
                        requestedByName: local.requestedByName,
                        requestedByUserId: local.requestedByUserId,
                        prompt: prompt,
                        attachments: AxWorkAttachment.fromList(inputs),
                        replyTo: replyTo,
                        workflowId: workflowId,
                        workflowVersion: workflowVersion,
                        workflowName: workflowName,
                        status: 'failed',
                        createdAt: local.createdAt,
                        steps: const [],
                        error: message)
                  else
                    r
              ],
              fenceReads: false);
        },
        invalidate: (savedId, _) => refreshRequest(id, savedId),
      ));
    } finally {
      context.pendingSubmissions.remove(key);
      if (current(context)) _emit(context);
    }
  }

  Future<void> loadOlder(String id) {
    if (_isLegacyThreadId(id)) return Future.value();
    final context = _context(id);
    if (context.olderFlight != null) return context.olderFlight!;
    final cursor = peek(id).olderCursor;
    if (cursor == null || source == null) return Future.value();
    final completer = Completer<void>();
    context.olderFlight = completer.future;
    context.olderError = null;
    _emit(context);
    () async {
      try {
        final pageKey = AxQueryKey([
          'thread',
          id,
          'work-requests',
          'page',
          cursor.createdAt,
          cursor.id
        ]);
        context.pageKeys.add(pageKey);
        final page = await engine.ensure(
            AxQuery<AxWorkRequestPage>(
                key: pageKey,
                load: () async {
                  final page = await source!.loadThreadWorkRequestPage(
                      threadId: id,
                      beforeCreatedAt: cursor.createdAt,
                      beforeId: cursor.id);
                  if (page.nextCursor == cursor) {
                    throw const AxApiException('Work history cursor repeated');
                  }
                  return page;
                }),
            policy: AxCachePolicy.cacheFirst);
        if (page.nextCursor == cursor ||
            context.consumedCursors.contains(page.nextCursor)) {
          engine.remove(pageKey);
          throw const AxApiException('Work history cursor repeated');
        }
        if (identical(_contexts[id], context)) {
          context.consumedCursors.add(cursor);
          engine.update(query(id), (state) {
            final current = state.data ?? AxWorkHistory();
            var next = page.nextCursor;
            var gaps = current._gaps;
            if (gaps.isNotEmpty &&
                page.requests
                    .any((r) => _compare(r, gaps.first.boundary) <= 0)) {
              next = gaps.first.resumeCursor;
              gaps = gaps.sublist(1);
            }
            // Preserve newer status data when a historical page overlaps.
            return AxWorkHistory(
                requests: _merge(page.requests, current.requests),
                olderCursor: next,
                initialLoaded: current.initialLoaded,
                newestPageRequest: current.newestPageRequest,
                gaps: gaps,
                confirmedIds: {
                  ...current.confirmedIds,
                  ...page.requests.map((r) => r.id)
                });
          }, fenceReads: false);
        }
        completer.complete();
      } catch (error, stack) {
        if (identical(_contexts[id], context)) context.olderError = error;
        completer.completeError(error, stack);
      } finally {
        context.olderFlight = null;
        if (identical(_contexts[id], context)) _emit(context);
      }
    }();
    return completer.future;
  }

  Iterable<String> get threadIds => _contexts.keys.toList();
  Set<String> activeIds(String id) => peek(id)
      .requests
      .where((r) =>
          !r.id.startsWith('local-') &&
          const {
            'queued',
            'starting',
            'acknowledged',
            'running',
            'waiting',
          }.contains(r.status))
      .map((r) => r.id)
      .toSet();
  Set<String> dirtyIds(String id) =>
      _contexts[id]?.detailErrors.keys.toSet() ?? {};
  AxWorkRequest? request(String id, String requestId) =>
      peek(id).requests.where((r) => r.id == requestId).firstOrNull;

  void patchRequest(String id, AxWorkRequest value) {
    final context = _context(id);
    context.revisions[value.id] = (context.revisions[value.id] ?? 0) + 1;
    context.detailErrors.remove(value.id);
    final previous = request(id, value.id);
    _recordRequest(
      id,
      value.activityHistory.isEmpty &&
              previous?.activityHistory.isNotEmpty == true
          ? value.copyWith(activityHistory: previous!.activityHistory)
          : value,
    );
  }

  void _recordRequest(String id, AxWorkRequest value) {
    _context(id).localProgress.remove(value.id);
    engine.update(query(id), (state) {
      final current = state.data ?? AxWorkHistory();
      return AxWorkHistory(
          requests: _merge(current.requests, [value]),
          confirmedIds: {...current.confirmedIds, value.id},
          olderCursor: current.olderCursor,
          initialLoaded: current.initialLoaded,
          newestPageRequest: current.newestPageRequest,
          gaps: current._gaps);
    }, fenceReads: false);
  }

  Future<void> refreshRequest(String id, String requestId,
      {bool supersede = false, bool reconcileMissing = false}) {
    if (source == null || requestId.startsWith('local-')) return Future.value();
    final context = _context(id);
    final pending = context.details[requestId];
    if (pending != null) {
      if (supersede) {
        context.revisions[requestId] = (context.revisions[requestId] ?? 0) + 1;
        pending.again = true;
      }
      return pending.completer.future;
    }
    final read = _RequestRead();
    context.details[requestId] = read;
    context.revisions[requestId] = (context.revisions[requestId] ?? 0) + 1;
    int? attemptedRevision;
    () async {
      try {
        do {
          read.again = false;
          final revision = context.revisions[requestId];
          attemptedRevision = revision;
          late final AxWorkRequestStatus detail;
          try {
            detail = await source!.loadWorkRequest(workRequestId: requestId);
          } catch (error) {
            if (error is AxApiException &&
                error.statusCode == 404 &&
                revision != context.revisions[requestId]) {
              if (read.again && identical(_contexts[id], context)) continue;
              break;
            }
            rethrow;
          }
          if (!identical(_contexts[id], context)) break;
          if (revision != context.revisions[requestId]) continue;
          final previous = request(id, requestId);
          if ((detail.id != null && detail.id != requestId) ||
              (detail.threadId != null && detail.threadId != id) ||
              !const {
                'queued',
                'starting',
                'acknowledged',
                'running',
                'waiting',
                'completed',
                'failed',
                'cancelled',
                'timed_out',
                'lost',
              }.contains(detail.status) ||
              (previous == null &&
                  (detail.originalRequest == null ||
                      detail.createdAt == null ||
                      detail.workflowId == null ||
                      detail.workflowVersion == null))) {
            throw const AxApiException('Malformed Work Request detail');
          }
          final value = AxWorkRequest(
              id: requestId,
              conversationId: detail.conversationId ?? previous?.conversationId,
              turns: detail.turns,
              workflowRun: detail.workflowRun,
              executionConfig:
                  detail.executionConfig ?? previous?.executionConfig,
              requestedByName: detail.requestedByName ??
                  previous?.requestedByName ??
                  'Team member',
              requestedByUserId:
                  detail.requestedByUserId ?? previous?.requestedByUserId,
              prompt: detail.originalRequest ?? previous!.prompt,
              attachments: detail.attachments,
              replyTo: detail.replyTo ?? previous?.replyTo,
              workflowId: detail.workflowId ?? previous!.workflowId,
              workflowVersion:
                  detail.workflowVersion ?? previous!.workflowVersion,
              workflowName: detail.workflowName ?? previous?.workflowName,
              status: detail.status,
              isPhased: detail.isPhased,
              createdAt: detail.createdAt ?? previous!.createdAt,
              steps: List.unmodifiable(detail.steps),
              finalText: detail.text,
              error: detail.error ?? detail.errorMessage,
              activityHistory: detail.activityHistory,
              executionPhase: detail.executionPhase);
          context.detailErrors.remove(requestId);
          context.revisions[requestId] =
              (context.revisions[requestId] ?? 0) + 1;
          _recordRequest(id, value);
        } while (read.again && identical(_contexts[id], context));
        read.completer.complete();
      } catch (error, stack) {
        if (identical(_contexts[id], context)) {
          final missing = error is AxApiException && error.statusCode == 404;
          final pendingSubmission =
              context.localProgress.containsKey(requestId) ||
                  context.pendingSubmissions.values.contains(requestId);
          if (missing && attemptedRevision != context.revisions[requestId]) {
            // A newer event or read superseded this response.
            read.completer.complete();
            return;
          }
          if (missing &&
              reconcileMissing &&
              !pendingSubmission &&
              attemptedRevision == context.revisions[requestId]) {
            // The recovery list did not contain this retained ID and its
            // authoritative detail is gone. Remove only this entry; a 404
            // does not prove the rest of the conversation was cleared.
            context.detailErrors.remove(requestId);
            context.localProgress.remove(requestId);
            context.revisions[requestId] =
                (context.revisions[requestId] ?? 0) + 1;
            engine.update(query(id), (state) {
              final current = state.data ?? AxWorkHistory();
              return AxWorkHistory(
                  requests: current.requests.where((r) => r.id != requestId),
                  olderCursor: current.olderCursor,
                  initialLoaded: current.initialLoaded,
                  newestPageRequest: current.newestPageRequest,
                  gaps: current._gaps,
                  confirmedIds:
                      current.confirmedIds.where((v) => v != requestId));
            }, fenceReads: false);
            _emit(context);
            read.completer.complete();
            return;
          }
          if (error is AxApiException &&
              error.statusCode == 404 &&
              !pendingSubmission &&
              peek(id).confirmedIds.contains(requestId)) {
            // A request the server already returned no longer exists: another
            // session cleared the history while this one missed the realtime
            // event. Drop retained pages rather than showing an error for a
            // row that cannot return. A just-created request the server cannot
            // read yet is not a clear; resetting would wipe the new row until
            // it completed.
            resetHistory(id);
          } else {
            context.detailErrors[requestId] = error;
            _emit(context);
          }
        }
        read.completer.completeError(error, stack);
      } finally {
        if (identical(context.details[requestId], read)) {
          context.details.remove(requestId);
        }
      }
    }();
    return read.completer.future;
  }

  Future<Set<String>> discoverRecent(String id) async {
    if (_isLegacyThreadId(id)) return {};
    if (source == null || !peek(id).initialLoaded) return {};
    final context = _context(id);
    final revisions = Map.of(context.revisions);
    final page = await source!.loadThreadWorkRequestPage(threadId: id);
    if (!identical(_contexts[id], context)) return {};
    final accepted = page.requests
        .where((r) => (context.revisions[r.id] ?? 0) == (revisions[r.id] ?? 0))
        .toList();
    for (final value in accepted) {
      context.revisions[value.id] = (context.revisions[value.id] ?? 0) + 1;
      context.detailErrors.remove(value.id);
    }
    engine.update(
        query(id),
        (_) => _historyWithPage(
            id, accepted, page, false, context, Map.of(context.revisions)),
        fenceReads: false);
    return accepted.map((r) => r.id).toSet();
  }

  /// Discover only active/recent changes after a durable gap, retaining history.
  Future<Set<String>> discoverActive(String id) async {
    if (_isLegacyThreadId(id)) return {};
    if (source == null || !peek(id).initialLoaded) return {};
    final context = _context(id);
    final revisions = Map.of(context.revisions);
    final found = <String>{};
    AxWorkRequestCursor? cursor;
    final seen = <AxWorkRequestCursor>{};
    do {
      final page = await source!.loadThreadWorkRequestPage(
          threadId: id,
          activeOnly: true,
          beforeCreatedAt: cursor?.createdAt,
          beforeId: cursor?.id);
      if (!identical(_contexts[id], context)) return found;
      for (final value in page.requests) {
        if ((context.revisions[value.id] ?? 0) == (revisions[value.id] ?? 0)) {
          patchRequest(id, value);
          found.add(value.id);
        }
      }
      cursor = page.nextCursor;
      if (cursor != null && !seen.add(cursor)) {
        throw const AxApiException('Work history cursor repeated');
      }
    } while (cursor != null);
    return found;
  }

  /// Explicit recovery discards old pages so subsequent scrolling reloads them.
  void invalidate(String id) {
    final context = _contexts.remove(id);
    context?.cancel?.call();
    for (final key in context?.pageKeys ?? <AxQueryKey>{}) {
      engine.remove(key);
    }
    engine.invalidate(AxQueryKey(['thread', id, 'work-requests']),
        prefix: true);
    // Keep subscribers while resetting history and all cached pages.
    engine.remove(query(id).key);
    if (context != null) {
      final replacement = _context(id);
      replacement.listeners.addAll(context.listeners);
      _emit(replacement);
    }
  }

  /// Requests created at or before this instant are hidden from AI History;
  /// the Conversation still shows them unchanged.
  String? aiHistoryClearedAt(String threadId) => _aiHistoryClearedAt[threadId];
  final _aiHistoryClearedAt = <String, String?>{};

  /// Clearing AI History records a cutoff instead of deleting Work, so the
  /// retained requests stay; the refresh brings Cloud's exact cutoff.
  Future<void> clearHistory(String threadId) async {
    // Remote success is the boundary: failures must preserve visible history.
    final cutoff = await source?.clearThreadWorkHistory(threadId: threadId);
    // Fence pre-clear reads while keeping the original Conversation records.
    final retained = peek(threadId);
    invalidate(threadId);
    engine.update(query(threadId), (_) => retained);
    _aiHistoryClearedAt[threadId] = cutoff;
    final context = _contexts[threadId];
    if (context != null) _emit(context);
    unawaited(refresh(threadId).then<void>((_) {}, onError: (Object _) {}));
  }

  /// Apply a confirmed remote clear and fence all pre-clear reads.
  void resetHistory(String threadId) {
    _aiHistoryClearedAt.remove(threadId);
    invalidate(threadId);
    engine.update(
      query(threadId),
      (_) => AxWorkHistory(initialLoaded: true),
    );
  }

  void clear() {
    _attempts.clear();
    _aiHistoryClearedAt.clear();
    for (final entry in _contexts.entries) {
      entry.value.cancel?.call();
      for (final key in entry.value.pageKeys) {
        engine.remove(key);
      }
      engine.invalidate(AxQueryKey(['thread', entry.key, 'work-requests']),
          prefix: true);
      engine.remove(query(entry.key).key);
    }
    _contexts.clear();
  }
}
