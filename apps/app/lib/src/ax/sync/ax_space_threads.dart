import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_sync_engine.dart';

/// Space-owned collections, independent of the selected navigation route.
class AxSpaceThreads {
  AxSpaceThreads(this.source, {AxSyncEngine? engine})
      : engine = engine ?? AxSyncEngine();
  final AxDataSource source;
  final AxSyncEngine engine;

  AxQuery<List<AxThread>> query(String spaceId) => AxQuery(
        key: AxQueryKey(['space', spaceId, 'threads']),
        load: () async => List.unmodifiable(sortAxThreadsByLastUpdate(
            (await source.loadSpaceThreads(spaceId: spaceId))
                .where((thread) => !thread.id.startsWith('workstream-')))),
      );

  List<AxThread> peek(String spaceId) =>
      engine.peek(query(spaceId)).data ?? const [];

  Future<List<AxThread>> ensure(String spaceId) =>
      engine.ensure(query(spaceId));

  Future<List<AxThread>> refresh(String spaceId) {
    engine.invalidate(query(spaceId).key);
    return engine.refresh(query(spaceId));
  }

  /// Pins or unpins for the signed-in user. The list changes first and is put
  /// back when Cloud rejects the change.
  Future<void> setPinned(String spaceId, String threadId, bool pinned) async {
    final source = this.source;
    if (source is! AxPinDataSource) return;
    final key = query(spaceId);
    final before = engine.peek(key).data;
    if (before == null) return;
    final stamp = pinned ? DateTime.now().toUtc().toIso8601String() : '';
    final top = nextAxPinPosition([
      for (final t in before)
        if (t.isPinned) t.pinPosition
    ]);
    engine.update(
        key,
        (state) => List.unmodifiable([
              for (final t in state.data ?? const <AxThread>[])
                t.id == threadId
                    ? t.copyWith(pinnedAt: stamp, pinPosition: pinned ? top : 0)
                    : t
            ]),
        fenceReads: false);
    try {
      await (source as AxPinDataSource)
          .setPinned(kind: 'thread', id: threadId, pinned: pinned);
    } catch (_) {
      engine.update(
          key,
          (state) => List.unmodifiable([
                for (final t in state.data ?? const <AxThread>[])
                  t.id == threadId
                      ? t.copyWith(
                          pinnedAt: before
                                  .where((b) => b.id == threadId)
                                  .firstOrNull
                                  ?.pinnedAt ??
                              '')
                      : t
              ]),
          fenceReads: false);
      rethrow;
    }
  }

  /// Stores the user's order of pinned Threads (first to last).
  Future<void> setPinOrder(String spaceId, List<String> orderedIds) async {
    final source = this.source;
    if (source is! AxPinDataSource) return;
    final key = query(spaceId);
    final before = engine.peek(key).data;
    if (before == null) return;
    final rank = {for (final e in orderedIds.asMap().entries) e.value: e.key};
    engine.update(
        key,
        (state) => List.unmodifiable([
              for (final t in state.data ?? const <AxThread>[])
                rank.containsKey(t.id) ? t.copyWith(pinPosition: rank[t.id]) : t
            ]),
        fenceReads: false);
    try {
      await (source as AxPinDataSource)
          .setPinOrder(kind: 'thread', ids: orderedIds, spaceId: spaceId);
    } catch (_) {
      engine.update(key, (_) => before, fenceReads: false);
      rethrow;
    }
  }

  /// Clears the indicator locally first; the server marker follows and also
  /// clears it for the user's other sessions. Failures leave the next list
  /// read to restore the authoritative flag.
  Future<void> markRead(String spaceId, String threadId) async {
    final source = this.source;
    if (source is! AxThreadReadDataSource) return;
    final key = query(spaceId);
    final cached = engine.peek(key).data;
    final unread = cached?.any((t) => t.id == threadId && t.hasUnread) ?? false;
    if (unread) {
      engine.update(
          key,
          (state) => List.unmodifiable([
                for (final t in state.data ?? const <AxThread>[])
                  t.id == threadId ? t.copyWith(hasUnread: false) : t
              ]),
          fenceReads: false);
    }
    // A lost POST would leave the server flag set and bring the indicator back
    // on the next list read, so retry once before giving up.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await (source as AxThreadReadDataSource).markThreadRead(threadId);
        return;
      } catch (_) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
    }
  }
}
