import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_external_worker_protocol/syntila_external_worker_protocol.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

import 'conversation_execution_router.dart';
import 'model_discovery.dart';
import 'engine_session_store.dart';
import 'worker_session.dart';
import 'external_worker_process_host.dart';
import 'external_worker_process_limits.dart';

/// Options for the plugin-mode Engine (`syntila-agent --plugin ...`). It has
/// no Tool Profile: the Workspace Service passes the verified plugin identity
/// in `initialize.request` (protocol 4.2) and re-asserts it on every execute.
class ExternalWorkerEngineOptions {
  ExternalWorkerEngineOptions({
    required this.engineVersion,
    required this.statePath,
  });

  final String engineVersion;
  final String statePath;

  static bool isExternalWorkerMode(List<String> arguments) =>
      arguments.contains('--plugin');

  static ExternalWorkerEngineOptions parse(List<String> arguments) {
    final values = <String, String>{};
    var sawPlugin = false;
    for (var index = 0; index < arguments.length; index++) {
      final key = arguments[index];
      if (key == '--plugin') {
        if (sawPlugin) throw const FormatException('duplicate --plugin');
        sawPlugin = true;
        continue;
      }
      if (!const {'--engine-version', '--state-directory'}.contains(key) ||
          values.containsKey(key) ||
          index + 1 >= arguments.length) {
        throw const FormatException(
          'expected --plugin, --engine-version and --state-directory',
        );
      }
      values[key] = arguments[++index];
    }
    final version = values['--engine-version'];
    final state = values['--state-directory'];
    if (!sawPlugin ||
        version == null ||
        state == null ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        !Directory(state).isAbsolute) {
      throw const FormatException('Engine options are incomplete or invalid');
    }
    return ExternalWorkerEngineOptions(
      engineVersion: version,
      statePath: state,
    );
  }
}

/// Protocol 4.2 process loop for one plugin Worker. Provider-neutral and
/// plugin-neutral: it admits the identity it was told about, then delegates
/// all process supervision to [ExternalWorkerProcessHost].
class ExternalWorkerEngine {
  ExternalWorkerEngine({
    required this.options,
    ExternalWorkerProcessHost? host,
    ConversationExecutionRouter router = const ConversationExecutionRouter(),
  }) : _host =
           host ??
           ExternalWorkerProcessHost(
             supervisor: LimitedExternalWorkerSupervisor(),
           ),
       _router = router;

  final ExternalWorkerEngineOptions options;
  final ExternalWorkerProcessHost _host;
  final ConversationExecutionRouter _router;
  InitializeRequest? _admitted;

  /// Stable Worker issue codes for plugin outcomes; no new wire codes.
  static (String code, bool retryable) mapFailure(
    ExternalWorkerRunFailure failure,
  ) {
    if (failure.fromPlugin) {
      return switch (failure.code) {
        'cancelled' => (WorkerIssueCode.cancelled, false),
        'timeout' => (WorkerIssueCode.deadlineExceeded, true),
        'sign_in_required' => (
          WorkerIssueCode.providerAuthenticationRequired,
          false,
        ),
        'not_ready' => (WorkerIssueCode.providerUnavailable, true),
        'rate_limited' => (WorkerIssueCode.quotaExhausted, true),
        'unsupported_policy' => (WorkerIssueCode.permissionDenied, false),
        'context_limit_exceeded' => (
          WorkerIssueCode.contextLimitExceeded,
          false,
        ),
        'model_unavailable' => (WorkerIssueCode.modelNotSupported, false),
        'session_commit_failed' => (WorkerIssueCode.sessionResumeFailed, false),
        'session_not_found' => (WorkerIssueCode.sessionResumeFailed, true),
        _ => (WorkerIssueCode.providerFailure, failure.retryable),
      };
    }
    return switch (failure.code) {
      'timeout' => (WorkerIssueCode.deadlineExceeded, true),
      'cancelled' => (WorkerIssueCode.cancelled, false),
      ExternalWorkerHostFailure.digestMismatch ||
      ExternalWorkerHostFailure.identityMismatch => (
        WorkerIssueCode.profileIdentityMismatch,
        false,
      ),
      ExternalWorkerHostFailure.protocolUnsupported => (
        WorkerIssueCode.profileSchemaIncompatible,
        false,
      ),
      'context_limit_exceeded' => (WorkerIssueCode.contextLimitExceeded, false),
      ExternalWorkerHostFailure.crashed => (
        WorkerIssueCode.providerFailure,
        true,
      ),
      _ => (WorkerIssueCode.providerFailure, false),
    };
  }

