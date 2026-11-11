import 'dart:async';
import 'dart:io';

import 'worker_check_progress.dart';
import 'workspace_notifier.dart';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart'
    show ToolProfileResolution;

import 'local_worker_registry.dart';
import 'external_worker_executor.dart' show isExternalWorkerType;
import 'cli_worker_engine_supervisor.dart';
import 'worker_profile_store.dart';
import 'tool_profile_release_verifier.dart';
import 'worker_catalog_coordinator.dart';
import 'worker_diagnostic_store.dart';
import 'workspace_registration.dart';

enum LocalWorkerProbeMode { passive, live }

class WorkerReadinessAssessment {
  const WorkerReadinessAssessment(
    this.state, {
    this.issueCode,
    this.diagnosticDetails,
    this.toolVersion,
    this.replaceToolVersion = false,
    this.toolName,
    this.replaceToolName = false,
    this.toolPath,
    this.replaceToolPath = false,
    this.modelCatalog,
    this.profileDigest,
    this.checks = const [],
  });

  final WorkerReadinessState state;
  final String? issueCode;
  final String? diagnosticDetails;
  final String? toolVersion;
  final bool replaceToolVersion;
  final String? toolName;
  final bool replaceToolName;
  final String? toolPath;
  final bool replaceToolPath;
  final DiscoveredModelCatalog? modelCatalog;
  final String? profileDigest;

  /// Individual Engine checks from the probe, in execution order.
  final List<ProbeCheck> checks;
}

class WorkerReadinessMonitor extends WorkspaceNotifier {
  WorkerReadinessMonitor({
    required this.registry,
    this.toolProfileReleaseStore,
    this.workerCatalogCoordinator,
    this.cliWorkerEngineSupervisor,
    this.workerStateDirectory,
    this.profileDiagnosticStoreForWorker,
    this.assessWorker,
    this.externalWorkerAssessor,
    this.refreshInterval = const Duration(minutes: 1),
  });

  final LocalWorkerRegistry registry;
  final WorkerProfileStorePort? toolProfileReleaseStore;
  final WorkerCatalogCoordinator? workerCatalogCoordinator;
  final CliWorkerEngineSupervisor? cliWorkerEngineSupervisor;
  final Directory Function(String workerId)? workerStateDirectory;
  final WorkerDiagnosticStore Function(String workerTypeId)?
      profileDiagnosticStoreForWorker;
  final Future<WorkerReadinessAssessment> Function(LocalWorker worker)?
      assessWorker;

  /// Assesses plugin Workers (ADR-027). They have no Tool Profile, so the
  /// Profile path below never sees them.
  final Future<WorkerReadinessAssessment> Function(
    LocalWorker worker,
    LocalWorkerProbeMode mode,
  )? externalWorkerAssessor;
  final Duration refreshInterval;
  Timer? _refreshTimer;

  bool _isExternalWorker(LocalWorker worker) =>
      externalWorkerAssessor != null &&
      isExternalWorkerType(worker.workerTypeId);
  bool _disposed = false;
  bool _started = false;
  ({LocalWorkerProbeMode mode, String? type, bool disabled})? _activeScope;
  final Map<String, Future<void>> _queuedChecks = {};
  Future<void>? _activeCheck;

  final Map<String, WorkerCheckProgress> _checks = {};
  Map<String, WorkerCheckProgress> get checks => Map.unmodifiable(_checks);

