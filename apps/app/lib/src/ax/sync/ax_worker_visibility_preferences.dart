import '../ax_data.dart';
import 'ax_sync_engine.dart';

/// Session-owned preferences, shared by Workspace and never persisted locally.
class AxWorkerVisibilityPreferences {
  AxWorkerVisibilityPreferences(this.source,
      {required this.engine, this.workspaceId});
  final AxDataSource source;
  final AxSyncEngine engine;
  final String? workspaceId;
  final _scoped = <String, AxWorkerVisibilityPreferences>{};
  int _epoch = 0;
  Object? _lease;
  AxWorkerVisibilityPreferences forWorkspace(String id) {
    if (workspaceId != null) throw StateError('Already scoped to a Workspace');
    return _scoped.putIfAbsent(
        id,
        () => AxWorkerVisibilityPreferences(source,
            engine: engine, workspaceId: id));
  }

  String get _id => workspaceId ?? (throw StateError('Workspace is required'));
  AxWorkerVisibilityDataSource get _api =>
      source is AxWorkerVisibilityDataSource
          ? source as AxWorkerVisibilityDataSource
          : throw StateError('Worker visibility is unavailable');
  late final query = AxQuery<AxWorkerVisibility>(
      key: AxQueryKey(['worker-visibility', _id]),
      staleTime: const Duration(minutes: 45),
      load: () => _api.loadWorkerVisibility(_id));
  Future<AxWorkerVisibility> ensure() =>
      engine.ensure(query, policy: AxCachePolicy.cacheFirst);
  Future<AxWorkerVisibility> refresh() => engine.refresh(query);
  Future<void> save(AxWorkerVisibility value) =>
      _write(() => _api.saveWorkerVisibility(_id, value));
  Future<void> reset() => _write(() => _api.resetWorkerVisibility(_id));
  Future<void> _write(Future<AxWorkerVisibility> Function() execute) async {
    if (_lease != null) {
      throw StateError('A visibility update is already pending');
    }
    final epoch = _epoch;
    final lease = Object();
    _lease = lease;
    try {
      await engine.mutate(
          AxMutation<AxWorkerVisibility>(query: query, execute: execute));
      if (epoch != _epoch) throw const AxMutationSuperseded();
    } finally {
      if (identical(_lease, lease)) _lease = null;
    }
  }

  void clear() {
    _epoch++;
    _lease = null;
    if (workspaceId != null) engine.remove(query.key);
    for (final child in _scoped.values) {
      child.clear();
    }
    _scoped.clear();
  }
}
