import 'dart:async';
import 'dart:io';

import 'package:syntila_protocol/worker_descriptor.dart';
import 'package:syntila_external_worker_protocol/syntila_external_worker_protocol.dart'
    show negotiateExternalWorkerProtocol;
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

import 'local_worker_registry.dart';
import 'external_worker_executor.dart';
import 'external_worker_registry.dart';
import 'external_worker_service.dart';
import 'external_worker_store.dart';
import 'worker_readiness.dart';

/// Runs one Engine probe for a plugin. Production wires the supervisor.
typedef ExternalWorkerProbeRunner = Future<ProbeResult> Function({
  required WorkerExecutor executor,
  required String workerTypeId,
  required Directory stateDirectory,
  required WorkerProbeMode mode,
});

/// What a launch needs, verified at the moment of use.
class ExternalWorkerExecution {
  const ExternalWorkerExecution({
    required this.executor,
    required this.plugin,
    required this.readOnlyEnforced,
  });

  final WorkerExecutor executor;
  final InstalledExternalWorker plugin;

  /// True only when an isolation tier proved read-only on this host. Today no
  /// tier does, so a read-only Step is requested of the Worker, not enforced.
  final bool readOnlyEnforced;

  /// False when the manifest declares no working directory access
  /// (`access.workRoot: "none"`), e.g. a Worker that only calls a model.
  bool get writesWorkingDirectory =>
      (plugin.manifest.raw['access'] as Map?)?['workRoot'] != 'none';
}

/// Everything the Service does for an enabled plugin Worker: readiness,
/// effective enablement, pre-spawn verification and inventory projection.
/// Local checks here are a defence in depth and a UX hint; Cloud scheduling
/// and the signed lease remain the gate that matters.
class ExternalWorkerRuntime {
  ExternalWorkerRuntime({
    required this.store,
    required this.registry,
    required this.probe,
    required this.engineStateDirectory,
    this.engineProtocol = '1.2',
  });

  final ExternalWorkerStore store;
  final ExternalWorkerRegistry registry;
  final ExternalWorkerProbeRunner probe;
  final Directory Function(String pluginId) engineStateDirectory;
  final String engineProtocol;

  /// The pinned record when the user's intent is enabled.
  Future<({ExternalWorkerRecord record, ExternalWorkerPin pin})?> _pinned(
    String pluginRef,
  ) async {
    final record = await registry.findByRef(pluginRef);
    final pin = record?.pin;
    if (record == null || pin == null || !pin.enabled) return null;
    return (record: record, pin: pin);
  }

  /// Enabled intent. Used before any new plugin process may start; Syntila
  /// Plus is enforced by Cloud when it admits the assignment.
  Future<bool> isEffectivelyEnabled(String pluginRef) async =>
      await _pinned(pluginRef) != null;

  /// Verifies enablement and every byte of the pinned artifact,
  /// then returns the executor to launch. Throws a [ExternalWorkerException]
  /// with a stable code when anything is off. Nothing is spawned here.
  Future<ExternalWorkerExecution> prepareExecution(String pluginRef) async {
    final pinned = await _pinned(pluginRef);
    if (pinned == null) {
      throw const ExternalWorkerException(
        'plugin_not_enabled',
        'This External Worker is not enabled on this Workspace.',
      );
    }
    final version = pinned.record.versions[pinned.pin.version];
    final installed = await store.load(
      pinned.record.pluginId,
      pinned.pin.version,
      pinned.pin.manifestDigest,
      origin: version?.origin,
      signer: version?.signer,
    );
    if (version?.toolPins == null || version!.toolPins!.isEmpty) {
      throw const ExternalWorkerException(
        'plugin_conformance_required',
        'MCP Worker tools must be inspected and pinned.',
      );
    }
    return ExternalWorkerExecution(
      executor: workerExecutorFor(
        installed,
        store.dataDirectory(installed.pluginId),
        toolPins: version.toolPins,
      ),
      plugin: installed,
      readOnlyEnforced: false,
    );
  }

  /// Readiness for the monitor's passive and live checks.
  Future<WorkerReadinessAssessment> assess(
    LocalWorker worker,
    LocalWorkerProbeMode mode,
  ) async {
    final ExternalWorkerExecution execution;
    try {
      execution = await prepareExecution(worker.workerTypeId);
    } on ExternalWorkerException catch (error) {
      return WorkerReadinessAssessment(
        WorkerReadinessState.runtimeUnavailable,
        issueCode: error.code,
        diagnosticDetails: error.message,
      );
    }
    try {
      final result = await probe(
        executor: execution.executor,
        workerTypeId: worker.workerTypeId,
        stateDirectory: engineStateDirectory(execution.plugin.pluginId),
        mode: mode == LocalWorkerProbeMode.live
            ? WorkerProbeMode.live
            : WorkerProbeMode.passive,
      );
      return WorkerReadinessAssessment(
        result.ready
            ? WorkerReadinessState.ready
            : _stateFor(result.issueCode, mode),
        issueCode: result.issueCode,
        diagnosticDetails: result.diagnostics,
        checks: result.checks,
        modelCatalog: result.modelCatalog,
        toolName: execution.plugin.pluginId,
        replaceToolName: true,
        toolVersion: execution.plugin.version,
        replaceToolVersion: true,
        profileDigest: execution.plugin.manifestDigest,
      );
    } on Object catch (error) {
      final code = error is TimeoutException
          ? 'probe_timeout'
          : 'plugin_handshake_failed';
      return WorkerReadinessAssessment(
        WorkerReadinessState.runtimeUnavailable,
        issueCode: code,
        diagnosticDetails:
            'The External Worker could not complete its readiness probe.',
      );
    }
  }

