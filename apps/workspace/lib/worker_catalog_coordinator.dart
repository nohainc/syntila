import 'dart:async';

import 'worker_check_progress.dart';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart'
    show SafeProviderDiagnostics;

import 'cli_worker_engine_supervisor.dart';
import 'local_worker_registry.dart';
import 'external_worker_executor.dart' show isExternalWorkerType;
import 'tool_profile_catalog.dart';
import 'worker_profile_store.dart';
import 'tool_profile_release_verifier.dart';
import 'tool_profile_resolver.dart';
import 'worker_inventory_projection.dart';
import 'workspace_worker_view.dart';
import 'workspace_notifier.dart';

class WorkerCatalogSnapshot {
  const WorkerCatalogSnapshot({
    this.checks = const {},
    this.descriptors = const [],
    this.workers = const [],
    this.profiles = const {},
    this.catalogError,
    this.catalogConfirmed = false,
    this.refreshing = false,
    this.localRegistryLoaded = false,
    this.localRegistryError,
    this.removingWorkerIds = const {},
  });

  final Map<String, WorkerCheckProgress> checks;
  final List<WorkerDescriptor> descriptors;
  final List<WorkerCatalogWorkerState> workers;
  final Map<String, WorkerProfileResolution> profiles;
  final String? catalogError;
  final bool catalogConfirmed;
  final bool refreshing;
  final bool localRegistryLoaded;
  final String? localRegistryError;

  /// Local Worker IDs that take no new work and are removed once their
  /// current work finishes.
  final Set<String> removingWorkerIds;
}

abstract interface class WorkspaceWorkerCatalogClient {
  void addListener(void Function() listener);
  void removeListener(void Function() listener);
  WorkerCatalogSnapshot get snapshot;
  WorkerDescriptor? entryForWorker(String workerTypeId);
  Future<void> refresh({bool force = false});

  /// Checks one Worker for a newer Cloud catalog entry and Profile release,
  /// leaving every other Worker untouched.
  Future<void> refreshWorker(String workerTypeId);
  Future<void> refreshLocalWorkers();
  Future<void> ensureWorkerProfileAvailable(
    String workerTypeId, {
    bool waitForActiveRefresh = false,
  });
}

/// Owns the Workspace catalog -> Profile -> readiness synchronization pipeline.
/// Projects a plugin Worker for Cloud inventory, or null to omit it.
typedef ExternalWorkerInventoryProjection = Future<Map<String, Object?>?>
    Function(
  LocalWorker worker, {
  required String engineVersion,
  required String lastSeenAt,
});

