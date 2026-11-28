import 'ax_thread_view_state.dart';

abstract interface class AxThreadViewStateStore {
  /// Synchronous read so a Thread can apply its saved view before its first
  /// frame. Every store is backed by synchronous storage.
  AxThreadViewState? loadSync({
    required String userId,
    required String threadId,
  });

  Future<AxThreadViewState?> load({
    required String userId,
    required String threadId,
  });

  Future<void> save({
    required String userId,
    required String threadId,
    required AxThreadViewState state,
  });

  /// Forgets one Thread's saved view, for example after it is deleted.
  Future<void> remove({required String userId, required String threadId});

  Future<void> clearUser(String userId);
  void dispose();
}

/// In-memory fallback for non-browser targets and deterministic tests.
class MemoryAxThreadViewStateStore implements AxThreadViewStateStore {
  final _values = <String, Map<String, AxThreadViewState>>{};

  @override
  AxThreadViewState? loadSync({
    required String userId,
    required String threadId,
  }) =>
      _values[userId]?[threadId];

  @override
  Future<AxThreadViewState?> load({
    required String userId,
    required String threadId,
  }) async =>
      loadSync(userId: userId, threadId: threadId);

  @override
  Future<void> save({
    required String userId,
    required String threadId,
    required AxThreadViewState state,
  }) async {
    (_values[userId] ??= {})[threadId] = state;
  }

  @override
  Future<void> remove({
    required String userId,
    required String threadId,
  }) async =>
      _values[userId]?.remove(threadId);

  @override
  Future<void> clearUser(String userId) async => _values.remove(userId);

  @override
  void dispose() => _values.clear();
}