  Future<void> run({Stream<List<int>>? input, IOSink? output}) async {
    try {
      await _serve(input: input, output: output);
    } finally {
      await _host.close();
    }
  }

  Future<void> _serve({Stream<List<int>>? input, IOSink? output}) async {
    final sink = output ?? stdout;
    final lines = (input ?? stdin)
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final frame = decodeWorkerFrame(line);
        switch (frame) {
          case InitializeRequest():
            await _initialize(frame, sink);
          case ProbeRequest():
            await _probe(frame, sink);
          case ExecuteRequest():
            await _execute(frame, sink);
          case ConformanceRequest():
            await _conformance(frame, sink);
          default:
            throw FormatException('unsupported request frame: ${frame.type}');
        }
      } on FormatException catch (error) {
        await _write(
          sink,
          WorkerErrorFrame(
            requestId: _requestId(line),
            code: WorkerIssueCode.malformedFrame,
            message: error.message.length > 256
                ? 'Malformed protocol frame'
                : error.message,
          ),
        );
      } on Object {
        await _write(
          sink,
          WorkerErrorFrame(
            requestId: _requestId(line),
            code: WorkerIssueCode.workerInternalFailure,
            message: 'Engine request failed',
          ),
        );
      }
    }
  }

  Future<void> _initialize(InitializeRequest request, IOSink sink) async {
    if (request.executor == null) {
      return _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.profileIdentityMismatch,
          message: 'A plugin Engine requires a plugin executor identity',
        ),
      );
    }
    if (!request.executor!.isMcp) {
      return _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.profileSchemaIncompatible,
          message: 'Only MCP Workers (kind: "mcp") are supported',
        ),
      );
    }
    if (request.expectedEngineVersion != options.engineVersion) {
      return _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.engineVersionMismatch,
          message: 'Engine version does not match Workspace admission',
        ),
      );
    }
    _admitted = request;
    await _write(
      sink,
      InitializeResult(
        protocolVersion: request.protocolVersion,
        requestId: request.requestId,
        workerTypeId: request.workerTypeId,
        engineVersion: options.engineVersion,
        profileDefinitionId: request.profileDefinitionId,
        profileReleaseVersion: request.profileReleaseVersion,
        profileSchemaVersion: 1,
        capabilities: const [],
      ),
    );
  }

  ExternalWorkerLaunch _launch(WorkerExecutor executor) => ExternalWorkerLaunch(
    executable: executor.executable,
    arguments: executor.arguments,
    artifactSha256: executor.artifactSha256,
    pluginId: executor.pluginId,
    version: executor.version,
    dataDirectory: executor.dataDirectory,
    workingDirectory: Directory.current.path,
    environment: {
      ...ExternalWorkerProcessHost.buildEnvironment(
        consentedNames: executor.environmentNames,
      ),
      // MCP has no handshake to carry the data directory. Set by the host
      // only: a Worker's own `SYNTILA_*` names are never inherited.
      'SYNTILA_PLUGIN_DATA_DIR': executor.dataDirectory,
    },
    hostVersion: options.engineVersion,
    mcpToolPins: executor.toolPins,
  );

  WorkerErrorFrame _notInitialized(String requestId) => WorkerErrorFrame(
    requestId: requestId,
    code: WorkerIssueCode.workerInternalFailure,
    message: 'Engine is not initialized',
  );

  Future<void> _probe(ProbeRequest request, IOSink sink) async {
    final admitted = _admitted;
    if (admitted == null) {
      return _write(sink, _notInitialized(request.requestId));
    }
    final outcome = await _host.run(
      _launch(admitted.executor!),
      ExternalWorkerRunRequest.probe(
        executeId: request.requestId,
        mode: request.mode.name,
        deadline: Duration(milliseconds: request.timeoutMs),
      ),
    );
    switch (outcome) {
      case ExternalWorkerProbeSuccess():
        var ready = outcome.state == 'ready';
        String? issue = ready ? null : _probeIssue(outcome.state);
        final cache = ModelDiscoveryCache(options.statePath);
        final executor = admitted.executor!;
        var catalog = await cache.load(
          executor.manifestDigest,
          executor.version,
        );
        if (outcome.capabilities['modelDiscovery'] == true &&
            (request.mode == WorkerProbeMode.live ||
                catalog == null ||
                catalog.stale ||
                DateTime.now().toUtc().difference(
                      DateTime.parse(catalog.discoveredAt),
                    ) >=
                    const Duration(minutes: 1))) {
          final discovery = await _host.run(
            _launch(executor),
            ExternalWorkerRunRequest.models(
              executeId: request.requestId,
              deadline: const Duration(seconds: 8),
            ),
          );
          if (discovery is ExternalWorkerModelsSuccess) {
            catalog = DiscoveredModelCatalog(
              schemaVersion: 2,
              profileDigest: executor.manifestDigest,
              providerToolVersion: executor.version,
              discoveredAt: DateTime.now().toUtc().toIso8601String(),
              models: discovery.models.map(
                (m) => DiscoveredModel(
                  id: m['id'] as String,
                  name: m['name'] as String,
                  status: m['status'] as String? ?? 'listed',
                ),
              ),
            );
            await cache.save(catalog);
          } else {
            catalog = catalog?.withStale(true);
            if (catalog != null) await cache.save(catalog);
          }
        }
        if (outcome.capabilities['modelDiscovery'] == true &&
            ready &&
            (catalog == null || catalog.stale || catalog.models.isEmpty)) {
          ready = false;
          issue = catalog != null && catalog.models.isEmpty
              ? WorkerIssueCode.providerToolUnavailable
              : WorkerIssueCode.providerUnavailable;
        }
        await _write(
          sink,
          ProbeResult(
            requestId: request.requestId,
            mode: request.mode,
            ready: ready,
            modelCatalog: catalog,
            checks: [
              for (final check in outcome.checks.take(
                WorkerProtocolLimits.maxProbeChecks,
              ))
                ProbeCheck(
                  code: _checkCode(check['code']),
                  status: check['ok'] == true
                      ? ProbeCheckStatus.passed
                      : ProbeCheckStatus.failed,
                  message: _safeText(
                    check['message'],
                    WorkerProtocolLimits.maxCheckMessageLength,
                  ),
                ),
            ],
            issueCode: issue,
          ),
        );
      case ExternalWorkerRunFailure():
        final (code, _) = mapFailure(outcome);
        await _write(
          sink,
          ProbeResult(
            requestId: request.requestId,
            mode: request.mode,
            ready: false,
            checks: const [],
            issueCode: code,
            diagnostics: 'plugin_code=${outcome.code}',
          ),
        );
      case ExternalWorkerRunSuccess() || ExternalWorkerModelsSuccess():
        await _write(sink, _notInitialized(request.requestId));
    }
  }

  /// The NDJSON conformance suite is gone. The Workspace inspects MCP Worker
  /// tools itself (`syntila workers inspect`), so this request is refused.
  Future<void> _conformance(ConformanceRequest request, IOSink sink) async {
    if (_admitted == null) {
      return _write(sink, _notInitialized(request.requestId));
    }
    return _write(
      sink,
      WorkerErrorFrame(
        requestId: request.requestId,
        code: WorkerIssueCode.profileSchemaIncompatible,
        message: 'Conformance runs are not available for MCP Workers',
      ),
    );
  }

  Future<void> _execute(ExecuteRequest request, IOSink sink) async {
    final admitted = _admitted;
    if (admitted == null) {
      return _write(sink, _notInitialized(request.requestId));
    }
    final executor = request.executor;
    if (executor == null ||
        jsonEncode(executor.toJson()) !=
            jsonEncode(admitted.executor!.toJson())) {
      return _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          code: WorkerIssueCode.profileIdentityMismatch,
          message: 'Execution does not match the admitted plugin identity',
        ),
      );
    }
    if (request.additionalDirectories.isNotEmpty) {
      return _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          code: WorkerIssueCode.permissionDenied,
          message: 'Plugins cannot use additional folders yet',
        ),
      );
    }
    final clock = Stopwatch()..start();
    final metadata = await _host.run(
      _launch(executor),
      ExternalWorkerRunRequest.probe(
        executeId: request.requestId,
        mode: 'passive',
        deadline: Duration(milliseconds: request.timeoutMs.clamp(1, 8000)),
      ),
    );
    if (metadata is! ExternalWorkerProbeSuccess) {
      final failure = metadata is ExternalWorkerRunFailure
          ? metadata
          : const ExternalWorkerRunFailure(
              code: 'not_ready',
              message: 'Plugin capabilities unavailable',
            );
      final (code, retryable) = mapFailure(failure);
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          code: code,
          message: failure.message,
          diagnostics: 'plugin_code=${failure.code}',
          retryable: retryable,
        ),
      );
      return;
    }
    final caps = metadata.capabilities;
    final continuity = caps['continuity'] is Map
        ? caps['continuity'] as Map
        : const {};
    final strategy =
        continuity['strategy'] ??
        (caps['sessionResume'] == true ? 'native_handle' : 'none');
    final durable = request.sessionPolicy == WorkerSessionPolicy.durableSession;
    if (durable && strategy == 'none') {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          code: WorkerIssueCode.sessionResumeFailed,
          message: 'Plugin does not support conversation continuity',
        ),
      );
      return;
    }
    if (request.compactContext || request.reasoningEffort != null) {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          code: WorkerIssueCode.modelNotSupported,
          message:
              'This plugin contract does not support compaction or reasoning effort',
        ),
      );
      return;
    }
    final native =
        durable && const {'native_handle', 'checkpoint'}.contains(strategy);
    final store = EngineSessionStore(Directory(options.statePath));
    // Pin execution state to the admitted package; changed adapters rebuild.
    final identity = '${executor.pluginId}:${executor.manifestDigest}';
    final format = continuity['formatId'] as String? ?? 'plugin-legacy-v1';
    EngineSessionLease? lease;
    try {
      if (native) {
        lease = await store.acquireExecution(
          sessionKey: request.sessionKey!,
          workerTypeId: admitted.workerTypeId,
          profileDefinitionId: admitted.profileDefinitionId,
          providerToolIdentity: identity,
        );
      }
      WorkerSession? stored;
      final prior = !native
          ? null
          : await store.read(
              sessionKey: request.sessionKey!,
              workerTypeId: admitted.workerTypeId,
              profileDefinitionId: admitted.profileDefinitionId,
              providerToolIdentity: identity,
              compatibleFormatIds: [format],
              workerSession: request.workerSession,
              modelSwitchSupported: continuity['modelSwitchSupported'] == true,
              requestedModelId: request.model,
              requestedEffort: request.reasoningEffort,
              allowModelReconstruction:
                  request.workerSession?.bootstrap != null,
              allowContextSynchronization:
                  request.workerSession?.bootstrap?.turnRevision != null,
              executionPolicy: request.executionPolicy.wireValue,
              executionPolicyBound: true,
              onSessionRead: (value) => stored = value,
            );
      var plan = _router.prepare(
        request,
        nativeSessionId: prior,
        storedSession: stored,
      );
      final remaining = request.timeoutMs - clock.elapsedMilliseconds;
      if (remaining <= 0) throw const ExternalWorkerFailureDeadline();
      Future<ExternalWorkerRunOutcome> invoke(
        String prompt,
        String mode,
      ) => _host.run(
        _launch(executor),
        ExternalWorkerRunRequest(
          executeId: request.requestId,
          prompt: prompt,
          access: request.executionPolicy == WorkerExecutionPolicy.restricted
              ? 'read_only'
              : 'read_write',
          deadline: Duration(
            milliseconds: (request.timeoutMs - clock.elapsedMilliseconds).clamp(
              1,
              request.timeoutMs,
            ),
          ),
          model: request.model,
          sessionKey: native ? request.sessionKey : null,
          sessionMode: mode == 'rebuild' && continuity.isEmpty ? 'new' : mode,
        ),
        onWorkStarted: () => unawaited(
          _write(
            sink,
            WorkerProgress(
              requestId: request.requestId,
              assignmentId: request.assignmentId,
              percentage: 0,
              message: workerProviderExecutionStartedMessage,
            ),
          ),
        ),
        onProgress: (percentage, message) => unawaited(
          _write(
            sink,
            WorkerProgress(
              requestId: request.requestId,
              assignmentId: request.assignmentId,
              percentage: percentage?.toDouble() ?? 0,
              message: _safeText(
                message,
                WorkerProtocolLimits.maxProgressMessageLength,
              ),
            ),
          ),
        ),
      );
      var resumed = prior != null;
      var outcome = await invoke(
        plan.prompt,
        resumed
            ? 'resume'
            : stored != null
            ? 'rebuild'
            : 'new',
      );
      if (native &&
          resumed &&
          outcome is ExternalWorkerRunFailure &&
          outcome.fromPlugin &&
          outcome.code == 'session_not_found' &&
          request.workerSession?.bootstrap != null &&
          clock.elapsedMilliseconds < request.timeoutMs) {
        await store.quarantine(
          sessionKey: request.sessionKey!,
          workerTypeId: admitted.workerTypeId,
          profileDefinitionId: admitted.profileDefinitionId,
          providerToolIdentity: identity,
        );
        plan = _router.prepare(request, reconstruct: true);
        resumed = false;
        outcome = await invoke(plan.prompt, 'rebuild');
      }
      switch (outcome) {
        case ExternalWorkerRunSuccess():
          if (native) {
            final expected = resumed ? 'resumed' : 'created';
            if (outcome.sessionState != expected) {
              throw const FormatException(
                'Plugin did not confirm the requested session transition',
              );
            }
            await store.write(
              sessionKey: request.sessionKey!,
              workerTypeId: admitted.workerTypeId,
              profileDefinitionId: admitted.profileDefinitionId,
              providerToolIdentity: identity,
              profileReleaseVersion: 1,
              sessionFormatId: format,
              sessionId: request.sessionKey!,
              workerSession: request.workerSession,
              modelId: request.model,
              synchronizedContextRevision:
                  plan.bootstrap?.turnRevision ??
                  plan.bootstrap?.contextRevision,
              synchronizedHistorySequence: plan.bootstrap?.throughSequence,
              executionPolicy: request.executionPolicy.wireValue,
            );
          }
          await _write(
            sink,
            WorkerResult(
              requestId: request.requestId,
              assignmentId: request.assignmentId,
              output: outcome.output,
              artifacts: const [],
            ),
          );
        case ExternalWorkerRunFailure():
          if (native) {
            // An interrupted adapter may have advanced its state. Never resume
            // that state until canonical reconstruction establishes a new mapping.
            await store.quarantine(
              sessionKey: request.sessionKey!,
              workerTypeId: admitted.workerTypeId,
              profileDefinitionId: admitted.profileDefinitionId,
              providerToolIdentity: identity,
            );
          }
          final (code, retryable) = mapFailure(outcome);
          await _write(
            sink,
            WorkerErrorFrame(
              requestId: request.requestId,
              assignmentId: request.assignmentId,
              code: code,
              message: _safeText(outcome.message, 2048),
              retryable: retryable,
              diagnostics:
                  'plugin_code=${outcome.code}'
                  '${outcome.code == 'context_limit_exceeded' ? '\nModel context window exceeded' : ''}',
            ),
          );
        case ExternalWorkerProbeSuccess() || ExternalWorkerModelsSuccess():
          await _write(sink, _notInitialized(request.requestId));
      }
    } on ExternalWorkerFailureDeadline {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          code: WorkerIssueCode.deadlineExceeded,
          message: 'Plugin preparation exceeded the request deadline',
        ),
      );
    } on Object catch (error) {
      if (lease != null) {
        try {
          await store.quarantine(
            sessionKey: request.sessionKey!,
            workerTypeId: admitted.workerTypeId,
            profileDefinitionId: admitted.profileDefinitionId,
            providerToolIdentity: identity,
          );
        } on Object {
          /* Preserve files and fail closed if quarantine is unavailable. */
        }
      }
      await _write(
        sink,
        WorkerErrorFrame(
          diagnostics: error is FormatException
              ? error.message
              : error.runtimeType.toString(),
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          code: WorkerIssueCode.sessionResumeFailed,
          message:
              'Plugin continuity could not be validated or committed; canonical reconstruction is required',
        ),
      );
    } finally {
      await lease?.release();
    }
  }

  static String _probeIssue(String state) => switch (state) {
    'setup_required' => WorkerIssueCode.providerToolUnavailable,
    'sign_in_required' => WorkerIssueCode.providerAuthenticationRequired,
    'unavailable' => WorkerIssueCode.providerUnavailable,
    _ => WorkerIssueCode.providerFailure,
  };

  static String _checkCode(Object? raw) {
    final lowered = (raw is String ? raw : 'check').toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9_]'),
      '_',
    );
    final code = RegExp(r'^[a-z]').hasMatch(lowered)
        ? lowered
        : 'check_$lowered';
    return code.length > WorkerProtocolLimits.maxCheckCodeLength
        ? code.substring(0, WorkerProtocolLimits.maxCheckCodeLength)
        : code;
  }

  /// Removes control characters and bounds the length; never throws.
  static String _safeText(Object? raw, int max) {
    final text = (raw is String ? raw : '').replaceAll(
      RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]'),
      ' ',
    );
    return text.length > max ? text.substring(0, max) : text;
  }

  String _requestId(String line) {
    final match = RegExp(
      r'"requestId"\s*:\s*"([A-Za-z0-9._:-]{1,128})"',
    ).firstMatch(line);
    return match?.group(1) ?? 'unknown';
  }

  /// Every frame goes through one queue: progress is emitted without awaiting,
  /// and an IOSink forbids a write while a flush is pending. Order is kept.
  Future<void> _writes = Future<void>.value();

  Future<void> _write(IOSink sink, WorkerFrame frame) {
    final line = frame.encode();
    final next = _writes.then((_) async {
      sink.writeln(line);
      await sink.flush();
    });
    _writes = next.catchError((Object _) {});
    return next;
  }
}

class ExternalWorkerFailureDeadline implements Exception {
  const ExternalWorkerFailureDeadline();
}