  void _progress(String type, LocalWorkerProbeMode mode, WorkerCheckPhase phase,
      {WorkerCheckOutcome outcome = WorkerCheckOutcome.running,
      String? issueCode,
      List<ProbeCheck> checks = const []}) {
    final prior = _checks[type];
    _checks[type] = WorkerCheckProgress(
      mode: mode.name,
      phase: phase,
      outcome: outcome,
      startedAt: prior?.outcome == WorkerCheckOutcome.running
          ? prior!.startedAt
          : DateTime.now().toUtc().toIso8601String(),
      completedAt: outcome == WorkerCheckOutcome.running
          ? null
          : DateTime.now().toUtc().toIso8601String(),
      issueCode: issueCode,
      steps: [
        for (final check in checks)
          WorkerCheckStep(
            code: check.code,
            status: check.status.name,
            message: check.message,
          ),
      ],
    );
    notifyListeners();
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _disposed = false;
    if (refreshInterval > Duration.zero) {
      _refreshTimer =
          Timer.periodic(refreshInterval, (_) => unawaited(_checkSafely()));
    }
    for (final worker in await registry.list()) {
      if (worker.activationState != LocalWorkerActivationState.enabled ||
          worker.status != LocalWorkerStatus.ready) {
        continue;
      }
      await registry.update(
        worker.id,
        (current) => current.copyWith(
          status: LocalWorkerStatus.needsAttention,
          activationState: current.activationState,
          readinessState: WorkerReadinessState.notProbed,
          readinessIssueCode: 'probe_required',
        ),
      );
    }
    unawaited(_checkSafely());
  }

  Future<void> _checkSafely({
    LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
  }) async {
    try {
      await checkNow(mode: mode, includeDisabled: true);
    } on Object {
      // Preserve the last safe state and retry on the next lifecycle event.
    }
  }

  Future<void> checkNow({
    LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
    String? workerTypeId,
    bool includeDisabled = false,
    bool rerunWhenActive = false,
  }) {
    if (_disposed) return Future.value();
    final active = _activeCheck;
    if (active != null) {
      final scope = _activeScope!;
      if (!rerunWhenActive &&
          scope.mode == mode &&
          (scope.type == null || scope.type == workerTypeId) &&
          (scope.disabled || !includeDisabled)) {
        return active;
      }
      final key = '${mode.name}:${workerTypeId ?? '*'}:$includeDisabled';
      final queued = _queuedChecks[key];
      if (queued != null) return queued;
      late final Future<void> pending;
      pending = active.catchError((_) {}).then((_) {
        _queuedChecks.remove(key);
        return checkNow(
            mode: mode,
            workerTypeId: workerTypeId,
            includeDisabled: includeDisabled);
      }).whenComplete(() {
        if (identical(_queuedChecks[key], pending)) _queuedChecks.remove(key);
      });
      _queuedChecks[key] = pending;
      return pending;
    }
    final check = _checkAll(
      mode: mode,
      workerTypeId: workerTypeId,
      includeDisabled: includeDisabled,
    );
    _activeScope = (mode: mode, type: workerTypeId, disabled: includeDisabled);
    final tracked = check.whenComplete(() {
      _activeCheck = null;
      _activeScope = null;
    });
    _activeCheck = tracked;
    return tracked;
  }

  /// Validates and atomically activates the trusted last-known-good Profile.
  /// Rollback is a snapshot restore, never a channel or release selection.
  Future<bool> rollbackToolProfile(String workerTypeId) async {
    final timer = Stopwatch()..start();
    final store = toolProfileReleaseStore;
    final engine = cliWorkerEngineSupervisor;
    if (store is! WorkerProfileStore || engine == null) {
      return false;
    }
    final worker = (await registry.list(includeRemoved: true))
        .where((item) =>
            item.workerTypeId == workerTypeId &&
            item.status != LocalWorkerStatus.removed)
        .firstOrNull;
    if (worker == null) return false;
    final stateDirectory = workerStateDirectory?.call(worker.id);
    if (stateDirectory == null) return false;

    final runId = 'profile-rollback-${DateTime.now().microsecondsSinceEpoch}';
    var issueCode = 'tool_profile_unavailable';
    ProbeResult? candidateProbe;
    try {
      final rolledBack = await store.restoreLastKnownGood(
        workerTypeId,
        validator: (candidate) async {
          try {
            candidateProbe = await engine.probe(
              candidate,
              profileFile: await store.executionProfileFile(candidate),
              stateDirectory: stateDirectory,
              mode: WorkerProbeMode.passive,
              timeout: const Duration(seconds: 20),
            );
          } on Object catch (error) {
            issueCode = error is CliWorkerEngineProbeException
                ? error.issueCode
                : error is TimeoutException
                    ? 'deadline_exceeded'
                    : 'provider_failure';
            return false;
          }
          final result = candidateProbe!;
          if (!result.ready) {
            issueCode = result.issueCode ?? 'provider_failure';
            return false;
          }
          return true;
        },
      );
      final result = candidateProbe;
      if (result == null || !result.ready) return false;
      await _recordToolProfileDiagnostic(
        worker,
        runId: runId,
        mode: LocalWorkerProbeMode.passive,
        durationMs: timer.elapsedMilliseconds,
        profileDefinitionId: rolledBack.profileDefinitionId,
        profileReleaseVersion: rolledBack.revision,
        profileResolutionSource: 'lastKnownGood',
        providerToolName: result.providerToolName,
        providerToolVersion: result.providerToolVersion,
      );
      await checkNow(
        mode: LocalWorkerProbeMode.passive,
        workerTypeId: workerTypeId,
        includeDisabled: true,
      );
      return true;
    } on Object {
      await _recordToolProfileDiagnostic(
        worker,
        runId: runId,
        mode: LocalWorkerProbeMode.passive,
        durationMs: timer.elapsedMilliseconds,
        profileDefinitionId: workerTypeId,
        profileResolutionSource: 'lastKnownGood',
        issueCode: issueCode,
        failureLayer: _profileProbeFailureLayer(issueCode),
      );
      return false;
    }
  }

