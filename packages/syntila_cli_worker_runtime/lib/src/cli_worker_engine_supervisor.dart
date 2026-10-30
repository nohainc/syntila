import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

import 'platform_process_supervisor.dart';
import 'worker_process_cleanup.dart';

const cliWorkerEngineVersion = '1.3.1';

/// Runs one isolated generic Engine process for one passive or live probe,
/// or for normal / sandbox assignment execution.
final class CliWorkerEngineSupervisor {
  static const defaultQueueWaitTimeout = Duration(minutes: 2);

  CliWorkerEngineSupervisor({
    required this.engineExecutable,
    this.engineArgumentsPrefix = const [],
    this.environmentOverrides = const {},
    this.processRegistryDirectory,
    PlatformProcessSupervisor? platformRuntime,
    this.maxFrameBytes = WorkerProtocolLimits.maxFrameBytes,
    this.maxStderrBytes = 64 * 1024,
  }) : _platformRuntime = platformRuntime ?? const StandardProcessSupervisor();

  final String engineExecutable;
  final List<String> engineArgumentsPrefix;
  final Map<String, String> environmentOverrides;
  final Directory? processRegistryDirectory;
  final PlatformProcessSupervisor _platformRuntime;
  final int maxFrameBytes;
  final int maxStderrBytes;
  final Map<String, Process> _activeAssignments = {};
  final Map<String, String> _activeWorkerByAssignment = {};
  final Map<String, String> _reservedWorkerByAssignment = {};

  /// Slot admission is one Workspace-wide pool: every Worker draws from the
  /// same [_pool] entry, so the limit is total parallel executions regardless
  /// of which Worker runs them. Per-Worker views are derived for telemetry.
  static const _pool = 'workspace';
  final Map<String, int> _activeByWorker = {};
  final Map<String, List<_QueuedEngineAssignment>> _waitersByWorker = {};
  final Map<String, _QueuedEngineAssignment> _queuedAssignments = {};
  final Set<String> _reservedAssignmentIds = {};
  final Set<String> _cancelledAssignments = {};

  /// The Workspace-wide parallel slot limit most recently applied.
  /// Every admission restates it and every state change re-evaluates the
  /// queue against it, so lowering or raising a limit takes effect at once.
  final Map<String, int> _limitByWorker = {};

  /// Native-session gates: at most one reserved or running assignment may use
  /// a given durable provider session at a time. A gate is held from slot
  /// reservation to teardown and is part of queue admission, so an
  /// assignment waiting for a busy session never holds a Worker slot.
  final Set<String> _busySessionGates = {};
  final Map<String, String> _sessionGateByAssignment = {};

  /// Assignments the Supervisor started whose Engine process no longer exists.
  ///
  /// Reported to Cloud on every heartbeat so a crashed or killed Engine is
  /// noticed even when no terminal outcome could be recorded. Queued or
  /// reserved assignments have no process yet and are never listed. On
  /// Windows the process cannot be probed without a signal, so none is listed.
  Set<String> get deadAssignmentIds {
    if (Platform.isWindows) return const {};
    return {
      for (final entry in _activeAssignments.entries)
        if (!_processExists(entry.value.pid)) entry.key,
    };
  }

  /// `SIGCONT` to a running process is harmless; a missing process is false.
  static bool _processExists(int pid) {
    try {
      return Process.killPid(pid, ProcessSignal.sigcont);
    } on Object {
      return true;
    }
  }

  /// Assignments waiting for a local Worker slot. Telemetry only.
  int get queuedAssignmentCount => _queuedAssignments.length;

  /// Assignments of [workerId] waiting for a slot or session. Telemetry only.
  int queuedAssignmentCountFor(String workerId) => _queuedAssignments.values
      .where((queued) => queued.workerId == workerId)
      .length;

  /// Slots of [workerId] currently reserved or running. Telemetry only.
  int activeAssignmentCountFor(String workerId) => {
    for (final entry in _reservedWorkerByAssignment.entries)
      if (entry.value == workerId) entry.key,
    for (final entry in _activeWorkerByAssignment.entries)
      if (entry.value == workerId) entry.key,
  }.length;

  /// Slots of the shared pool currently reserved or running. Telemetry only.
  int get activeSlotCount => _activeByWorker[_pool] ?? 0;

