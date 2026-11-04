import 'dart:async';
import 'dart:io';

import 'package:syntila_protocol/worker_descriptor.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

import 'local_worker_registry.dart';
import 'plugin_entitlement.dart';
import 'plugin_executor.dart';
import 'plugin_registry.dart';
import 'plugin_service.dart';
import 'plugin_store.dart';
import 'worker_readiness.dart';

/// Runs one Engine probe for a plugin. Production wires the supervisor.
typedef PluginProbeRunner = Future<ProbeResult> Function({
  required WorkerExecutor executor,
  required String workerTypeId,
  required Directory stateDirectory,
  required WorkerProbeMode mode,
});

/// What a launch needs, verified at the moment of use.
class PluginExecution {
  const PluginExecution({
    required this.executor,
    required this.plugin,
    required this.readOnlyEnforced,
  });

  final WorkerExecutor executor;
  final InstalledPlugin plugin;

  /// True only when an isolation tier proved read-only on this host. Today no
  /// tier does, so read-only Steps are refused for plugins (the honest rule).
  final bool readOnlyEnforced;
}

/// Everything the Service does for an enabled plugin Worker: readiness,
/// effective enablement, pre-spawn verification and inventory projection.
/// Local checks here are a defence in depth and a UX hint; Cloud scheduling
/// and the signed lease remain the gate that matters.
class PluginWorkerRuntime {
  PluginWorkerRuntime({
    required this.store,
    required this.registry,
    required this.entitlement,
    required this.probe,
    required this.engineStateDirectory,
    this.engineProtocol = '1.0',
  });

  final PluginStore store;
  final PluginRegistry registry;
  final PluginEntitlementStore entitlement;
  final PluginProbeRunner probe;
  final Directory Function(String pluginId) engineStateDirectory;
  final String engineProtocol;

  /// The pinned record when the user's intent is enabled.
  Future<({PluginRecord record, PluginPin pin})?> _pinned(
    String pluginRef,
  ) async {
    final record = await registry.findByRef(pluginRef);
    final pin = record?.pin;
    if (record == null || pin == null || !pin.enabled) return null;
    return (record: record, pin: pin);
  }

  /// Intent AND entitled. Used before any new plugin process may start.
  Future<bool> isEffectivelyEnabled(String pluginRef) async =>
      await _pinned(pluginRef) != null && (await entitlement.status()).entitled;

  /// Verifies enablement, entitlement and every byte of the pinned artifact,
  /// then returns the executor to launch. Throws a [PluginServiceException]
  /// with a stable code when anything is off. Nothing is spawned here.
  Future<PluginExecution> prepareExecution(String pluginRef) async {
    final pinned = await _pinned(pluginRef);
    if (pinned == null) {
      throw const PluginServiceException(
        'plugin_not_enabled',
        'This plugin is not enabled on this Workspace.',
      );
    }
    if (!(await entitlement.status()).entitled) {
      throw const PluginServiceException(
        'plugin_entitlement_lapsed',
        'Custom Worker plugins are paused: Syntila Plus is not active.',
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
    return PluginExecution(
      executor: workerExecutorFor(
        installed,
        store.dataDirectory(installed.pluginId),
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
    final PluginExecution execution;
    try {
      execution = await prepareExecution(worker.workerTypeId);
    } on PluginServiceException catch (error) {
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
        diagnosticDetails: 'The plugin could not complete its readiness probe.',
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
    final entitled = (await entitlement.status()).entitled;
    final effective = pin.enabled && entitled;
    String? issue = worker.readinessIssueCode;
    var readiness = worker.readinessState.wireValue;
    InstalledPlugin? installed;
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
      } on PluginServiceException catch (error) {
        readiness = WorkerReadinessState.runtimeUnavailable.wireValue;
        issue = error.code;
      }
    } else {
      readiness = WorkerReadinessState.runtimeUnavailable.wireValue;
      issue = pin.enabled ? 'plugin_entitlement_lapsed' : 'plugin_not_enabled';
    }
    final version = record.versions[pin.version];
    final capabilities = installed == null
        ? const <String, Object?>{}
        : Map<String, Object?>.from(
            installed.manifest.raw['capabilities'] as Map,
          );
    final resume = capabilities['sessionResume'] == true;
    final conformancePassed = version?.conformance?.passed == true;
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
        'pluginProtocol': engineProtocol,
        'isolation': {'tier': 'none', 'readOnlyEnforced': false},
        'sessionResume': !resume
            ? 'none'
            : conformancePassed
                ? 'tested'
                : 'declared_untested',
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
        description: 'Custom plugin $pluginId',
        engineFamily: 'cli',
        profileDefinitionId: 'plugin-$pluginId',
        providerToolName: pluginId,
        releaseStage: 'stable',
        visibilityState: 'visible',
        sortOrder: 1000,
      );
}

/// Local Worker records for plugins.
class LocalPluginWorkerHost implements PluginWorkerHost {
  LocalPluginWorkerHost({required this.workers, this.afterChange});

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
        catalogEntry: PluginWorkerRuntime.descriptorFor(
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

/// Bounds how long plugin work may run after Syntila Plus lapses. New spawns
/// stop immediately (see [PluginWorkerRuntime.prepareExecution]); work that
/// was already running finishes, like admitted Work after any other downgrade
/// (ADR-022), but only for [drain] (30 minutes by default), because a plugin
/// is user-supplied code. Call [tick] periodically.
class PluginLapseEnforcer {
  PluginLapseEnforcer({
    required this.entitlement,
    required this.cancelPluginWork,
    DateTime Function()? clock,
    this.drain = pluginLapseDrainMax,
  }) : _clock = clock ?? DateTime.now;

  final PluginEntitlementStore entitlement;

  /// Cancels all running plugin assignments and returns how many Workers had
  /// work to cancel.
  final Future<int> Function() cancelPluginWork;
  final Duration drain;
  final DateTime Function() _clock;
  DateTime? _lapsedAt;

  /// When the current lapse was first noticed, or null while entitled.
  DateTime? get lapsedAt => _lapsedAt;

  Future<int> tick() async {
    final status = await entitlement.status();
    if (status.entitled) {
      _lapsedAt = null;
      return 0;
    }
    final now = _clock();
    _lapsedAt ??= now;
    if (now.difference(_lapsedAt!) < drain) return 0;
    return cancelPluginWork();
  }
}
