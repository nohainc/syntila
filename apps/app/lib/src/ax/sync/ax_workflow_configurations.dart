import '../ax_data.dart';
import 'ax_sync_engine.dart';

/// Session-owned global, Workspace or Space preferences. Navigation reuses the
/// scoped query. User-level preferences are stored per Workspace: [workspaceId]
/// addresses one, otherwise Cloud uses the selected Workspace.
class AxWorkflowConfigurations {
  AxWorkflowConfigurations(this.source,
      {required this.engine, this.spaceId, this.workspaceId});
  final String? spaceId;
  final String? workspaceId;
  final Map<String, AxWorkflowConfigurations> _scoped = {};

  /// Preferences of one Workspace, shared per session.
  AxWorkflowConfigurations forWorkspace(String id) {
    assert(spaceId == null);
    return _scoped.putIfAbsent(
        id,
        () =>
            AxWorkflowConfigurations(source, engine: engine, workspaceId: id));
  }

  AxQueryKey get queryKey => spaceId != null
      ? AxQueryKey(['space-workflow-configurations', spaceId!])
      : workspaceId != null
          ? AxQueryKey(['user-workflow-configurations', workspaceId!])
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
          ? await _api.loadWorkflowConfigurations(workspaceId: workspaceId)
          : await _spaceApi.loadSpaceWorkflowConfigurations(spaceId!)));

  late final defaultQuery = AxQuery<String>(
      key: AxQueryKey(['workflow-default', spaceId ?? workspaceId ?? 'user']),
      staleTime: const Duration(minutes: 45),
      load: () async {
        final api = source is AxWorkflowDefaultDataSource
            ? source as AxWorkflowDefaultDataSource
            : null;
        if (api == null) return 'chat';
        return spaceId == null
            ? api.loadWorkflowDefault(workspaceId: workspaceId)
            : api.loadSpaceWorkflowDefault(spaceId!);
      });

  Future<List<AxUserWorkflowConfiguration>> ensure() =>
      engine.ensure(query, policy: AxCachePolicy.cacheFirst);
  Future<List<AxUserWorkflowConfiguration>> refresh() => engine.refresh(query);
  Future<String> ensureDefault() =>
      engine.ensure(defaultQuery, policy: AxCachePolicy.cacheFirst);
  Future<String> refreshDefault() => engine.refresh(defaultQuery);

  /// Space preferences are read-only: a Space follows its Workspace's workflows.
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
          execute: () =>
              api.saveWorkflowDefault(workflowId, workspaceId: workspaceId)));
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

  AxQueryKey get workspaceKey =>
      AxQueryKey(['workflow-workspace', spaceId ?? 'user']);
  late final workspaceQuery = AxQuery<AxWorkflowWorkspaceSettings>(
      key: workspaceKey,
      staleTime: const Duration(minutes: 45),
      load: () => (source as AxWorkflowWorkspaceDataSource)
          .loadWorkflowWorkspace(spaceId: spaceId));
  Future<AxWorkflowWorkspaceSettings> ensureWorkspace() =>
      engine.ensure(workspaceQuery, policy: AxCachePolicy.cacheFirst);
  Future<void> selectWorkspace(String? workspaceId) async {
    if (_writeLease != null) {
      throw StateError('A workflow update is already pending');
    }
    final epoch = _sessionEpoch;
    final lease = Object();
    _writeLease = lease;
    try {
      await engine.mutate(AxMutation<AxWorkflowWorkspaceSettings>(
          query: workspaceQuery,
          execute: () => (source as AxWorkflowWorkspaceDataSource)
              .selectWorkflowWorkspace(
                  spaceId: spaceId, workspaceId: workspaceId)));
      if (epoch != _sessionEpoch) throw const AxMutationSuperseded();
      // Space overrides of inheriting Spaces are reset on Cloud. Drop the old
      // values before reloading so a successful reset cannot leave a stale
      // Space default or disabled configuration visible while the new
      // effective settings are fetched.
      if (spaceId != null) {
        engine.remove(queryKey);
        engine.remove(defaultQuery.key);
      }
      // Refresh both resources independently. A transient configuration read
      // failure must not prevent the default workflow from being updated.
      await Future.wait<Object?>([refresh(), refreshDefault()]);
      if (epoch != _sessionEpoch) throw const AxMutationSuperseded();
      if (spaceId == null) {
        // User configuration is per Workspace and stays valid, but the
        // unscoped (selected Workspace) views now point elsewhere.
        engine.invalidate(AxQueryKey(['space-workflow-configurations']),
            prefix: true);
        engine.invalidate(AxQueryKey(['workflow-workspace']), prefix: true);
        engine.invalidate(AxQueryKey(['workflow-default']), prefix: true);
        engine.invalidate(key);
        await engine
            .refreshStaleWhere((key) =>
                key.startsWith(AxQueryKey(['space-workflow-configurations'])) ||
                key.startsWith(AxQueryKey(['workflow-workspace'])) ||
                key.startsWith(AxQueryKey(['workflow-default'])))
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
    engine.remove(workspaceKey);
    engine.remove(defaultQuery.key);
    for (final child in _scoped.values) {
      child.clear();
    }
  }

  Future<void> save(AxUserWorkflowConfiguration value) => _write(
      value.workflowId,
      () => _api.saveWorkflowConfiguration(value, workspaceId: workspaceId));
  Future<void> reset(String workflowId) => _write(
      workflowId,
      () => _api.resetWorkflowConfiguration(workflowId,
          workspaceId: workspaceId));

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