  /// Reaps Engine processes left behind if the owning Workspace Service died.
  /// A PID is acted on only when its command line still identifies this exact
  /// bundled Engine and its private state directory.
  Future<int> recoverOrphanedProcesses() async {
    final directory = processRegistryDirectory;
    if (directory == null || !await directory.exists()) return 0;
    if (Platform.isWindows) return 0;
    try {
      final probe = await Process.run('ps', ['-p', '1', '-o', 'pid=']);
      if (probe.exitCode != 0) return 0;
    } on ProcessException {
      return 0;
    }
    var reaped = 0;
    for (final entity in await directory.list(followLinks: false).toList()) {
      if (entity is! File || !entity.path.endsWith('.worker-process.json')) {
        continue;
      }
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is! Map) throw const FormatException('invalid record');
        final record = Map<String, Object?>.from(decoded);
        final pid = record['enginePid'] ?? record['pid'];
        final executable = record['engineExecutable'] ?? record['executable'];
        final stateDirectory = record['stateDirectory'];
        if (pid is! int ||
            pid <= 1 ||
            executable != File(engineExecutable).absolute.path ||
            stateDirectory is! String) {
          throw const FormatException('invalid process identity');
        }
        final processInfo = await Process.run('ps', [
          '-p',
          '$pid',
          '-o',
          'command=',
        ]);
        final command = processInfo.exitCode == 0
            ? processInfo.stdout.toString().trimLeft()
            : '';
        final recordedStartIdentity = record['engineStartIdentity'];
        String? currentStartIdentity;
        if (recordedStartIdentity is String &&
            recordedStartIdentity.isNotEmpty) {
          final startInfo = await Process.run('ps', [
            '-p',
            '$pid',
            '-o',
            'lstart=',
          ]);
          currentStartIdentity = startInfo.exitCode == 0
              ? startInfo.stdout.toString().trim()
              : null;
        }
        if (command.isNotEmpty &&
            command.startsWith('$executable ') &&
            command.contains(stateDirectory) &&
            (recordedStartIdentity == null ||
                recordedStartIdentity == currentStartIdentity)) {
          await const WorkerProcessCleanup().terminateOrphanedPid(pid);
          reaped++;
        }
      } on Object {
        // Stale, malformed, or reused PIDs are discarded without signaling.
      }
      try {
        await entity.delete();
      } on FileSystemException {
        // A later startup will retry the bounded cleanup.
      }
    }
    return reaped;
  }

  Future<ProbeResult> probe(
    ToolProfileCandidate release, {
    required File profileFile,
    required Directory stateDirectory,
    required WorkerProbeMode mode,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final boundedTimeout =
        timeout >
            const Duration(milliseconds: WorkerProtocolLimits.maxProbeTimeoutMs)
        ? const Duration(milliseconds: WorkerProtocolLimits.maxProbeTimeoutMs)
        : timeout;
    if (boundedTimeout < const Duration(milliseconds: 100)) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'probe timeout is too short',
      );
    }
    await stateDirectory.create(recursive: true);
    final timer = Stopwatch()..start();
    Process? process;
    File? processRecord;
    CliEngineChannel? channel;
    var stopped = false;
    try {
      process = await _platformRuntime.startIsolatedProcess(
        engineExecutable,
        [
          ...engineArgumentsPrefix,
          '--profile',
          profileFile.path,
          '--engine-version',
          cliWorkerEngineVersion,
          '--state-directory',
          stateDirectory.path,
        ],
        workingDirectory: stateDirectory.path,
        environment: _engineEnvironment(),
        includeParentEnvironment: false,
      );
      processRecord = await _writeProcessRecord(
        process,
        assignmentId: 'probe-${DateTime.now().microsecondsSinceEpoch}',
        stateDirectory: stateDirectory,
      );
      channel = CliEngineChannel(
        process,
        maxFrameBytes: maxFrameBytes,
        maxStderrBytes: maxStderrBytes,
      );
      final initialized = await channel.exchange(
        InitializeRequest(
          requestId: 'engine-init-${DateTime.now().microsecondsSinceEpoch}',
          workerTypeId: release.logicalWorkerTypeId,
          expectedEngineVersion: cliWorkerEngineVersion,
          profileDefinitionId: release.profileDefinitionId,
          profileReleaseVersion: release.revision.toString(),
          profileDigest: release.payloadDigest,
        ),
        _remaining(boundedTimeout, timer),
      );
      if (initialized is! InitializeResult ||
          initialized.workerTypeId != release.logicalWorkerTypeId ||
          initialized.engineVersion != cliWorkerEngineVersion ||
          initialized.profileDefinitionId != release.profileDefinitionId ||
          initialized.profileReleaseVersion != release.revision.toString() ||
          initialized.profileSchemaVersion !=
              release.profile['schemaVersion']) {
        throw const FormatException('CLI Worker Engine initialize mismatch');
      }
      final result = await channel.exchange(
        ProbeRequest(
          requestId: 'engine-probe-${DateTime.now().microsecondsSinceEpoch}',
          mode: mode,
          timeoutMs: boundedTimeout.inMilliseconds,
        ),
        _remaining(boundedTimeout, timer),
      );
      if (result is! ProbeResult || result.mode != mode) {
        throw const FormatException(
          'CLI Worker Engine probe response mismatch',
        );
      }
      if (result.providerToolName != null &&
          result.providerToolName != release.providerToolName) {
        throw const FormatException(
          'CLI Worker Engine provider identity mismatch',
        );
      }
      await process.stdin.close();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 2),
      );
      if (exitCode != 0) {
        throw const FormatException('CLI Worker Engine exited unsuccessfully');
      }
      stopped = true;
      return result;
    } on TimeoutException {
      throw const CliWorkerEngineProbeException(
        WorkerIssueCode.deadlineExceeded,
        'Provider probe exceeded its deadline.',
      );
    } on ProcessException catch (error) {
      throw CliWorkerEngineProbeException(
        WorkerIssueCode.providerToolUnavailable,
        'CLI Worker Engine could not be started.',
        localDiagnostics: jsonEncode({
          'stage': 'engine_process_start',
          'errorCode': error.errorCode,
          'message': error.message,
        }),
      );
    } finally {
      if (process != null && !stopped) {
        await _platformRuntime.terminateProcessTree(process, force: true);
      }
      if (processRecord != null) {
        await _updateProcessRecord(
          processRecord,
          engineState: 'terminated',
          providerState: 'terminated',
        );
      }
      await _deleteProcessRecord(processRecord);
      await channel?.dispose();
    }
  }

  /// Runs the Profile-owned usage command in an isolated Engine process and
  /// returns the provider's report verbatim.
  Future<UsageResult> usage(
    ToolProfileCandidate release, {
    required File profileFile,
    required Directory stateDirectory,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final boundedTimeout =
        timeout >
            const Duration(milliseconds: WorkerProtocolLimits.maxUsageTimeoutMs)
        ? const Duration(milliseconds: WorkerProtocolLimits.maxUsageTimeoutMs)
        : timeout;
    if (boundedTimeout < const Duration(milliseconds: 100)) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'usage timeout is too short',
      );
    }
    await stateDirectory.create(recursive: true);
    final timer = Stopwatch()..start();
    Process? process;
    File? processRecord;
    CliEngineChannel? channel;
    var stopped = false;
    try {
      process = await _platformRuntime.startIsolatedProcess(
        engineExecutable,
        [
          ...engineArgumentsPrefix,
          '--profile',
          profileFile.path,
          '--engine-version',
          cliWorkerEngineVersion,
          '--state-directory',
          stateDirectory.path,
        ],
        workingDirectory: stateDirectory.path,
        environment: _engineEnvironment(),
        includeParentEnvironment: false,
      );
      processRecord = await _writeProcessRecord(
        process,
        assignmentId: 'usage-${DateTime.now().microsecondsSinceEpoch}',
        stateDirectory: stateDirectory,
      );
      channel = CliEngineChannel(
        process,
        maxFrameBytes: maxFrameBytes,
        maxStderrBytes: maxStderrBytes,
      );
      final initialized = await channel.exchange(
        InitializeRequest(
          requestId: 'engine-init-${DateTime.now().microsecondsSinceEpoch}',
          workerTypeId: release.logicalWorkerTypeId,
          expectedEngineVersion: cliWorkerEngineVersion,
          profileDefinitionId: release.profileDefinitionId,
          profileReleaseVersion: release.revision.toString(),
          profileDigest: release.payloadDigest,
        ),
        _remaining(boundedTimeout, timer),
      );
      if (initialized is! InitializeResult ||
          initialized.workerTypeId != release.logicalWorkerTypeId ||
          initialized.engineVersion != cliWorkerEngineVersion ||
          initialized.profileDefinitionId != release.profileDefinitionId ||
          initialized.profileReleaseVersion != release.revision.toString() ||
          initialized.profileSchemaVersion !=
              release.profile['schemaVersion']) {
        throw const FormatException('CLI Worker Engine initialize mismatch');
      }
      final result = await channel.exchange(
        UsageRequest(
          requestId: 'engine-usage-${DateTime.now().microsecondsSinceEpoch}',
          timeoutMs: boundedTimeout.inMilliseconds,
        ),
        _remaining(boundedTimeout, timer),
      );
      if (result is WorkerErrorFrame) {
        throw CliWorkerEngineProbeException(result.code, result.message);
      }
      if (result is! UsageResult) {
        throw const FormatException(
          'CLI Worker Engine usage response mismatch',
        );
      }
      await process.stdin.close();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 2),
      );
      if (exitCode != 0) {
        throw const FormatException('CLI Worker Engine exited unsuccessfully');
      }
      stopped = true;
      return result;
    } on TimeoutException {
      throw const CliWorkerEngineProbeException(
        WorkerIssueCode.deadlineExceeded,
        'Provider probe exceeded its deadline.',
      );
    } on ProcessException catch (error) {
      throw CliWorkerEngineProbeException(
        WorkerIssueCode.providerToolUnavailable,
        'CLI Worker Engine could not be started.',
        localDiagnostics: jsonEncode({
          'stage': 'engine_process_start',
          'errorCode': error.errorCode,
          'message': error.message,
        }),
      );
    } finally {
      if (process != null && !stopped) {
        await _platformRuntime.terminateProcessTree(process, force: true);
      }
      if (processRecord != null) {
        await _updateProcessRecord(
          processRecord,
          engineState: 'terminated',
          providerState: 'terminated',
        );
      }
      await _deleteProcessRecord(processRecord);
      await channel?.dispose();
    }
  }

  /// Executes one assignment through a Tool Profile candidate.
  Future<WorkerResult> execute(
    ToolProfileCandidate release, {
    required File profileFile,
    required Directory stateDirectory,
    required Directory workingDirectory,
    required String workerId,
    required int maxConcurrentAssignments,
    required String assignmentId,
    required String prompt,
    required Duration timeout,
    Duration? queueWaitTimeout,
    WorkerSessionPolicy sessionPolicy = WorkerSessionPolicy.stateless,
    String? sessionKey,
    WorkerSessionContext? workerSession,
    ConversationBootstrap? statelessContext,
    String? model,
    String? reasoningEffort,
    String? catalogRevision,
    WorkerExecutionPolicy executionPolicy = WorkerExecutionPolicy.restricted,
    List<String> additionalDirectories = const [],
    bool compactContext = false,
    Duration? engineExecutionTimeout,
    String? attemptId,
    String? executionId,
    FutureOr<void> Function()? onSlotReserved,

    /// Start fence. Called after the slot is reserved and immediately before
    /// the Engine process is created. Returning false means Cloud did not
    /// authorize this launch (the assignment was revoked or timed out), and
    /// no process is started.
    FutureOr<bool> Function()? authorizeStart,
    void Function()? onExecutionStarted,

    /// Called synchronously once the Engine OS process exists, before the
    /// initialize handshake. Observation only; it is never awaited.
    void Function()? onProcessStarted,

    /// Called synchronously when the assignment must wait for a Worker slot
    /// or a busy provider session, with its queue position. Observation only.
    void Function(WorkerQueueSnapshot queue)? onQueued,

    /// Called once the Engine answered the initialize handshake with a
    /// matching identity. Observation only; it is never awaited.
    void Function()? onInitialized,
    void Function(WorkerProgress progress)? onProgress,
    FutureOr<void> Function(WorkerActivity activity)? onActivity,
  }) async {
    if (workerSession != null && workerSession.workerId != workerId) {
      throw const FormatException(
        'Worker Session does not belong to this Worker',
      );
    }
    final boundedTimeout =
        timeout >
            const Duration(milliseconds: WorkerProtocolLimits.maxTimeoutMs)
        ? const Duration(milliseconds: WorkerProtocolLimits.maxTimeoutMs)
        : timeout;
    final requestedQueueWaitTimeout =
        queueWaitTimeout ?? defaultQueueWaitTimeout;
    final boundedQueueWaitTimeout =
        requestedQueueWaitTimeout >
            const Duration(milliseconds: WorkerProtocolLimits.maxTimeoutMs)
        ? const Duration(milliseconds: WorkerProtocolLimits.maxTimeoutMs)
        : requestedQueueWaitTimeout;
    final requestedEngineTimeout = engineExecutionTimeout ?? boundedTimeout;
    final boundedEngineTimeout =
        requestedEngineTimeout >
            const Duration(milliseconds: WorkerProtocolLimits.maxTimeoutMs)
        ? const Duration(milliseconds: WorkerProtocolLimits.maxTimeoutMs)
        : requestedEngineTimeout;

    if (boundedTimeout < const Duration(milliseconds: 100) ||
        boundedQueueWaitTimeout < const Duration(milliseconds: 100) ||
        boundedEngineTimeout < const Duration(milliseconds: 100)) {
      throw ArgumentError.value(
        engineExecutionTimeout ?? timeout,
        'timeout',
        'assignment timeout is too short',
      );
    }
    if (maxConcurrentAssignments < 1) {
      throw ArgumentError.value(
        maxConcurrentAssignments,
        'maxConcurrentAssignments',
        'effective Worker concurrency limit must be positive',
      );
    }
    if (_activeAssignments.containsKey(assignmentId) ||
        _reservedAssignmentIds.contains(assignmentId) ||
        _queuedAssignments.containsKey(assignmentId)) {
      throw const FormatException(
        'Assignment already has an active or queued Engine execution',
      );
    }

    // Queue insertion is synchronous: nothing above awaits and _acquireSlot
    // registers the assignment before it first yields. A cancellation issued
    // at any point after this call finds the assignment and prevents process
    // creation.
    //
    // Queueing is admission time, not provider execution time. A request
    // must not lose its provider deadline while waiting for another
    // assignment to release a Worker slot.
    await _acquireSlot(
      workerId,
      assignmentId,
      maxConcurrentAssignments,
      sessionGate:
          sessionPolicy == WorkerSessionPolicy.durableSession &&
              sessionKey != null
          ? '$workerId|$sessionKey'
          : null,
      timeout: boundedQueueWaitTimeout,
      onQueued: onQueued,
    );
    final timer = Stopwatch()..start();
    Process? process;
    File? processRecord;
    CliEngineChannel? channel;
    var stopped = false;
    // Where launch currently is, for precise failure classification:
    // slot_reserved → engine_spawn → engine_initialize → provider_execution.
    var launchStage = 'slot_reserved';
    var providerStarted = false;
    var processObservation = Future<void>.value();
    Future<File?>? pendingProcessRecord;
    try {
      // The slot is held from here, so every failure below releases it.
      await stateDirectory.create(recursive: true);
      await workingDirectory.create(recursive: true);
      final existingRecord = _processRecordFile(assignmentId);
      if (existingRecord != null && await existingRecord.exists()) {
        throw const FormatException(
          'Assignment already has a durable Engine ownership record',
        );
      }
      // Slot reservation is observation: a failing or slow callback must
      // neither leak the slot nor delay the launch.
      _observe(onSlotReserved);
      if (_cancelledAssignments.remove(assignmentId)) {
        throw const WorkerAssignmentCancelledException();
      }
      if (authorizeStart != null && !await authorizeStart()) {
        throw const WorkerAssignmentCancelledException();
      }
      if (_cancelledAssignments.remove(assignmentId)) {
        throw const WorkerAssignmentCancelledException();
      }
      launchStage = 'engine_spawn';
      process = await _platformRuntime.startIsolatedProcess(
        engineExecutable,
        [
          ...engineArgumentsPrefix,
          '--profile',
          profileFile.path,
          '--engine-version',
          cliWorkerEngineVersion,
          '--state-directory',
          stateDirectory.path,
        ],
        workingDirectory: workingDirectory.path,
        environment: _engineEnvironment(),
        includeParentEnvironment: false,
      );
      launchStage = 'engine_initialize';
      try {
        onProcessStarted?.call();
      } on Object {
        // Observation must never affect Engine launch.
      }
      // Own the process immediately so cancel() can stop it while the
      // ownership record is still being written.
      _activeAssignments[assignmentId] = process;
      _activeWorkerByAssignment[assignmentId] = workerId;
      _reservedAssignmentIds.remove(assignmentId);
      _reservedWorkerByAssignment.remove(assignmentId);
      // The durable ownership record (which identifies the process with a
      // `ps` call) is written concurrently with the initialize handshake and
      // awaited before the provider can be asked to start.
      final recordWrite = pendingProcessRecord = _writeProcessRecord(
        process,
        assignmentId: assignmentId,
        stateDirectory: stateDirectory,
        workingDirectory: workingDirectory,
        workerId: workerId,
        attemptId: attemptId,
        executionId: executionId,
        deadlineAt: DateTime.now()
            .toUtc()
            .add(_remaining(boundedTimeout, timer))
            .toIso8601String(),
      );
      // Errors surface when the record is awaited (before the provider
      // starts, or in teardown); until then they are not "unhandled".
      recordWrite.ignore();
      if (_cancelledAssignments.remove(assignmentId)) {
        await _platformRuntime.terminateProcessTree(process, force: true);
        throw const WorkerAssignmentCancelledException();
      }
      channel = CliEngineChannel(
        process,
        maxFrameBytes: maxFrameBytes,
        maxStderrBytes: maxStderrBytes,
      );
      final initialized = await channel.exchange(
        InitializeRequest(
          requestId: 'engine-init-${DateTime.now().microsecondsSinceEpoch}',
          workerTypeId: release.logicalWorkerTypeId,
          expectedEngineVersion: cliWorkerEngineVersion,
          profileDefinitionId: release.profileDefinitionId,
          profileReleaseVersion: release.revision.toString(),
          profileDigest: release.payloadDigest,
        ),
        _remaining(boundedTimeout, timer),
      );
      if (initialized is! InitializeResult ||
          initialized.workerTypeId != release.logicalWorkerTypeId ||
          initialized.engineVersion != cliWorkerEngineVersion ||
          initialized.profileDefinitionId != release.profileDefinitionId ||
          initialized.profileReleaseVersion != release.revision.toString() ||
          initialized.profileSchemaVersion !=
              release.profile['schemaVersion']) {
        throw const FormatException('CLI Worker Engine initialize mismatch');
      }
      _observe(onInitialized);
      launchStage = 'provider_execution';
      processRecord = await pendingProcessRecord;
      pendingProcessRecord = null;
      final result = await channel.exchangeUntilTerminal(
        ExecuteRequest(
          requestId: 'engine-exec-${DateTime.now().microsecondsSinceEpoch}',
          assignmentId: assignmentId,
          prompt: prompt,
          timeoutMs: boundedEngineTimeout.inMilliseconds,
          sessionPolicy: sessionPolicy,
          sessionKey: sessionKey,
          workerSession: workerSession,
          statelessContext: statelessContext,
          model: model,
          reasoningEffort: reasoningEffort,
          catalogRevision: catalogRevision,
          executionPolicy: executionPolicy,
          additionalDirectories: additionalDirectories,
          compactContext: compactContext,
        ),

        _remaining(boundedTimeout, timer),
        onProgress: (progress) {
          if (progress.message == workerProviderExecutionStartedMessage) {
            providerStarted = true;
            onExecutionStarted?.call();
            final record = processRecord;
            if (record != null) {
              processObservation = processObservation.then(
                (_) => _updateProcessRecord(
                  record,
                  engineState: 'running',
                  providerState: 'running',
                ),
              );
            }
            // The Workspace handler consumes this internal marker to persist
            // and relay the explicit startup acknowledgement. It is never
            // forwarded as user-facing progress.
            onProgress?.call(progress);
          } else {
            onProgress?.call(progress);
          }
        },
        onActivity: onActivity,
      );
      await processObservation;
      if (result is WorkerErrorFrame) {
        throw CliWorkerEngineProbeException(
          result.code,
          result.message,
          localDiagnostics: result.diagnostics,
        );
      }
      if (result is! WorkerResult || result.assignmentId != assignmentId) {
        throw const FormatException(
          'CLI Worker Engine execution response mismatch',
        );
      }
      await process.stdin.close();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 2),
      );
      if (exitCode != 0) {
        throw CliWorkerEngineProbeException(
          WorkerIssueCode.providerFailure,
          'CLI Worker Engine exited unsuccessfully.',
          localDiagnostics: jsonEncode({
            'stage': 'engine_process_exit',
            'processExitCode': exitCode,
          }),
        );
      }
      stopped = true;
      return result;
    } on TimeoutException {
      if (_cancelledAssignments.remove(assignmentId)) {
        throw const WorkerAssignmentCancelledException();
      }
      // A deadline that elapses before the provider began executing is a
      // local startup timeout, not a provider execution timeout. Neither is a
      // Cloud command-delivery timeout, which ends at acknowledgement.
      throw CliWorkerEngineProbeException(
        WorkerIssueCode.deadlineExceeded,
        'Assignment execution exceeded its deadline.',
        localDiagnostics: jsonEncode({
          'stage': launchStage,
          'failureLayer': providerStarted
              ? 'provider_execution'
              : 'local_startup',
          if (!providerStarted) 'reason': 'startup_timeout',
          'providerStarted': providerStarted,
        }),
      );
    } on ProcessException catch (error) {
      if (_cancelledAssignments.remove(assignmentId)) {
        throw const WorkerAssignmentCancelledException();
      }
      throw CliWorkerEngineProbeException(
        WorkerIssueCode.providerToolUnavailable,
        'CLI Worker Engine could not be started.',
        localDiagnostics: jsonEncode({
          'stage': 'engine_process_start',
          'failureLayer': 'local_startup',
          'providerStarted': false,
          'errorCode': error.errorCode,
          'message': error.message,
        }),
      );
    } on Object {
      if (_cancelledAssignments.remove(assignmentId)) {
        throw const WorkerAssignmentCancelledException();
      }
      rethrow;
    } finally {
      _activeAssignments.remove(assignmentId);
      _activeWorkerByAssignment.remove(assignmentId);
      _reservedAssignmentIds.remove(assignmentId);
      _reservedWorkerByAssignment.remove(assignmentId);
      try {
        // Tear the process down before the slot is handed to the next
        // assignment of this Worker: both would otherwise share one state
        // directory. Bounded so a stuck teardown cannot hold the slot.
        if (process != null && !stopped) {
          await _platformRuntime
              .terminateProcessTree(process, force: true)
              .timeout(const Duration(seconds: 10), onTimeout: () {});
        }
        final pending = pendingProcessRecord;
        if (pending != null) {
          try {
            processRecord = await pending;
          } on Object {
            // A record that could not be written has nothing to delete.
          }
        }
        if (processRecord != null) {
          await _updateProcessRecord(
            processRecord,
            engineState: 'terminated',
            providerState: 'terminated',
          );
        }
        await _deleteProcessRecord(processRecord);
        await channel?.dispose();
      } finally {
        _releaseSlot(assignmentId);
      }
    }
  }

  Future<bool> cancel(String assignmentId) async {
    final queued = _queuedAssignments.remove(assignmentId);
    if (queued != null) {
      _removeWaiter(queued);
      // A cancelled waiter never received a slot, so it must not release one.
      if (!queued.permit.isCompleted) {
        queued.permit.completeError(const WorkerAssignmentCancelledException());
      }
      return true;
    }
    final process = _activeAssignments[assignmentId];
    if (process == null) {
      if (_reservedAssignmentIds.contains(assignmentId)) {
        _cancelledAssignments.add(assignmentId);
        return true;
      }
      return false;
    }
    _cancelledAssignments.add(assignmentId);
    await _platformRuntime.terminateProcessTree(process, force: true);
    return true;
  }

  Future<void> cancelWorker(String workerId) async {
    final assignmentIds = <String>{
      for (final entry in _queuedAssignments.entries)
        if (entry.value.workerId == workerId) entry.key,
      for (final entry in _activeWorkerByAssignment.entries)
        if (entry.value == workerId) entry.key,
      for (final entry in _reservedWorkerByAssignment.entries)
        if (entry.value == workerId) entry.key,
    };
    for (final assignmentId in assignmentIds) {
      await cancel(assignmentId);
    }
  }

  /// Point-in-time view of the shared slot pool for the Workspace UI, with a
  /// per-Worker breakdown of who holds the slots. Telemetry only.
  Map<String, Object?> slotSnapshot() {
    final workerIds = <String>{
      ..._queuedAssignments.values.map((queued) => queued.workerId),
      ..._reservedWorkerByAssignment.values,
      ..._activeWorkerByAssignment.values,
    }.toList()..sort();
    return {
      'active': _activeByWorker[_pool] ?? 0,
      'queued': _waitersByWorker[_pool]?.length ?? 0,
      if (_limitByWorker[_pool] != null) 'limit': _limitByWorker[_pool],
      'workers': [
        for (final workerId in workerIds)
          {
            'workerId': workerId,
            'active': activeAssignmentCountFor(workerId),
            'queued': queuedAssignmentCountFor(workerId),
            'assignmentIds': ({
              for (final entry in _reservedWorkerByAssignment.entries)
                if (entry.value == workerId) entry.key,
              for (final entry in _activeWorkerByAssignment.entries)
                if (entry.value == workerId) entry.key,
            }.toList()..sort()),
          },
      ],
      'busySessions': _busySessionGates.length,
    };
  }

  /// Stops every running and waiting assignment, then discards slot
  /// bookkeeping that did not release itself (for example after an assignment
  /// was abandoned during a disconnect). Returns how many assignments were
  /// stopped or discarded. Provider session data on disk is untouched.
  Future<int> resetSlots() async {
    final assignmentIds = <String>{
      ..._queuedAssignments.keys,
      ..._activeAssignments.keys,
      ..._reservedAssignmentIds,
    };
    for (final assignmentId in assignmentIds) {
      try {
        await cancel(assignmentId);
      } on Object {
        // Resetting must continue; the bookkeeping below is cleared anyway.
      }
    }
    for (final waiters in _waitersByWorker.values.toList()) {
      for (final queued in waiters.toList()) {
        if (!queued.permit.isCompleted) {
          queued.permit.completeError(
            const WorkerAssignmentCancelledException(),
          );
        }
      }
    }
    _waitersByWorker.clear();
    _queuedAssignments.clear();
    _activeByWorker.clear();
    _reservedAssignmentIds.clear();
    _reservedWorkerByAssignment.clear();
    _busySessionGates.clear();
    _sessionGateByAssignment.clear();
    _limitByWorker.clear();
    return assignmentIds.length;
  }

  Future<void> shutdown() async {
    for (final assignmentId in _queuedAssignments.keys.toList()) {
      await cancel(assignmentId);
    }
    final processes = _activeAssignments.values.toList();
    for (final process in processes) {
      await _platformRuntime.terminateProcessTree(process, force: true);
    }
  }

  /// Updates shared admission capacity without cancelling running assignments.
  void setParallelSlots(int slots) {
    if (slots < 1)
      throw ArgumentError.value(slots, 'slots', 'must be positive');
    _limitByWorker[_pool] = slots;
    _promoteWaiters();
  }

  Future<void> _acquireSlot(
    String workerId,
    String assignmentId,
    int parallelSlots, {
    String? sessionGate,
    required Duration timeout,
    void Function(WorkerQueueSnapshot queue)? onQueued,
  }) async {
    // Everything up to the first `await` below is synchronous and atomic:
    // the check, the reservation or the queue insertion cannot interleave
    // with another assignment's admission, release or cancellation.
    _limitByWorker[_pool] = parallelSlots;
    // A raised limit admits earlier waiters before a new arrival, so a later
    // request can never overtake the queue.
    _promoteWaiters();
    final sessionFree =
        sessionGate == null || !_busySessionGates.contains(sessionGate);
    if ((_activeByWorker[_pool] ?? 0) < parallelSlots && sessionFree) {
      _reserve(workerId, assignmentId, sessionGate);
      return;
    }
    final queued = _QueuedEngineAssignment(workerId, assignmentId, sessionGate);
    _queuedAssignments[assignmentId] = queued;
    _waitersByWorker.putIfAbsent(_pool, () => []).add(queued);
    // A raised limit may already admit earlier waiters (and this one).
    _promoteWaiters();
    if (!queued.permit.isCompleted) {
      final waiters = _waitersByWorker[_pool] ?? const [];
      _observe(
        () => onQueued?.call(
          WorkerQueueSnapshot(
            workerId: workerId,
            assignmentId: assignmentId,
            position: waiters.indexOf(queued) + 1,
            active: _activeByWorker[_pool] ?? 0,
            limit: parallelSlots,
            waitingForSession:
                sessionGate != null && _busySessionGates.contains(sessionGate),
            queueWaitTimeout: timeout,
          ),
        ),
      );
    }
    try {
      await queued.permit.future.timeout(timeout);
    } on TimeoutException {
      // The reservation may have been transferred in the same turn the timer
      // fired; if so the assignment owns a slot and must proceed to use and
      // release it.
      if (queued.permit.isCompleted &&
          _reservedAssignmentIds.contains(assignmentId)) {
        return;
      }
      _removeWaiter(queued);
      throw CliWorkerEngineProbeException(
        WorkerIssueCode.deadlineExceeded,
        'Assignment execution exceeded its deadline while waiting for a Worker slot.',
        localDiagnostics: jsonEncode({
          'stage': 'queue_wait',
          'failureLayer': 'local_startup',
          'reason': 'queue_allowance_exhausted',
          'providerStarted': false,
          'queueWaitTimeoutMs': timeout.inMilliseconds,
        }),
      );
    }
  }

  /// Takes one pool slot for [assignmentId] (run by [workerId]) and its
  /// session gate.
  void _reserve(String workerId, String assignmentId, String? sessionGate) {
    _activeByWorker[_pool] = (_activeByWorker[_pool] ?? 0) + 1;
    _reservedAssignmentIds.add(assignmentId);
    _reservedWorkerByAssignment[assignmentId] = workerId;
    if (sessionGate != null) {
      _busySessionGates.add(sessionGate);
      _sessionGateByAssignment[assignmentId] = sessionGate;
    }
  }

  void _removeWaiter(_QueuedEngineAssignment queued) {
    _queuedAssignments.remove(queued.assignmentId);
    final waiters = _waitersByWorker[_pool];
    if (waiters == null) return;
    waiters.remove(queued);
    if (waiters.isEmpty) _waitersByWorker.remove(_pool);
  }

  /// Hands free capacity to waiting assignments, oldest first. A waiter whose
  /// provider session is busy is skipped rather than blocking the ones behind
  /// it, so one busy session never stalls unrelated work.
  /// The reservation is transferred before the waiter's future completes, so
  /// a cancellation that races the wake-up still finds a reservation to
  /// cancel and stops before a process is created.
  void _promoteWaiters() {
    final waiters = _waitersByWorker[_pool];
    if (waiters == null) return;
    final limit = _limitByWorker[_pool] ?? 1;
    var index = 0;
    while (index < waiters.length && (_activeByWorker[_pool] ?? 0) < limit) {
      final next = waiters[index];
      final gate = next.sessionGate;
      if (gate != null && _busySessionGates.contains(gate)) {
        index += 1;
        continue;
      }
      waiters.removeAt(index);
      _queuedAssignments.remove(next.assignmentId);
      _reserve(next.workerId, next.assignmentId, gate);
      if (!next.permit.isCompleted) {
        next.permit.complete();
      }
    }
    if (waiters.isEmpty) _waitersByWorker.remove(_pool);
  }

  void _releaseSlot(String assignmentId) {
    final active = _activeByWorker[_pool] ?? 0;
    if (active <= 1) {
      _activeByWorker.remove(_pool);
    } else {
      _activeByWorker[_pool] = active - 1;
    }
    final gate = _sessionGateByAssignment.remove(assignmentId);
    if (gate != null) _busySessionGates.remove(gate);
    _promoteWaiters();
    if ((_activeByWorker[_pool] ?? 0) == 0 &&
        !_waitersByWorker.containsKey(_pool)) {
      _limitByWorker.remove(_pool);
    }
  }

  /// Runs an observation callback without awaiting it and without letting it
  /// throw into (or delay) the launch path.
  void _observe(FutureOr<void> Function()? callback) {
    if (callback == null) return;
    try {
      final result = callback();
      if (result is Future<void>) result.ignore();
    } on Object {
      // Observation must never affect Engine launch or slot accounting.
    }
  }

  Duration _remaining(Duration timeout, Stopwatch timer) {
    final value = timeout - timer.elapsed;
    if (value <= Duration.zero) {
      throw TimeoutException('probe deadline elapsed');
    }
    return value;
  }

  Future<File?> _writeProcessRecord(
    Process process, {
    required String assignmentId,
    required Directory stateDirectory,
    Directory? workingDirectory,
    String? workerId,
    String? attemptId,
    String? executionId,
    String? deadlineAt,
  }) async {
    final directory = processRegistryDirectory;
    if (directory == null) return null;
    await directory.create(recursive: true);
    final file = _processRecordFile(assignmentId)!;
    final startedAt = DateTime.now().toUtc();
    final startIdentity = await _processStartIdentity(process.pid);
    final localExecutionId = _localExecutionIdentity();
    await file.writeAsString(
      jsonEncode({
        'schemaVersion': 2,
        'recordId': localExecutionId,
        'localExecutionId': localExecutionId,
        'assignmentId': assignmentId,
        if (attemptId != null) 'attemptId': attemptId,
        if (executionId != null) 'executionId': executionId,
        if (workerId != null) 'workerId': workerId,
        'pid': process.pid,
        'enginePid': process.pid,
        'executable': File(engineExecutable).absolute.path,
        'engineExecutable': File(engineExecutable).absolute.path,
        'stateDirectory': stateDirectory.absolute.path,
        if (workingDirectory != null)
          'workingDirectory': workingDirectory.absolute.path,
        'engineStartedAt': startedAt.toIso8601String(),
        if (startIdentity != null) 'engineStartIdentity': startIdentity,
        if (deadlineAt != null) 'deadlineAt': deadlineAt,
        'engineState': 'running',
        'providerState': 'not_started',
      }),
      flush: true,
    );
    return file;
  }

  Future<void> _updateProcessRecord(
    File file, {
    required String engineState,
    required String providerState,
  }) async {
    try {
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final record = Map<String, Object?>.from(decoded)
        ..['engineState'] = engineState
        ..['providerState'] = providerState
        ..['updatedAt'] = DateTime.now().toUtc().toIso8601String();
      await file.writeAsString(jsonEncode(record), flush: true);
    } on Object {
      // The journal and terminal delivery remain authoritative if diagnostics
      // cannot update during shutdown.
    }
  }

  File? _processRecordFile(String assignmentId) {
    final directory = processRegistryDirectory;
    if (directory == null) return null;
    final safeId = base64Url
        .encode(utf8.encode(assignmentId))
        .replaceAll('=', '');
    return File('${directory.path}/$safeId.worker-process.json');
  }

  Future<String?> _processStartIdentity(int pid) async {
    if (Platform.isWindows) return null;
    try {
      final result = await Process.run('ps', ['-p', '$pid', '-o', 'lstart=']);
      if (result.exitCode != 0) return null;
      final value = result.stdout.toString().trim();
      return value.isEmpty ? null : value;
    } on Object {
      return null;
    }
  }

  String _localExecutionIdentity() {
    final suffix = Random.secure().nextInt(0xFFFFFF).toRadixString(16);
    return 'exec-${DateTime.now().toUtc().microsecondsSinceEpoch}-$suffix';
  }

  Future<void> _deleteProcessRecord(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Leave stale records for safe startup validation and cleanup.
    }
  }

  Map<String, String> _engineEnvironment() {
    const inheritedKeys = {
      'HOME',
      'USER',
      'LOGNAME',
      'SHELL',
      '__CF_USER_TEXT_ENCODING',
      'PATH',
      'TMPDIR',
      'TMP',
      'TEMP',
      'LANG',
      'LC_ALL',
      'LC_CTYPE',
      'XDG_CONFIG_HOME',
      'USERPROFILE',
      'APPDATA',
      'LOCALAPPDATA',
      'PATHEXT',
      'ComSpec',
      'SystemDrive',
      'SystemRoot',
      'HTTP_PROXY',
      'HTTPS_PROXY',
      'ALL_PROXY',
      'NO_PROXY',
      'SSH_AUTH_SOCK',
      'SSH_AGENT_PID',
      'GIT_CONFIG_GLOBAL',
      'GIT_CONFIG_SYSTEM',
      'GIT_SSH_COMMAND',
      'GIT_ASKPASS',
      'GIT_TERMINAL_PROMPT',
      'SSH_ASKPASS',
      'XDG_DATA_HOME',
      'XDG_CACHE_HOME',
    };
    return {
      for (final key in inheritedKeys)
        if (Platform.environment[key] case final value?) key: value,
      ...environmentOverrides,
    };
  }
}

