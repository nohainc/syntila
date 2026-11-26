import '../ax_data.dart';
import 'ax_sync_engine.dart';

/// Session-owned personal or Space preferences.
class AxWorkflowConfigurations {
  AxWorkflowConfigurations(this.source, {required this.engine, this.spaceId});
  final String? spaceId;
  AxQueryKey get queryKey => spaceId != null
      ? AxQueryKey(['space-workflow-configurations', spaceId!])
      : key;
  AxSpaceWorkflowConfigurationDataSource get _spaceApi =>
      source as AxSpaceWorkflowConfigurationDataSource;
  final AxDataSource source;
  final AxSyncEngine engine;
  static final key = AxQueryKey(['user-workflow-configurations']);
  AxWorkflowConfigurationDataSource get _api {
    if (source is AxWorkflowConfigurationDataSource) {
      return source as AxWorkflowConfigurationDataSource;
    }
    throw StateError('Workflow configuration is unavailable');
  }

  late final query = AxQuery<List<AxUserWorkflowConfiguration>>(
      key: queryKey,
      staleTime: const Duration(minutes: 45),
      load: () async => List.unmodifiable(spaceId == null
          ? await _api.loadWorkflowConfigurations()
          : await _spaceApi.loadSpaceWorkflowConfigurations(spaceId!)));

  late final defaultQuery = AxQuery<String>(
      key: AxQueryKey(['workflow-default', spaceId ?? 'user']),
      staleTime: const Duration(minutes: 45),
      load: () async {
        final api = source is AxWorkflowDefaultDataSource
            ? source as AxWorkflowDefaultDataSource
            : null;
        if (api == null) return 'chat';
        return spaceId == null
            ? api.loadWorkflowDefault()
            : api.loadSpaceWorkflowDefault(spaceId!);
      });

  Future<List<AxUserWorkflowConfiguration>> ensure() =>
      engine.ensure(query, policy: AxCachePolicy.cacheFirst);
  Future<List<AxUserWorkflowConfiguration>> refresh() => engine.refresh(query);
  Future<String> ensureDefault() =>
      engine.ensure(defaultQuery, policy: AxCachePolicy.cacheFirst);
  Future<String> refreshDefault() => engine.refresh(defaultQuery);

  /// Space preferences are read-only in this view.
  void _requireWritable() {
    if (spaceId != null) {
      throw StateError('Space workflows are read-only');
    }
  }

  Future<void> setDefault(String workflowId) async {
    _requireWritable();
    if (_writeLease != null) {
      throw StateError('A workflow update is already pending');
    }
    final api = source is AxWorkflowDefaultDataSource
        ? source as AxWorkflowDefaultDataSource
        : null;
    if (api == null) throw StateError('Workflow default is unavailable');
    final epoch = _sessionEpoch;
    final lease = Object();
    _writeLease = lease;
    try {
      await engine.mutate(AxMutation<String>(
          query: defaultQuery,
          execute: () => api.saveWorkflowDefault(workflowId)));
      if (epoch != _sessionEpoch) throw const AxMutationSuperseded();
      if (spaceId == null) {
        engine.invalidate(AxQueryKey(['workflow-default']), prefix: true);
        await engine
            .refreshStaleWhere(
                (key) => key.startsWith(AxQueryKey(['workflow-default'])))
            .then<void>((_) {}, onError: (Object _, StackTrace __) {});
      }
    } finally {
      if (identical(_writeLease, lease)) _writeLease = null;
    }
  }

  int _sessionEpoch = 0;
  Object? _writeLease;
  void clear() {
    _sessionEpoch++;
    _writeLease = null;
    engine.remove(queryKey);
    engine.remove(defaultQuery.key);
  }

  Future<void> save(AxUserWorkflowConfiguration value) =>
      _write(value.workflowId, () => _api.saveWorkflowConfiguration(value));
  Future<void> reset(String workflowId) =>
      _write(workflowId, () => _api.resetWorkflowConfiguration(workflowId));

  Future<void> _write(String workflowId,
      Future<AxUserWorkflowConfiguration> Function() execute) async {
    _requireWritable();
    if (_writeLease != null) {
      throw StateError('A workflow update is already pending');
    }
    final epoch = _sessionEpoch;
    final lease = Object();
    _writeLease = lease;
    try {
      await ensure();
      if (epoch != _sessionEpoch) {
        throw const AxMutationSuperseded();
      }
      await engine.mutate(AxMutation<List<AxUserWorkflowConfiguration>>(
          query: query,
          execute: () async {
            final result = await execute();
            return List.unmodifiable([
              ...?engine
                  .peek(query)
                  .data
                  ?.where((item) => item.workflowId != workflowId),
              result,
            ]);
          }));
      if (spaceId == null) {
        engine.invalidate(AxQueryKey(['space-workflow-configurations']),
            prefix: true);
        engine.invalidate(AxQueryKey(['workflow-default']), prefix: true);
        await engine
            .refreshStaleWhere((key) =>
                key.startsWith(AxQueryKey(['space-workflow-configurations'])) ||
                key.startsWith(AxQueryKey(['workflow-default'])))
            .then<void>((_) {}, onError: (Object _, StackTrace __) {});
      }
      if (source is AxWorkflowDefaultDataSource) {
        engine.invalidate(defaultQuery.key);
        await refreshDefault();
      }
    } finally {
      if (identical(_writeLease, lease)) {
        _writeLease = null;
      }
    }
  }
}