  DiscoveredModelCatalog? _catalogForAssessment(
      LocalWorker worker, WorkerReadinessAssessment assessment) {
    final incoming = assessment.modelCatalog;
    final prior = worker.modelCatalog;
    final digest = assessment.profileDigest;
    final version = assessment.toolVersion;
    final invalidBinding =
        (digest != null && prior != null && prior.profileDigest != digest) ||
            (version != null &&
                prior != null &&
                prior.providerToolVersion != version) ||
            const {
              'tool_profile_unavailable',
              'profile_invalid',
              'unsupported_provider_tool_version',
              'engine_incompatible'
            }.contains(assessment.issueCode);
    if (incoming != null) {
      if ((digest != null && incoming.profileDigest != digest) ||
          (version != null && incoming.providerToolVersion != version)) {
        return null;
      }
      if (prior != null &&
          prior.catalogRevision == incoming.catalogRevision &&
          prior.stale == incoming.stale) {
        return prior;
      }
      return incoming;
    }
    return invalidBinding ? null : prior?.withStale(true);
  }

  Future<void> _checkAll({
    required LocalWorkerProbeMode mode,
    String? workerTypeId,
    bool includeDisabled = false,
  }) async {
    for (final worker in await registry.list()) {
      if ((workerTypeId != null && worker.workerTypeId != workerTypeId) ||
          worker.status == LocalWorkerStatus.removed) {
        continue;
      }
      if (!_isExternalWorker(worker) &&
          workerCatalogCoordinator != null &&
          _profileDefinitionFor(worker.workerTypeId) == null) {
        continue;
      }
      if (worker.activationState == LocalWorkerActivationState.disabled &&
          mode == LocalWorkerProbeMode.passive &&
          !includeDisabled) {
        continue;
      }
      _progress(worker.workerTypeId, mode, WorkerCheckPhase.profile);
      try {
        final checks = await _checkWorker(worker, mode);
        final updated = await registry.find(worker.id);
        final passed = mode == LocalWorkerProbeMode.live
            ? updated?.lastLiveTestPassed == true
            : updated?.readinessState == WorkerReadinessState.ready;
        _progress(
            worker.workerTypeId, mode, _checks[worker.workerTypeId]!.phase,
            outcome:
                passed ? WorkerCheckOutcome.passed : WorkerCheckOutcome.failed,
            issueCode: mode == LocalWorkerProbeMode.live
                ? updated?.lastLiveTestIssueCode
                : updated?.readinessIssueCode,
            checks: checks);
      } on Object {
        _progress(
            worker.workerTypeId, mode, _checks[worker.workerTypeId]!.phase,
            outcome: WorkerCheckOutcome.failed,
            issueCode: 'verification_save_failed');
        rethrow;
      }
    }
  }