final class _QueuedEngineAssignment {
  _QueuedEngineAssignment(this.workerId, this.assignmentId, this.sessionGate);

  final String workerId;
  final String assignmentId;
  final String? sessionGate;
  final Completer<void> permit = Completer<void>();
}

/// Where an assignment stands when it has to wait before launch.
final class WorkerQueueSnapshot {
  const WorkerQueueSnapshot({
    required this.workerId,
    required this.assignmentId,
    required this.position,
    required this.active,
    required this.limit,
    required this.waitingForSession,
    required this.queueWaitTimeout,
  });

  final String workerId;
  final String assignmentId;

  /// One-based position in the shared queue.
  final int position;

  /// Pool slots in use when the assignment queued.
  final int active;

  /// The Workspace-wide parallel slot limit.
  final int limit;

  /// Whether the assignment is also blocked by a busy provider session.
  final bool waitingForSession;
  final Duration queueWaitTimeout;
}

final class CliWorkerEngineProbeException implements Exception {
  const CliWorkerEngineProbeException(
    this.issueCode,
    this.safeMessage, {
    this.localDiagnostics,
  });

  final String issueCode;
  final String safeMessage;

  /// Bounded protocol diagnostics for local operator investigation.
  /// Never send this field to Cloud or include it in acceptance evidence.
  final String? localDiagnostics;