  WorkerReadinessState _stateFor(
          String? issueCode, LocalWorkerProbeMode mode) =>
      switch (issueCode) {
        'provider_authentication_required' =>
          WorkerReadinessState.signInRequired,
        'provider_tool_unavailable' => WorkerReadinessState.setupRequired,
        'provider_unavailable' ||
        'profile_identity_mismatch' ||
        'profile_schema_incompatible' =>
          WorkerReadinessState.runtimeUnavailable,
        _ => mode == LocalWorkerProbeMode.live
            ? WorkerReadinessState.testFailed
            : WorkerReadinessState.runtimeUnavailable,
      };

  /// The Cloud inventory entry for a plugin Worker, or null when the plugin
  /// is not known here. `executor` is sent only to a Cloud that announced
  /// `workspace.worker_plugins.v1`; callers decide that.
  Future<Map<String, Object?>?> inventoryFor(
    LocalWorker worker, {
    required String engineVersion,
    required String lastSeenAt,
  }) async {
    final record = await registry.findByRef(worker.workerTypeId);
    final pin = record?.pin;
    if (record == null || pin == null) return null;
    final effective = pin.enabled;
    String? issue = worker.readinessIssueCode;
    var readiness = worker.readinessState.wireValue;
    InstalledExternalWorker? installed;
    if (effective) {
      try {
        final version = record.versions[pin.version];
        installed = await store.load(
          record.pluginId,
          pin.version,
          pin.manifestDigest,
          origin: version?.origin,
          signer: version?.signer,
        );
      } on ExternalWorkerException catch (error) {
        readiness = WorkerReadinessState.runtimeUnavailable.wireValue;
        issue = error.code;
      }
    } else {
      readiness = WorkerReadinessState.runtimeUnavailable.wireValue;
      issue = 'plugin_not_enabled';
    }
    final capabilities = installed == null
        ? const <String, Object?>{}
        : Map<String, Object?>.from(
            installed.manifest.raw['capabilities'] as Map,
          );
    final continuity = capabilities['continuity'];
    final resume = capabilities['sessionResume'] == true ||
        (continuity is Map &&
            const {'native_handle', 'checkpoint'}
                .contains(continuity['strategy']));
    return {
      'workerId': worker.id,
      'workerTypeId': worker.workerTypeId,
      'activationState': effective ? 'enabled' : 'disabled',
      'readinessState': readiness,
      if (issue != null) 'readinessIssueCode': issue,
      'engineVersion': installed == null ? null : engineVersion,
      'profileDefinitionId': null,
      'profileReleaseVersion': null,
      'providerToolName': record.pluginId,
      'providerToolVersion': pin.version,
      if (installed != null &&
          worker.modelCatalog?.profileDigest == pin.manifestDigest &&
          worker.modelCatalog?.providerToolVersion == pin.version)
        'modelCatalog': worker.modelCatalog!.toJson(includeNativeIds: false),
      'localConcurrencyLimit': worker.localConcurrencyLimit,
      'revision': worker.revision,
      'createdAt': worker.createdAt,
      'updatedAt': worker.updatedAt,
      'lastSeenAt': lastSeenAt,
      'executor': {
        'kind': 'plugin',
        'pluginId': record.pluginId,
        'version': pin.version,
        'manifestDigest': pin.manifestDigest,
        'artifactDigest': installed?.artifactDigest,
        'pluginProtocol': installed == null
            ? engineProtocol
            : negotiateExternalWorkerProtocol(installed.manifest),
        'isolation': {'tier': 'none', 'readOnlyEnforced': false},
        // "tested" needs evidence that a run resumed a session. The MCP
        // Worker profile check gives none, so this is at most "declared".
        'sessionResume': resume ? 'declared_untested' : 'none',
        'shareable': pin.shareable,
      },
    };
  }

  /// Descriptor used to create the local Worker record for a plugin.
  static WorkerDescriptor descriptorFor({
    required String pluginRef,
    required String pluginId,
    required String displayName,
  }) =>
      WorkerDescriptor(
        workerTypeId: pluginRef,
        displayName: displayName,
        description: 'External Worker $pluginId',
        engineFamily: 'cli',
        profileDefinitionId: 'plugin-$pluginId',
        providerToolName: pluginId,
        releaseStage: 'stable',
        visibilityState: 'visible',
        sortOrder: 1000,
      );
}

/// Local Worker records for plugins.
class LocalExternalWorkerHost implements ExternalWorkerHost {
  LocalExternalWorkerHost({required this.workers, this.afterChange});

  final LocalWorkerRegistry workers;

  /// Called after a change, for example to run a passive readiness check.
  final Future<void> Function(String pluginRef)? afterChange;

  Future<LocalWorker?> _find(String pluginRef) async => (await workers.list())
      .where((worker) => worker.workerTypeId == pluginRef)
      .firstOrNull;

  @override
  Future<void> activate({
    required String pluginRef,
    required String pluginId,
    required String displayName,
  }) async {
    final existing = await _find(pluginRef);
    if (existing == null) {
      await workers.create(
        catalogEntry: ExternalWorkerRuntime.descriptorFor(
          pluginRef: pluginRef,
          pluginId: pluginId,
          displayName: displayName,
        ),
        status: LocalWorkerStatus.needsAttention,
      );
    } else {
      await workers.update(
        existing.id,
        (current) => current.copyWith(
          status: LocalWorkerStatus.needsAttention,
          activationState: LocalWorkerActivationState.enabled,
        ),
      );
    }
    await afterChange?.call(pluginRef);
  }

  @override
  Future<void> deactivate(String pluginRef) async {
    final existing = await _find(pluginRef);
    if (existing != null) await workers.disable(existing.id);
  }

  @override
  Future<void> remove(String pluginRef) async {
    final existing = await _find(pluginRef);
    if (existing != null) await workers.remove(existing.id);
  }
}