  /// Runs one check and records the result. Returns the Engine's individual
  /// checks for progress reporting.
  Future<List<ProbeCheck>> _checkWorker(
      LocalWorker worker, LocalWorkerProbeMode mode) async {
    WorkerReadinessAssessment assessment;
    try {
      if (assessWorker != null) {
        _progress(worker.workerTypeId, mode, WorkerCheckPhase.probe);
      }
      assessment = _isExternalWorker(worker)
          ? await externalWorkerAssessor!(worker, mode)
          : assessWorker != null
              ? await assessWorker!(worker)
              : await _assess(worker, mode: mode);
    } on Object {
      assessment = const WorkerReadinessAssessment(
          WorkerReadinessState.testFailed,
          issueCode: 'provider_failure');
    }
    if (assessment.state == WorkerReadinessState.ready) {
      _progress(worker.workerTypeId, mode, WorkerCheckPhase.save);
    }
    final catalog = _catalogForAssessment(worker, assessment);
    final checkedAt = DateTime.now().toUtc().toIso8601String();
    if (mode == LocalWorkerProbeMode.passive) {
      final effectiveReady = assessment.state == WorkerReadinessState.ready ||
          (assessment.state == WorkerReadinessState.setupRequired &&
              worker.lastLiveTestPassed == true);
      await registry.update(
        worker.id,
        (current) => current.copyWith(
          status: current.activationState == LocalWorkerActivationState.disabled
              ? LocalWorkerStatus.disabled
              : effectiveReady
                  ? LocalWorkerStatus.ready
                  : LocalWorkerStatus.needsAttention,
          activationState: current.activationState,
          readinessState: assessment.state,
          lastPassiveProbeAt: checkedAt,
          readinessIssueCode: assessment.issueCode,
          clearReadinessIssueCode: assessment.issueCode == null,
          modelCatalog: catalog,
          clearModelCatalog: catalog == null,
          toolVersion: assessment.toolVersion,
          clearToolVersion: assessment.replaceToolVersion &&
              assessment.toolVersion == null &&
              catalog == null,
          toolName: assessment.toolName,
          clearToolName:
              assessment.replaceToolName && assessment.toolName == null,
          toolPath: assessment.toolPath,
          clearToolPath:
              assessment.replaceToolPath && assessment.toolPath == null,
        ),
      );
      return assessment.checks;
    }

    final passed = assessment.state == WorkerReadinessState.ready;
    final details = passed
        ? null
        : assessment.diagnosticDetails ?? _safeTestDetails(assessment);
    await registry.update(
      worker.id,
      (current) => current.copyWith(
        status: current.activationState == LocalWorkerActivationState.disabled
            ? LocalWorkerStatus.disabled
            : passed
                ? LocalWorkerStatus.ready
                : LocalWorkerStatus.needsAttention,
        activationState: current.activationState,
        lastLiveTestAt: checkedAt,
        lastLiveTestPassed: passed,
        lastLiveTestProfileDigest: assessment.profileDigest,
        lastLiveTestToolVersion: assessment.toolVersion,
        lastLiveTestIssueCode: assessment.issueCode,
        clearLastLiveTestIssueCode: assessment.issueCode == null,
        lastLiveTestDetails: details,
        clearLastLiveTestDetails: passed,
        modelCatalog: catalog,
        clearModelCatalog: catalog == null,
        toolVersion: assessment.toolVersion,
        clearToolVersion: assessment.replaceToolVersion &&
            assessment.toolVersion == null &&
            catalog == null,
        toolName: assessment.toolName,
        clearToolName:
            assessment.replaceToolName && assessment.toolName == null,
        toolPath: assessment.toolPath,
        clearToolPath:
            assessment.replaceToolPath && assessment.toolPath == null,
      ),
    );
    return assessment.checks;
  }

  String _safeTestDetails(WorkerReadinessAssessment assessment) {
    final issueCode = assessment.issueCode ?? 'execution_test_failed';
    final details = [
      'Tool Profile test failed ($issueCode).',
      assessment.diagnosticDetails ??
          'The package did not return safe diagnostic details.',
    ].join('\n');
    return details.length <= 1000 ? details : details.substring(0, 1000);
  }