  @override
  String toString() =>
      'CliWorkerEngineProbeException($issueCode): $safeMessage';
}

final class WorkerAssignmentCancelledException implements Exception {
  const WorkerAssignmentCancelledException();
}

final class CliEngineChannel {
  CliEngineChannel(
    this.process, {
    required this.maxFrameBytes,
    required this.maxStderrBytes,
  }) : _lines = StreamIterator<String>(
         process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
       ) {
    _stderrTask = _drainStderr();
  }

  final Process process;
  final int maxFrameBytes;
  final int maxStderrBytes;
  final StreamIterator<String> _lines;
  late final Future<void> _stderrTask;
  int _stderrBytes = 0;

  Future<WorkerFrame> exchange(WorkerFrame request, Duration timeout) async {
    process.stdin.writeln(request.encode());
    await process.stdin.flush();
    final line = await _nextProtocolLine(timeout, 'engine_initialize');
    if (utf8.encode(line).length > maxFrameBytes) {
      throw const FormatException('CLI Worker Engine frame exceeds the limit');
    }
    final frame = decodeWorkerFrame(line);
    if (frame.requestId != request.requestId) {
      throw const FormatException('CLI Worker Engine request ID mismatch');
    }
    return frame;
  }

  Future<WorkerFrame> exchangeUntilTerminal(
    ExecuteRequest request,
    Duration timeout, {
    void Function(WorkerProgress progress)? onProgress,
    FutureOr<void> Function(WorkerActivity activity)? onActivity,
  }) async {
    process.stdin.writeln(request.encode());
    await process.stdin.flush();
    final timer = Stopwatch()..start();
    while (true) {
      final remaining = timeout - timer.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('deadline elapsed');
      }
      final line = await _nextProtocolLine(remaining, 'engine_execute');
      if (utf8.encode(line).length > maxFrameBytes) {
        throw const FormatException(
          'CLI Worker Engine frame exceeds the limit',
        );
      }
      final frame = decodeWorkerFrame(line);
      if (frame.requestId != request.requestId) {
        throw const FormatException('CLI Worker Engine request ID mismatch');
      }
      if (frame is WorkerProgress) {
        if (frame.assignmentId != request.assignmentId) {
          throw const FormatException(
            'CLI Worker Engine assignment ID mismatch',
          );
        }
        onProgress?.call(frame);
        continue;
      }
      if (frame is WorkerActivity) {
        if (frame.assignmentId != request.assignmentId) {
          throw const FormatException(
            'CLI Worker Engine assignment ID mismatch',
          );
        }
        final callback = onActivity;
        if (callback != null) {
          await Future.sync(() => callback(frame)).timeout(remaining);
        }
        continue;
      }
      if (frame is WorkerResult || frame is WorkerErrorFrame) {
        if (frame is WorkerResult &&
                frame.assignmentId != request.assignmentId ||
            frame is WorkerErrorFrame &&
                frame.assignmentId != request.assignmentId) {
          throw const FormatException(
            'CLI Worker Engine assignment ID mismatch',
          );
        }
        return frame;
      }
      throw const FormatException(
        'CLI Worker Engine returned an invalid frame',
      );
    }
  }

  Future<String> _nextProtocolLine(Duration timeout, String stage) async {
    final timer = Stopwatch()..start();
    while (true) {
      final remaining = timeout - timer.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('deadline elapsed');
      }
      if (!await _lines.moveNext().timeout(remaining)) {
        throw await _processExited(stage);
      }
      final line = _lines.current;
      if (_isDartVmServiceBanner(line)) {
        continue;
      }
      return line;
    }
  }

  bool _isDartVmServiceBanner(String line) =>
      line.startsWith('The Dart VM service is listening on ') ||
      line.startsWith(
        'The Dart DevTools debugger and profiler is available at: ',
      );

  Future<void> _drainStderr() async {
    await for (final bytes in process.stderr) {
      _stderrBytes = (_stderrBytes + bytes.length)
          .clamp(0, maxStderrBytes)
          .toInt();
    }
  }

  Future<void> dispose() async {
    await _lines.cancel();
    await _stderrTask;
  }

  Future<Never> _processExited(String stage) async {
    int? exitCode;
    try {
      exitCode = await process.exitCode.timeout(const Duration(seconds: 1));
    } on Object {
      // The process may still be unwinding; the closed stream is already
      // sufficient evidence that this execution cannot produce a result.
    }
    throw CliWorkerEngineProbeException(
      WorkerIssueCode.providerFailure,
      'CLI Worker Engine exited before producing a terminal result.',
      localDiagnostics: jsonEncode({
        'stage': stage,
        if (exitCode != null) 'processExitCode': exitCode,
      }),
    );
  }
}