class WorkerCatalogCoordinator extends WorkspaceNotifier
    implements WorkspaceWorkerCatalogClient {
  WorkerCatalogCoordinator({
    required this.catalog,
    required this.releaseStore,
    this.registry,
    this.onCatalogReconciled,
    this.refreshReadiness,
    this.refreshExecutor,
    this.minimumRefreshInterval = const Duration(minutes: 1),
  });

  final ToolProfileCatalogClient catalog;
  final WorkerProfileStorePort releaseStore;
  final LocalWorkerRegistry? registry;
  final Future<void> Function()? onCatalogReconciled;
  final Future<void> Function()? refreshReadiness;
  final Future<void> Function(Future<void> Function())? refreshExecutor;
  final Duration minimumRefreshInterval;

  WorkerCatalogSnapshot _snapshot = const WorkerCatalogSnapshot();
  @override
  WorkerCatalogSnapshot get snapshot => _snapshot;
  Future<void>? _activeRefresh;
  final Map<String, Future<void>> _activeProfileSyncs = {};
  final Map<String, Future<void>> _activeWorkerRefreshes = {};
  List<LocalWorker> _localWorkers = const [];
  bool _localRegistryLoaded = false;
  String? _localRegistryError;
  DateTime? _lastRefreshAt;
  int _generation = 0;
  bool _disposed = false;
  bool _refreshingReadiness = false;

  @override
  WorkerDescriptor? entryForWorker(String workerTypeId) =>
      catalog.entryForWorker(workerTypeId);

  String? profileDefinitionForWorker(String workerTypeId) =>
      catalog.profileDefinitionForWorker(workerTypeId);

  Future<ToolProfileResolution<ToolProfileCandidate>> resolveProfileForWorker({
    required String workerTypeId,
    required String engineVersion,
    bool synchronizeIfUnavailable = true,
  }) async {
    final descriptor = await ensureCatalogEntry(workerTypeId);
    if (descriptor == null) {
      return const ToolProfileResolution<
          ToolProfileReleaseAdmission>.unavailable(
        ToolProfileUnavailableReason.noEligibleRelease,
      );
    }
    return ToolProfileResolver(releaseStore).resolveForWorker(
      logicalWorkerTypeId: workerTypeId,
      profileDefinitionId: descriptor.profileDefinitionId,
      engineVersion: engineVersion,
      ensureAvailable: synchronizeIfUnavailable
          ? () => ensureWorkerProfileAvailable(
                workerTypeId,
                waitForActiveRefresh: true,
              )
          : null,
    );
  }

  Future<List<Map<String, Object?>>> inventoryForWorkers(
    Iterable<LocalWorker> workers, {
    required String engineVersion,
    required bool engineAvailable,
    ExternalWorkerInventoryProjection? externalWorkerInventory,
  }) async {
    final lastSeenAt = DateTime.now().toUtc().toIso8601String();
    final projected = await Future.wait(workers.map((worker) async {
      if (isExternalWorkerType(worker.workerTypeId)) {
        // Plugin Workers have no catalog entry or Profile. They are projected
        // only when the caller (a Cloud that announced plugin support) asks.
        return engineAvailable
            ? await externalWorkerInventory?.call(
                worker,
                engineVersion: engineVersion,
                lastSeenAt: lastSeenAt,
              )
            : null;
      }
      final descriptor = entryForWorker(worker.workerTypeId);
      if (descriptor == null) return null;
      ToolProfileCandidate? eligibleProfile;
      if (engineAvailable) {
        try {
          eligibleProfile = (await resolveProfileForWorker(
            workerTypeId: worker.workerTypeId,
            engineVersion: engineVersion,
            synchronizeIfUnavailable: false,
          ))
              .release;
        } on Object {
          // Invalid or unavailable local Profile evidence is non-ready.
        }
      }
      return spaceWorkerInventory(
        worker: worker,
        descriptor: descriptor,
        eligibleProfile: eligibleProfile,
        engineVersion: engineAvailable ? engineVersion : null,
        lastSeenAt: lastSeenAt,
      );
    }));
    return projected.whereType<Map<String, Object?>>().toList();
  }

  /// Reloads the local registry and republishes render-ready Worker states.
  /// Registry mutations call this through the runtime's onChanged hook.
  @override
  Future<void> refreshLocalWorkers() async {
    final currentRegistry = registry;
    try {
      _localWorkers = await currentRegistry?.list() ?? const <LocalWorker>[];
      _localRegistryLoaded = currentRegistry != null;
      _localRegistryError = null;
    } on Object catch (error) {
      _localWorkers = const [];
      _localRegistryLoaded = true;
      _localRegistryError = 'Local Worker state could not be loaded: $error';
    }
    _publish(
      _snapshot.copyWith(
        workers: _buildWorkerStates(),
        localRegistryLoaded: _localRegistryLoaded,
        localRegistryError: _localRegistryError,
        clearLocalRegistryError: _localRegistryError == null,
      ),
      _generation,
    );
  }

  List<WorkerCatalogWorkerState> _buildWorkerStates({
    List<WorkerDescriptor>? descriptors,
    Map<String, WorkerProfileResolution>? profiles,
    bool? catalogConfirmed,
  }) {
    final currentDescriptors = descriptors ?? _snapshot.descriptors;
    final currentProfiles = profiles ?? _snapshot.profiles;
    final isCatalogConfirmed = catalogConfirmed ?? _snapshot.catalogConfirmed;
    final views = currentDescriptors.map((descriptor) {
      final worker = _localWorkers
          .where((record) => record.workerTypeId == descriptor.workerTypeId)
          .firstOrNull;
      final profile = currentProfiles[descriptor.workerTypeId] ??
          const WorkerProfileResolution(
            state: WorkspaceWorkerProfileState.resolving,
          );
      final localState = !_localRegistryLoaded
          ? WorkspaceLocalWorkerState.loading
          : _localRegistryError != null
              ? WorkspaceLocalWorkerState.unavailable
              : worker == null
                  ? WorkspaceLocalWorkerState.notConfigured
                  : WorkspaceLocalWorkerState.configured;
      return WorkerCatalogWorkerState(
        descriptor: descriptor,
        catalogRetired: false,
        localWorker: worker,
        localState: localState,
        profileAvailability: profile,
        providerToolState: _providerToolState(worker),
      );
    }).toList();
    if (isCatalogConfirmed) {
      final currentTypes =
          currentDescriptors.map((worker) => worker.workerTypeId).toSet();
      for (final worker in _localWorkers.where(
        (worker) =>
            !currentTypes.contains(worker.workerTypeId) &&
            !isExternalWorkerType(worker.workerTypeId),
      )) {
        views.add(WorkerCatalogWorkerState(
          descriptor: null,
          catalogRetired: true,
          localWorker: worker,
          localState: WorkspaceLocalWorkerState.configured,
          profileAvailability: const WorkerProfileResolution(
            state: WorkspaceWorkerProfileState.unavailable,
            message: 'Worker is no longer in the current Cloud catalog.',
          ),
          providerToolState: _providerToolState(worker),
        ));
      }
    }
    return List.unmodifiable(views);
  }

  WorkspaceProviderToolState _providerToolState(LocalWorker? worker) {
    if (worker == null) return WorkspaceProviderToolState.unknown;
    if (worker.readinessIssueCode == 'provider_tool_unavailable' ||
        worker.lastLiveTestIssueCode == 'provider_tool_unavailable' ||
        worker.readinessIssueCode == 'cli_not_found' ||
        worker.lastLiveTestIssueCode == 'cli_not_found') {
      return WorkspaceProviderToolState.missing;
    }
    return worker.toolVersion != null
        ? WorkspaceProviderToolState.available
        : WorkspaceProviderToolState.unknown;
  }

  /// Excludes retained local records whose Worker Type is no longer in the
  /// last-known-good or authoritative catalog before reporting inventory.
  List<LocalWorker> inventoryEligibleWorkers(Iterable<LocalWorker> workers) =>
      workers
          .where((worker) => entryForWorker(worker.workerTypeId) != null)
          .toList();

  /// Resolves assignment eligibility against the newest known authoritative
  /// catalog. A locally cached entry remains usable offline; absence is
  /// authoritative only after a successful catalog synchronization.
  Future<WorkerDescriptor?> ensureCatalogEntry(String workerTypeId) async {
    var entry = entryForWorker(workerTypeId);
    if (entry != null || _snapshot.catalogConfirmed) return entry;

    final activeRefresh = _activeRefresh;
    if (activeRefresh != null) {
      await activeRefresh;
    } else {
      await refresh(force: true);
    }
    entry = entryForWorker(workerTypeId);
    return entry;
  }

  void start() {
    if (_started) return;
    _started = true;
    unawaited(refreshLocalWorkers());
    unawaited(refresh());
  }

  bool _started = false;

  @override
  Future<void> refresh({bool force = false}) {
    final active = _activeRefresh;
    if (active != null) return active;
    final lastRefreshAt = _lastRefreshAt;
    if (!force &&
        lastRefreshAt != null &&
        DateTime.now().difference(lastRefreshAt) < minimumRefreshInterval) {
      return Future<void>.value();
    }
    _publish(_snapshot.copyWith(refreshing: true), _generation);
    final operation = refreshExecutor == null
        ? _refreshCatalogAndProfiles()
        : refreshExecutor!(_refreshCatalogAndProfiles);
    _activeRefresh = operation;
    return operation.whenComplete(() {
      if (identical(_activeRefresh, operation)) _activeRefresh = null;
      _lastRefreshAt = DateTime.now();
    });
  }

  Future<void> _refreshCatalogAndProfiles() async {
    await refreshLocalWorkers();
    var generation = ++_generation;
    var cached = _snapshot.descriptors;
    Future<void>? cachedProfileResolution;
    try {
      cached = await catalog.loadCatalog();
      if (cached.isNotEmpty) {
        _publishCatalog(cached, generation, refreshing: true);
        await _notifyCatalogReconciled();
        cachedProfileResolution =
            _resolveProfiles(_addedWorkers(cached), generation);
      }
    } on Object {
      // A malformed cache is ignored; the Cloud catalog remains authoritative.
    }

    List<WorkerDescriptor> current;
    String? catalogError;
    var catalogConfirmed = false;
    if (!catalog.canSyncCatalogRemotely) {
      // A disconnected Workspace has no runtime identity for the Cloud
      // endpoint. Keep the last known catalog (or local in-memory state)
      // visible without surfacing that expected state as an error.
      current = catalog.workers.isNotEmpty ? catalog.workers : cached;
    } else {
      try {
        current = await catalog.syncCatalog();
        catalogConfirmed = true;
      } on Object catch (error) {
        current = catalog.workers.isNotEmpty ? catalog.workers : cached;
        catalogError = 'Cloud Worker catalog could not be loaded: $error';
      }
    }

    generation = ++_generation;
    _publishCatalog(
      current,
      generation,
      catalogError: catalogError,
      refreshing: true,
      catalogConfirmed: catalogConfirmed,
    );
    await _notifyCatalogReconciled();
    await cachedProfileResolution;
    await _syncAndResolveProfiles(_addedWorkers(current), generation);
    _refreshingReadiness = true;
    try {
      await refreshReadiness?.call();
    } on Object {
      // Keep catalog/Profile state; the next readiness-triggered check retries.
    } finally {
      _refreshingReadiness = false;
    }
    await refreshLocalWorkers();
    _publish(
      _snapshot.copyWith(refreshing: false),
      generation,
    );
  }

  Future<void> _notifyCatalogReconciled() async {
    try {
      await onCatalogReconciled?.call();
    } on Object {
      // Inventory transport failure does not invalidate local catalog state.
    }
  }

  @override
  Future<void> refreshWorker(String workerTypeId) {
    // A full refresh already covers this Worker.
    final activeRefresh = _activeRefresh;
    if (activeRefresh != null) return activeRefresh;
    final active = _activeWorkerRefreshes[workerTypeId];
    if (active != null) return active;
    final operation = _refreshSingleWorker(workerTypeId);
    _activeWorkerRefreshes[workerTypeId] = operation;
    return operation.whenComplete(() {
      if (identical(_activeWorkerRefreshes[workerTypeId], operation)) {
        _activeWorkerRefreshes.remove(workerTypeId);
      }
    });
  }

  Future<void> _refreshSingleWorker(String workerTypeId) async {
    // The current generation is reused so concurrent per-Worker Profile
    // syncs for other Workers keep publishing their results.
    final generation = _generation;
    if (catalog.canSyncCatalogRemotely) {
      try {
        final current = await catalog.syncCatalog();
        _publishCatalog(current, generation, catalogConfirmed: true);
        await _notifyCatalogReconciled();
      } on Object catch (error) {
        _publish(
          _snapshot.copyWith(
              catalogError: 'Cloud Worker catalog could not be loaded: $error'),
          generation,
        );
      }
    }
    final entry = catalog.entryForWorker(workerTypeId) ??
        _snapshot.descriptors
            .where((worker) => worker.workerTypeId == workerTypeId)
            .firstOrNull;
    if (entry != null) await _syncAndResolveWorker(entry, generation);
    await refreshLocalWorkers();
  }

  /// Ensures a single assignment/readiness fallback uses the same Profile
  /// synchronization and selection policy as the full catalog refresh.
  @override
  Future<void> ensureWorkerProfileAvailable(
    String workerTypeId, {
    bool waitForActiveRefresh = false,
  }) async {
    if (_refreshingReadiness) return;
    final activeRefresh = _activeRefresh;
    if (activeRefresh != null) {
      if (waitForActiveRefresh) await activeRefresh;
      return;
    }
    var entry = catalog.entryForWorker(workerTypeId);
    if (entry == null) {
      try {
        final current = await catalog.syncCatalog();
        final generation = ++_generation;
        _publishCatalog(current, generation, catalogConfirmed: true);
        entry = current
            .where((worker) => worker.workerTypeId == workerTypeId)
            .firstOrNull;
      } on Object {
        return;
      }
    }
    if (entry == null) return;
    await _syncAndResolveWorker(entry, _generation);
  }

  /// Catalog entries the user added to this Workspace. Profiles are only
  /// downloaded and verified for these; the rest of the Cloud catalog is
  /// display metadata for the Add Worker picker.
  List<WorkerDescriptor> _addedWorkers(List<WorkerDescriptor> descriptors) {
    if (registry == null) return descriptors;
    final added = _localWorkers.map((worker) => worker.workerTypeId).toSet();
    return descriptors
        .where((descriptor) => added.contains(descriptor.workerTypeId))
        .toList(growable: false);
  }

  Future<void> _syncAndResolveProfiles(
    List<WorkerDescriptor> workers,
    int generation,
  ) =>
      catalog.withSharedTrustRefresh(() async {
        for (final worker in workers) {
          await _syncAndResolveWorker(worker, generation);
        }
      });

  Future<void> _syncAndResolveWorker(
    WorkerDescriptor worker,
    int generation,
  ) {
    final active = _activeProfileSyncs[worker.workerTypeId];
    if (active != null) return active;
    final operation = _runProfileSync(worker, generation);
    _activeProfileSyncs[worker.workerTypeId] = operation;
    return operation.whenComplete(() {
      if (identical(_activeProfileSyncs[worker.workerTypeId], operation)) {
        _activeProfileSyncs.remove(worker.workerTypeId);
      }
    });
  }

  Future<void> _runProfileSync(
    WorkerDescriptor worker,
    int generation,
  ) async {
    List<ToolProfileCandidate> downloaded;
    _setProfile(
      worker.workerTypeId,
      const WorkerProfileResolution(
        state: WorkspaceWorkerProfileState.syncing,
      ),
      generation,
    );
    try {
      downloaded = await catalog.syncWorkerProfiles(worker.workerTypeId);
    } on Object catch (error) {
      // A verified cached Profile can remain usable when Cloud is unavailable.
      await _resolveAndSetProfile(worker, generation);
      final cached = _snapshot.profiles[worker.workerTypeId];
      if (cached?.state != WorkspaceWorkerProfileState.ready) {
        _setProfile(
            worker.workerTypeId,
            WorkerProfileResolution(
              state: WorkspaceWorkerProfileState.error,
              details: error is WorkerProfileProbeFailure
                  ? {'issueCode': error.issueCode}
                  : null,
              message: error is WorkerProfileProbeFailure
                  ? 'Profile downloaded; activation blocked: ${workerIssueLabel(error.issueCode)}. ${workerIssueRecovery(error.issueCode)}'
                  : 'Profile download failed: ${SafeProviderDiagnostics.redact(error.toString())}',
            ),
            generation);
      }
      return;
    }
    await _resolveAndSetProfile(worker, generation);
    // The Service cannot probe a first-time Worker until Configure creates
    // its local record. A verified download is staged, not execution-ready.
    if (downloaded.isNotEmpty &&
        _localRegistryLoaded &&
        _localRegistryError == null &&
        !_localWorkers
            .any((local) => local.workerTypeId == worker.workerTypeId) &&
        _snapshot.profiles[worker.workerTypeId]?.state ==
            WorkspaceWorkerProfileState.unavailable) {
      _setProfile(
        worker.workerTypeId,
        WorkerProfileResolution(
          state: WorkspaceWorkerProfileState.staged,
          details: {
            'definitionId': worker.profileDefinitionId,
          },
          message:
              'Profile downloaded. Configure this Worker, then run a live test.',
        ),
        generation,
      );
    }
  }

  Future<void> _resolveProfiles(
    List<WorkerDescriptor> workers,
    int generation,
  ) async {
    for (final worker in workers) {
      await _resolveAndSetProfile(worker, generation);
    }
  }

  Future<void> _resolveAndSetProfile(
    WorkerDescriptor entry,
    int generation,
  ) async {
    final definitionId = entry.profileDefinitionId;
    try {
      final resolver = ToolProfileResolver(releaseStore);
      final resolution = await resolver.resolveForWorker(
        logicalWorkerTypeId: entry.workerTypeId,
        profileDefinitionId: definitionId,
        engineVersion: cliWorkerEngineVersion,
      );
      if (!resolution.isAvailable) {
        final incompatible = resolution.reason ==
            ToolProfileUnavailableReason.incompatibleEngineVersion;
        _setProfile(
          entry.workerTypeId,
          WorkerProfileResolution(
            state: incompatible
                ? WorkspaceWorkerProfileState.incompatible
                : WorkspaceWorkerProfileState.unavailable,
            message: switch (resolution.reason) {
              ToolProfileUnavailableReason.noEligibleRelease =>
                'No eligible current Worker Profile is available for this '
                    'Worker. Refresh the current published Profile or '
                    'restore connectivity to use the authorized cache.',
              ToolProfileUnavailableReason.incompatibleEngineVersion =>
                'The current Profile is not compatible with this Engine version.',
              null => 'No compatible Worker Profile is available.',
            },
            details: {
              'definitionId': definitionId,
            },
          ),
          generation,
        );
        return;
      }
      _setProfile(
        entry.workerTypeId,
        WorkerProfileResolution(
          state: WorkspaceWorkerProfileState.ready,
          details: {
            'definitionId': definitionId,
            'source': resolution.source.name,
            if (resolution.release != null)
              'hasModelDiscovery': (resolution.release!.profile['model']
                      as Map?)?['discovery'] !=
                  null,
            if (resolution.release != null)
              'staticModelNames':
                  _staticModelNames(resolution.release!.profile),
            if (resolution.release != null)
              'supportsFullAccess':
                  _profileMapsFullAccess(resolution.release!.profile),
            'unpublishedDevelopment': resolution.release?.isPublished == false,
            if (resolution.release != null)
              'releaseVersion': resolution.release!.releaseVersion,
            if (resolution.release != null)
              'revision': resolution.release!.revision,
          },
        ),
        generation,
      );
    } on Object {
      _setProfile(
        entry.workerTypeId,
        const WorkerProfileResolution(
          state: WorkspaceWorkerProfileState.error,
          message: 'A local Worker Profile could not be resolved.',
        ),
        generation,
      );
    }
  }

  void _publishCatalog(
    List<WorkerDescriptor> workers,
    int generation, {
    String? catalogError,
    bool refreshing = false,
    bool catalogConfirmed = false,
  }) {
    final previous = _snapshot.profiles;
    final previousDefinitions = {
      for (final worker in _snapshot.descriptors)
        worker.workerTypeId: worker.profileDefinitionId,
    };
    final added =
        _addedWorkers(workers).map((worker) => worker.workerTypeId).toSet();
    final nextProfiles = {
      for (final worker in workers)
        worker.workerTypeId: !added.contains(worker.workerTypeId)
            // Not added here: no Profile is resolved, so none is pending.
            ? const WorkerProfileResolution(
                state: WorkspaceWorkerProfileState.unavailable,
              )
            : previousDefinitions[worker.workerTypeId] ==
                    worker.profileDefinitionId
                ? previous[worker.workerTypeId] ??
                    const WorkerProfileResolution(
                      state: WorkspaceWorkerProfileState.resolving,
                    )
                : const WorkerProfileResolution(
                    state: WorkspaceWorkerProfileState.resolving,
                  ),
    };
    final confirmed = catalogConfirmed || _snapshot.catalogConfirmed;
    _publish(
      WorkerCatalogSnapshot(
        descriptors: List.unmodifiable(workers),
        workers: _buildWorkerStates(
          descriptors: workers,
          profiles: nextProfiles,
          catalogConfirmed: confirmed,
        ),
        profiles: nextProfiles,
        catalogError: catalogError,
        catalogConfirmed: confirmed,
        refreshing: refreshing,
        localRegistryLoaded: _snapshot.localRegistryLoaded,
        localRegistryError: _snapshot.localRegistryError,
      ),
      generation,
    );
  }

  void _setProfile(
    String workerTypeId,
    WorkerProfileResolution resolution,
    int generation,
  ) {
    final profiles = Map<String, WorkerProfileResolution>.from(
      _snapshot.profiles,
    )..[workerTypeId] = resolution;
    _publish(
      _snapshot.copyWith(
        profiles: profiles,
        workers: _buildWorkerStates(profiles: profiles),
      ),
      generation,
    );
  }

  void _publish(WorkerCatalogSnapshot snapshot, int generation) {
    if (_disposed || generation != _generation) return;
    _snapshot = snapshot;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

extension on WorkerCatalogSnapshot {
  WorkerCatalogSnapshot copyWith({
    List<WorkerDescriptor>? descriptors,
    List<WorkerCatalogWorkerState>? workers,
    Map<String, WorkerProfileResolution>? profiles,
    String? catalogError,
    bool clearCatalogError = false,
    bool? catalogConfirmed,
    bool? refreshing,
    bool? localRegistryLoaded,
    String? localRegistryError,
    bool clearLocalRegistryError = false,
  }) =>
      WorkerCatalogSnapshot(
        descriptors: descriptors ?? this.descriptors,
        workers: workers ?? this.workers,
        profiles: profiles ?? this.profiles,
        catalogError:
            clearCatalogError ? null : catalogError ?? this.catalogError,
        catalogConfirmed: catalogConfirmed ?? this.catalogConfirmed,
        refreshing: refreshing ?? this.refreshing,
        localRegistryLoaded: localRegistryLoaded ?? this.localRegistryLoaded,
        localRegistryError: clearLocalRegistryError
            ? null
            : localRegistryError ?? this.localRegistryError,
      );
}

/// Whether the active signed profile maps `full_access` to provider arguments.
/// Display projection only; the Engine remains authoritative at run time.
bool _profileMapsFullAccess(Map<String, Object?> profile) {
  final sandbox = profile['sandbox'];
  final mappings = sandbox is Map ? sandbox['mappings'] : null;
  final mapping = mappings is Map ? mappings['full_access'] : null;
  return mapping is List && mapping.isNotEmpty;
}

// Safe display projection only; discovery and runtime state remain authoritative.
List<String> _staticModelNames(Map<String, Object?> profile) {
  final model = profile['model'];
  if (model is! Map || model['supported'] != true) return const [];
  final catalog = model['catalog'];
  if (catalog is! List) return const [];
  final allowlist = model['allowlist'];
  return catalog
      .whereType<Map>()
      .where((entry) =>
          entry['status'] != 'unavailable' &&
          (allowlist is! List || allowlist.contains(entry['id'])))
      .map((entry) => entry['name'])
      .whereType<String>()
      .where((name) => name.isNotEmpty)
      .toList();
}