  Future<WorkerReadinessAssessment> _assess(
    LocalWorker worker, {
    LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
  }) async {
    try {
      final profileDefinitionId = _profileDefinitionFor(worker.workerTypeId);
      if (profileDefinitionId == null || toolProfileReleaseStore == null) {
        return const WorkerReadinessAssessment(
          WorkerReadinessState.runtimeUnavailable,
          issueCode: 'tool_profile_unavailable',
        );
      }
      return await _assessToolProfileWorker(
        worker,
        profileDefinitionId: profileDefinitionId,
        mode: mode,
      );
    } on Object catch (error) {
      if (error is CliWorkerEngineProbeException) {
        return WorkerReadinessAssessment(
          error.issueCode == 'provider_authentication_required'
              ? WorkerReadinessState.signInRequired
              : error.issueCode == 'provider_tool_unavailable'
                  ? WorkerReadinessState.runtimeUnavailable
                  : WorkerReadinessState.testFailed,
          issueCode: error.issueCode,
          diagnosticDetails: error.safeMessage,
        );
      }
      final timeout = error is TimeoutException;
      return WorkerReadinessAssessment(
        WorkerReadinessState.runtimeUnavailable,
        issueCode: timeout ? 'probe_timeout' : 'provider_failure',
        diagnosticDetails: timeout
            ? 'The Tool Profile probe timed out.'
            : 'The Tool Profile could not complete its probe.',
      );
    }
  }

  String? _profileDefinitionFor(String workerTypeId) =>
      workerCatalogCoordinator?.profileDefinitionForWorker(workerTypeId);

  Future<WorkerReadinessAssessment> _assessToolProfileWorker(
    LocalWorker worker, {
    required String profileDefinitionId,
    required LocalWorkerProbeMode mode,
  }) async {
    final timer = Stopwatch()..start();
    final runId = 'profile-probe-${DateTime.now().microsecondsSinceEpoch}';
    final engine = cliWorkerEngineSupervisor;
    final store = toolProfileReleaseStore!;
    final stateDirectory = workerStateDirectory?.call(worker.id);
    if (engine == null || stateDirectory == null) {
      await _recordToolProfileDiagnostic(
        worker,
        runId: runId,
        mode: mode,
        durationMs: timer.elapsedMilliseconds,
        issueCode: 'cli_worker_engine_unavailable',
        failureLayer: 'engine',
        profileResolutionSource: 'unavailable',
      );
      return const WorkerReadinessAssessment(
        WorkerReadinessState.runtimeUnavailable,
        issueCode: 'cli_worker_engine_unavailable',
        diagnosticDetails: 'The generic CLI Worker Engine is unavailable.',
      );
    }
    late ToolProfileResolution<ToolProfileCandidate> resolution;
    try {
      resolution = await workerCatalogCoordinator!.resolveProfileForWorker(
        workerTypeId: worker.workerTypeId,
        engineVersion: cliWorkerEngineVersion,
        // Catalog refresh invokes readiness after downloading Profiles. Never
        // wait on that refresh from a readiness check: it may be waiting on us.
        synchronizeIfUnavailable: false,
      );
    } on Object catch (error) {
      final issueCode = error is FormatException
          ? 'profile_invalid'
          : 'tool_profile_unavailable';
      await _recordToolProfileDiagnostic(
        worker,
        runId: runId,
        mode: mode,
        durationMs: timer.elapsedMilliseconds,
        profileDefinitionId: profileDefinitionId,
        profileResolutionSource: 'unavailable',
        issueCode: issueCode,
        failureLayer: 'profile',
      );
      return WorkerReadinessAssessment(
        WorkerReadinessState.runtimeUnavailable,
        issueCode: issueCode,
        diagnosticDetails: 'The current Tool Profile could not be resolved.',
      );
    }
    final candidate = resolution.release;
    if (candidate != null && !candidate.isPublished) {
      _progress(worker.workerTypeId, mode, WorkerCheckPhase.probe);
      final probe = await engine.probe(
        candidate,
        profileFile: await store.executionProfileFile(candidate),
        stateDirectory: stateDirectory,
        mode: mode == LocalWorkerProbeMode.live
            ? WorkerProbeMode.live
            : WorkerProbeMode.passive,
        timeout: mode == LocalWorkerProbeMode.live
            ? const Duration(
                milliseconds: WorkerProtocolLimits.maxProbeTimeoutMs)
            : const Duration(seconds: 20),
      );
      await _recordToolProfileDiagnostic(worker,
          runId: runId,
          mode: mode,
          durationMs: timer.elapsedMilliseconds,
          profileDefinitionId: profileDefinitionId,
          profileReleaseVersion: candidate.releaseVersion,
          profileResolutionSource: 'draft',
          providerToolName: probe.providerToolName,
          providerToolVersion: probe.providerToolVersion,
          issueCode: probe.issueCode,
          failureLayer: probe.issueCode == null
              ? null
              : _profileProbeFailureLayer(probe.issueCode!));
      return WorkerReadinessAssessment(
        probe.ready
            ? profileProbeReadiness(worker, candidate, probe, mode)
            : probe.issueCode == 'provider_authentication_required'
                ? WorkerReadinessState.signInRequired
                : WorkerReadinessState.testFailed,
        issueCode: probe.issueCode,
        toolName: probe.providerToolName,
        modelCatalog: probe.modelCatalog,
        profileDigest: candidate.payloadDigest,
        toolVersion: probe.providerToolVersion,
        replaceToolName: true,
        replaceToolVersion: true,
        checks: probe.checks,
        diagnosticDetails:
            'Unsigned development Profile; local loopback execution only.',
      );
    }
    if (candidate is WorkerProfileSnapshotAdmission) {
      _progress(worker.workerTypeId, mode, WorkerCheckPhase.probe);
      final probe = await engine.probe(
        candidate,
        profileFile: await store.executionProfileFile(candidate),
        stateDirectory: stateDirectory,
        mode: mode == LocalWorkerProbeMode.live
            ? WorkerProbeMode.live
            : WorkerProbeMode.passive,
        timeout: mode == LocalWorkerProbeMode.live
            ? const Duration(
                milliseconds: WorkerProtocolLimits.maxProbeTimeoutMs)
            : const Duration(seconds: 20),
      );
      final actualVersion = probe.providerToolVersion;
      final issueCode = probe.issueCode;
      await _recordToolProfileDiagnostic(
        worker,
        runId: runId,
        mode: mode,
        durationMs: timer.elapsedMilliseconds,
        profileDefinitionId: profileDefinitionId,
        profileReleaseVersion: candidate.releaseVersion,
        profileResolutionSource: resolution.source.name,
        providerToolName: probe.providerToolName,
        providerToolVersion: actualVersion,
        issueCode: issueCode,
        failureLayer:
            issueCode == null ? null : _profileProbeFailureLayer(issueCode),
      );
      final failedCheck = probe.checks.cast<ProbeCheck?>().firstWhere(
            (check) => check?.status == ProbeCheckStatus.failed,
            orElse: () => null,
          );
      final diagnosticDetails = probe.diagnostics ?? failedCheck?.message;
      return WorkerReadinessAssessment(
        issueCode == null && probe.ready
            ? profileProbeReadiness(worker, candidate, probe, mode)
            : issueCode == 'provider_authentication_required'
                ? WorkerReadinessState.signInRequired
                : WorkerReadinessState.testFailed,
        issueCode: issueCode,
        diagnosticDetails: diagnosticDetails,
        toolName: probe.providerToolName,
        modelCatalog: probe.modelCatalog,
        profileDigest: candidate.payloadDigest,
        toolVersion: actualVersion,
        replaceToolName: true,
        replaceToolVersion: true,
        checks: probe.checks,
      );
    }
    if (candidate == null) {
      final activationIssue = workerCatalogCoordinator?.snapshot
          .profiles[worker.workerTypeId]?.details?['issueCode'] as String?;
      final issueCode = activationIssue ?? 'tool_profile_unavailable';
      await _recordToolProfileDiagnostic(
        worker,
        runId: runId,
        mode: mode,
        durationMs: timer.elapsedMilliseconds,
        profileDefinitionId: profileDefinitionId,
        profileResolutionSource: 'unavailable',
        issueCode: issueCode,
        failureLayer: _profileProbeFailureLayer(issueCode),
      );
      return WorkerReadinessAssessment(
        WorkerReadinessState.runtimeUnavailable,
        issueCode: issueCode,
        diagnosticDetails: activationIssue == null
            ? 'No current Worker Profile is available.'
            : 'Profile downloaded; activation probe failed ($issueCode).',
      );
    }
    await _recordToolProfileDiagnostic(
      worker,
      runId: runId,
      mode: mode,
      durationMs: timer.elapsedMilliseconds,
      profileDefinitionId: profileDefinitionId,
      profileReleaseVersion: candidate.revision,
      profileResolutionSource: resolution.source.name,
      issueCode: 'tool_profile_unavailable',
      failureLayer: 'profile',
      context: {'reason': 'unsupported_profile_candidate_type'},
    );
    return const WorkerReadinessAssessment(
      WorkerReadinessState.runtimeUnavailable,
      issueCode: 'tool_profile_unavailable',
      diagnosticDetails: 'The Workspace requires a V9 Worker Profile.',
    );
  }

  Future<void> _recordToolProfileDiagnostic(
    LocalWorker worker, {
    required String runId,
    required LocalWorkerProbeMode mode,
    required int durationMs,
    required String profileResolutionSource,
    String? profileDefinitionId,
    int? profileReleaseVersion,
    String? providerToolName,
    String? providerToolVersion,
    String? issueCode,
    String? failureLayer,
    Map<String, Object?> context = const {},
  }) async {
    final store = profileDiagnosticStoreForWorker?.call(worker.workerTypeId);
    if (store == null) return;
    await store.record(
      workerTypeId: worker.workerTypeId,
      workerVersion: cliWorkerEngineVersion,
      protocolStage: 'profile_probe',
      event: issueCode == null
          ? 'profile.probe.completed'
          : 'profile.probe.failed',
      workspaceVersion: syntilaWorkspaceAppVersion,
      engineVersion: cliWorkerEngineVersion,
      profileDefinitionId: profileDefinitionId,
      profileReleaseVersion: profileReleaseVersion,
      profileResolutionSource: profileResolutionSource,
      probeStage: mode.name,
      failureLayer: failureLayer,
      runId: runId,
      providerToolName: providerToolName,
      providerToolVersion: providerToolVersion,
      durationMs: durationMs,
      errorCode: issueCode,
      context: context,
    );
  }

  String _profileProbeFailureLayer(String issueCode, {Object? error}) {
    if (error is CliWorkerEngineProbeException ||
        error is TimeoutException ||
        error is FormatException ||
        error is ProcessException) {
      return 'engine';
    }
    return switch (issueCode) {
      'cli_worker_engine_unavailable' ||
      'engine_incompatible' ||
      'engine_version_mismatch' ||
      'profile_identity_mismatch' ||
      'malformed_frame' ||
      'worker_internal_failure' =>
        'engine',
      'unsupported_provider_tool_version' ||
      'tool_profile_unavailable' ||
      'profile_invalid' =>
        'profile',
      _ => 'provider_tool',
    };
  }

  @override
  Future<void> dispose() async {
    super.dispose();
    _disposed = true;
    _started = false;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    await _activeCheck;
    await Future.wait(_queuedChecks.values.toList());
  }
}

WorkerReadinessState profileProbeReadiness(
    LocalWorker worker,
    ToolProfileCandidate profile,
    ProbeResult probe,
    LocalWorkerProbeMode mode) {
  final rawProbe = profile.profile['probe'];
  final live = rawProbe is Map ? rawProbe['live'] : null;
  if (mode == LocalWorkerProbeMode.passive &&
      live is Map &&
      live['requiredForReadiness'] == true &&
      !(worker.lastLiveTestPassed == true &&
          worker.lastLiveTestProfileDigest == profile.payloadDigest &&
          worker.lastLiveTestToolVersion == probe.providerToolVersion)) {
    return WorkerReadinessState.notProbed;
  }
  return WorkerReadinessState.ready;
}
