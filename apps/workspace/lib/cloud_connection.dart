import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_protocol/syntila_protocol.dart';
import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart'
    show SafeProviderDiagnostics;
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

import 'assignment_execution_failure.dart';
import 'assignment_journal.dart';
import 'assignment_trace.dart';
import 'worker_diagnostic_store.dart';
import 'workspace_connection_stage.dart';
import 'workspace_registration.dart';
import 'workspace_transport.dart';

export 'assignment_execution_failure.dart';
export 'websocket_workspace_transport.dart';
export 'workspace_connection_stage.dart';

part 'cloud_connection/assignment_handlers.dart';

class WorkspaceAssignmentContext {
  const WorkspaceAssignmentContext({
    required this.workspaceId,
    required this.workspaceRuntimeId,
    required this.workerId,
    required this.runId,
    required this.taskId,
    required this.attemptId,
    required this.assignmentId,
    required this.idempotencyKey,
    required this.payload,
  });

  final String workspaceId;
  final String workspaceRuntimeId;
  final String workerId;
  final String runId;
  final String taskId;
  final String attemptId;
  final String assignmentId;
  final String idempotencyKey;
  final Map<String, Object?> payload;

  String get executionId => payload['executionId'] is String &&
          (payload['executionId'] as String).isNotEmpty
      ? payload['executionId'] as String
      : assignmentId;

  WorkspaceAssignmentContext copyWith({
    String? workerId,
    Map<String, Object?>? payload,
  }) =>
      WorkspaceAssignmentContext(
        workspaceId: workspaceId,
        workspaceRuntimeId: workspaceRuntimeId,
        workerId: workerId ?? this.workerId,
        runId: runId,
        taskId: taskId,
        attemptId: attemptId,
        assignmentId: assignmentId,
        idempotencyKey: idempotencyKey,
        payload: payload ?? this.payload,
      );
}

final class _PendingWorkerActivity {
  const _PendingWorkerActivity({
    required this.context,
    required this.activity,
    required this.replaceableKey,
  });

  final WorkspaceAssignmentContext context;
  final WorkerActivity activity;
  final String? replaceableKey;
}

class WorkspaceAssignmentResult {
  const WorkspaceAssignmentResult({
    required this.summary,
    this.output,
    this.artifactIds = const [],
    this.evidence,
  });

  final String summary;
  final Map<String, Object?>? output;
  final List<String> artifactIds;
  final Map<String, Object?>? evidence;
}

typedef WorkspaceAssignmentHandler = Future<WorkspaceAssignmentResult> Function(
    WorkspaceAssignmentContext context);
typedef WorkspaceAssignmentCancellationHandler = Future<bool> Function(
  String assignmentId,
  String reason,
);
typedef WorkspaceUpdateAvailableHandler = Future<void> Function(
  Map<String, Object?> payload,
);

/// Service-level connection state published to Cloud. It describes the Service
/// as a transport endpoint only; Worker eligibility is reported separately
/// through inventory. Only [ready] may be handed new assignments.
enum ServiceConnectionState {
  disconnected,
  connecting,
  authenticated,
  synchronizing,
  ready,
  paused,
  draining,
  reconnecting;

  /// The state name used on the wire (`workspace.readiness`).
  String get wireName => name;
}

/// Capability advertised in the hello so Cloud trusts published readiness
/// instead of inferring it.
const serviceReadinessCapability = 'workspace.readiness.v1';

/// Capability Cloud announces in `hello.ack` when it accepts
/// `assignment.startup` progress for accepted, not-yet-running assignments.
const assignmentStartupCapability = 'assignment.startup.v1';

/// Capability Cloud announces in `hello.ack` when its inventory schema accepts
/// the optional plugin `executor` object (ADR-027). Plugin Workers are only
/// reported after the announcement; an older Cloud would reject the field.
const pluginExecutorsCapability = 'workspace.worker_plugins.v1';

/// Capability Cloud announces in `hello.ack` when its inventory schema accepts
/// `allowedFolders`. Older Cloud rejects unknown inventory fields, so the
/// Service omits the list until this is announced.
const allowedFoldersCapability = 'workspace.allowed_folders.v1';

class WorkspaceConnectionPreflightException implements Exception {
  const WorkspaceConnectionPreflightException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Flattens an `assignment.start` payload exactly as the handler does.
Map<String, dynamic> _flattenAssignmentPayload(Map<String, dynamic> payload) =>
    payload['snapshot'] is Map
        ? <String, dynamic>{
            ...(payload['snapshot'] as Map).cast<String, dynamic>(),
            if (payload['input'] is Map)
              'input': (payload['input'] as Map).cast<String, dynamic>(),
          }
        : payload;

/// Local send time of a message whose acknowledgement carries Cloud time.
final class _ClockProbe {
  _ClockProbe() : sentAt = DateTime.now().toUtc();

  final DateTime sentAt;
  final Stopwatch timer = Stopwatch()..start();
}

class WorkspaceCloudConnection {
  WorkspaceCloudConnection({
    required this.uri,
    required this.workspaceRuntimeId,
    required this.workspaceId,
    required this.factory,
    this.fallbackFactory,
    Set<String>? authorizedWorkspaceIds,
    this.name = 'Syntila Workspace',
    String? hostname,
    this.workspaceVersion = syntilaWorkspaceAppVersion,
    Map<String, Object?>? capabilities,
    this.activeWorkerIds = const [],
    this.unreconciledAssignmentIds = const [],
    this.assignmentHandler,
    this.assignmentCancellationHandler,
    this.assignmentJournal,
    this.diagnosticStoreForWorkerType,
    this.localQueueLengthProvider,
    this.deadAssignmentIdsProvider,
    this.workerInventoryProvider,
    this.allowedFolderProvider,
    this.workerUsageProvider,
    this.inputAvailableHandler,
    this.onSessionReady,
    this.workspaceUpdateAvailableHandler,
    this.onKnownSpaces,
    this.heartbeat = const Duration(seconds: 15),
    this.reconnectBaseDelay = const Duration(seconds: 2),
    this.reconnectMaxDelay = const Duration(minutes: 2),
    this.protocolHandshakeTimeout = const Duration(seconds: 15),
    this.syncTimeout = const Duration(seconds: 20),
    this.terminalRedeliveryInterval = const Duration(seconds: 20),
    this.webSocketProbeInterval = const Duration(minutes: 5),
    // A probe is one cheap WSS handshake; keep retrying often enough that a
    // temporary WebSocket block does not leave the Service on HTTPS for hours.
    this.webSocketProbeMaxInterval = const Duration(minutes: 15),
    this.webSocketFailureLimit = 3,
    this.credentialAvailable = true,
    MonotonicCloudClock? startPermitClock,
  })  : authorizedWorkspaceIds = {
          workspaceId,
          ...?authorizedWorkspaceIds,
        },
        hostname = hostname ?? Platform.localHostname,
        capabilities = capabilities ?? _defaultCapabilities(),
        startPermitClock = startPermitClock ?? MonotonicCloudClock();

  final Uri uri;
  final String workspaceRuntimeId;
  final String workspaceId;
  final Set<String> authorizedWorkspaceIds;
  final WorkspaceTransportFactory factory;
  final WorkspaceTransportFactory? fallbackFactory;
  final String name;
  final String hostname;
  final String workspaceVersion;
  final Map<String, Object?> capabilities;
  final List<String> activeWorkerIds;
  final List<String> unreconciledAssignmentIds;
  final WorkspaceAssignmentHandler? assignmentHandler;
  final WorkspaceAssignmentCancellationHandler? assignmentCancellationHandler;
  final AssignmentJournal? assignmentJournal;

  /// Bounded local evidence for assignment lifecycle events. The store is
  /// optional so connection tests and offline-only runtimes need no logger.
  final WorkerDiagnosticStore Function(String workerTypeId)?
      diagnosticStoreForWorkerType;

  /// Number of assignments waiting for a local execution slot. Telemetry only.
  final int Function()? localQueueLengthProvider;

  /// Latency tracing state (see assignment_trace.dart). Telemetry only: no
  /// assignment decision reads these values.
  final AssignmentTraceRecorder traceRecorder = AssignmentTraceRecorder();
  final ClockOffsetEstimator clockOffset = ClockOffsetEstimator();
  final MonotonicCloudClock startPermitClock;
  final Map<String, _ClockProbe> _clockProbes = {};
  final Future<List<Map<String, Object?>>> Function()? workerInventoryProvider;

  /// Path-free summaries of the owner's Allowed Folders, published with each
  /// inventory snapshot so Cloud can offer them to the owner's Spaces.
  final Future<List<Map<String, Object?>>> Function()? allowedFolderProvider;

  /// Runs a Worker's Profile-defined usage command and returns the raw report
  /// as a `worker.usage.result` payload (without `requestId`). The report is
  /// forwarded verbatim; the Service never interprets it.
  final Future<Map<String, Object?>> Function(String workerId)?
      workerUsageProvider;

  /// Called on `input.available`: uploaded Work Request inputs can be
  /// listed and downloaded (Input Delivery v1). The message has no content.
  final void Function()? inputAvailableHandler;
  final Future<void> Function()? onSessionReady;
  final WorkspaceUpdateAvailableHandler? workspaceUpdateAvailableHandler;

  /// Receives the Space IDs Cloud still knows for this Workspace on each
  /// synchronization so local bookkeeping for removed Spaces can be dropped.
  final Future<void> Function(Set<String> knownSpaceIds)? onKnownSpaces;
  final Duration heartbeat;
  final Duration reconnectBaseDelay;
  final Duration reconnectMaxDelay;
  final Duration protocolHandshakeTimeout;
  final Duration syncTimeout;

  /// Base delay before re-sending an unacknowledged terminal result while the
  /// transport stays up; it doubles per attempt up to sixteen times.
  final Duration terminalRedeliveryInterval;
  int _terminalRedeliveryAttempt = 0;
  Timer? _terminalRedeliveryTimer;
  final Duration webSocketProbeInterval;
  final Duration webSocketProbeMaxInterval;
  int _webSocketProbeFailures = 0;
  int _transportGeneration = 0;
  final int webSocketFailureLimit;
  final bool credentialAvailable;
  WorkspaceTransport? _transport;

  /// Assignments whose Engine process is gone. Null when the Service cannot
  /// tell, in which case no liveness is reported.
  final Set<String> Function()? deadAssignmentIdsProvider;
  Timer? _heartbeatTimer;
  Timer? _heartbeatTimeoutTimer;
  Timer? _protocolHandshakeTimer;
  Timer? _syncTimer;
  Timer? _webSocketProbeTimer;
  StreamSubscription<Object?>? _subscription;
  Completer<void>? _reconnectWakeup;
  bool _closing = false;
  bool _reconnecting = false;
  bool _preferFallbackTransport = false;
  bool _probingWebSocket = false;
  int _reconnectAttempt = 0;
  int reconnectCount = 0;
  String? sessionId;
  bool get isConnected => sessionId != null;
  void Function()? onStateChanged;
  WorkspaceConnectionStage _connectionStage = WorkspaceConnectionStage.offline;
  WorkspaceConnectionStage get connectionStage => _connectionStage;
  set connectionStage(WorkspaceConnectionStage value) {
    if (_connectionStage == value) return;
    _connectionStage = value;
    _notifyStateChanged();
  }

  DateTime? lastConnectionAttemptAt;
  DateTime? lastWebSocketUpgradeAt;
  String? activeTransportMode;
  String? _pendingTransportMode;
  String? lastWebSocketFailure;
  int? lastWebSocketHttpStatusCode;
  DateTime? lastWebSocketFailureAt;
  String fallbackHealthStatus = 'not configured';
  String get transportMode => activeTransportMode ?? 'offline';
  DateTime? lastHelloSentAt;
  DateTime? lastHelloAcknowledgedAt;
  DateTime? lastReadyAt;
  String? lastConnectionError;
  int? lastHttpStatusCode;
  String lastDnsTlsStatus = 'not checked';
  bool _workerInventorySent = false;
  bool _syncResultReceived = false;
  bool _syncReconciliationComplete = false;
  String? _readyCallbackSessionId;
  String? _helloMessageId;
  String? _syncRequestMessageId;

  String get protocolHelloStatus {
    if (lastHelloSentAt == null) return 'not started';
    if (sessionId != null) return 'acknowledged';
    if (lastConnectionError?.contains('did not acknowledge workspace.hello') ==
        true) {
      return 'timed out';
    }
    return 'waiting for acknowledgement';
  }

  void validateConfiguration() {
    if (!credentialAvailable) {
      throw const WorkspaceConnectionPreflightException(
        'The Workspace runtime credential is missing from secure storage.',
      );
    }
    if (!const {'ws', 'wss'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        (uri.hasPort && (uri.port <= 0 || uri.port > 65535)) ||
        uri.hasFragment) {
      throw const WorkspaceConnectionPreflightException(
        'The Cloud WebSocket endpoint is invalid. Expected ws/wss, a workspace, '
        'a valid port, and no URL fragment.',
      );
    }
    if (uri.path != '/api/workspace-gateway/connect' ||
        uri.queryParameters['workspaceRuntimeId'] != workspaceRuntimeId) {
      throw const WorkspaceConnectionPreflightException(
        'The Cloud WebSocket endpoint must include the Workspace Gateway '
        'path and this runtime ID.',
      );
    }
  }

  int get activeAssignmentCount => _activeAssignments.length;
  bool _acceptingNewWork = true;
  bool get acceptingNewWork => _acceptingNewWork;
  set acceptingNewWork(bool value) {
    if (_acceptingNewWork == value) return;
    _acceptingNewWork = value;
    _notifyStateChanged();
  }

  bool get isDraining => _draining;
  bool _draining = false;
  DateTime? lastInventorySyncAt;

  void pauseNewWork() {
    acceptingNewWork = false;
    _draining = false;
    _publishReadiness(reason: 'paused');
  }

  void resumeNewWork() {
    _draining = false;
    acceptingNewWork = true;
    _publishReadiness(reason: 'resumed');
  }

  void beginDrain() {
    acceptingNewWork = false;
    _draining = true;
    _publishReadiness(reason: 'draining');
  }

  /// Increases each time this Service completes a synchronization with Cloud.
  /// Cloud ignores a readiness report from before the latest generation.
  int _syncGeneration = 0;
  bool _syncRequested = false;
  bool _helloAcknowledged = false;

  /// Whether this Cloud announced it understands `workspace.readiness`. An
  /// older Cloud would reject the message, so it is only sent after the
  /// announcement; the heartbeat carries readiness either way.
  bool _cloudAcceptsReadiness = false;

  /// Whether this Cloud announced `assignment.startup.v1`. Startup progress is
  /// only sent after the announcement; an older Cloud would reject it.
  bool _cloudAcceptsStartup = false;
  bool _cloudAcceptsAllowedFolders = false;
  bool _cloudAcceptsPluginExecutors = false;

  /// Whether this Cloud announced [pluginExecutorsCapability].
  bool get cloudAcceptsPluginExecutors => _cloudAcceptsPluginExecutors;

  /// The Service-level state Cloud should schedule against. `ready` is the
  /// only state that accepts assignments, and it requires the current
  /// synchronization to be complete and new work to be accepted.
  ServiceConnectionState get serviceState {
    if (_closing) return ServiceConnectionState.draining;
    switch (connectionStage) {
      case WorkspaceConnectionStage.validating:
      case WorkspaceConnectionStage.offline:
        return ServiceConnectionState.disconnected;
      case WorkspaceConnectionStage.connecting:
      case WorkspaceConnectionStage.authenticating:
        return ServiceConnectionState.connecting;
      case WorkspaceConnectionStage.synchronizing:
        return _syncRequested
            ? ServiceConnectionState.synchronizing
            : (_helloAcknowledged
                ? ServiceConnectionState.authenticated
                : ServiceConnectionState.connecting);
      case WorkspaceConnectionStage.ready:
        if (_draining) return ServiceConnectionState.draining;
        if (!acceptingNewWork) return ServiceConnectionState.paused;
        return ServiceConnectionState.ready;
      case WorkspaceConnectionStage.reconnecting:
      case WorkspaceConnectionStage.switchingToWebSocket:
        return ServiceConnectionState.reconnecting;
    }
  }

  /// `readyForAssignments` is derived from [serviceState], never set directly,
  /// so it cannot disagree with it.
  bool get readyForAssignments => serviceState == ServiceConnectionState.ready;

  Map<String, Object?> _readinessPayload({String? reason}) => {
        'state': serviceState.wireName,
        'readyForAssignments': readyForAssignments,
        'syncGeneration': _syncGeneration,
        if (reason != null) 'reason': reason,
        if (_pendingAssignmentsDuringSync.isNotEmpty)
          'pendingAssignments': _pendingAssignmentsDuringSync.length,
      };

  /// Publishes the current readiness to Cloud immediately. Used when sync
  /// completes, new work is paused or resumed, and shutdown begins. The
  /// heartbeat repeats it, so a lost message heals within one interval.
  void _publishReadiness({String? reason}) {
    final socket = _transport;
    if (socket == null || sessionId == null || !_cloudAcceptsReadiness) return;
    try {
      socket.send(jsonEncode({
        ..._envelope('workspace.readiness', _readinessPayload(reason: reason)),
        'executionWorkspaceId': workspaceId,
        'workspaceRuntimeId': workspaceRuntimeId,
      }));
    } on Object {
      // Readiness is repeated on the next heartbeat; never disturb the
      // connection for it.
    }
  }

  Future<void> refreshWorkerInventory() => _reportCurrentWorkerInventory();
  List<String> get activeAssignmentIds => _activeAssignments.toList()..sort();

  Future<bool> cancelActiveAssignment(
    String assignmentId, {
    String reason = 'Cancelled by Workspace user',
  }) async {
    if (!_activeAssignments.contains(assignmentId)) return false;
    final cancel = assignmentCancellationHandler;
    if (cancel == null) return false;
    return cancel(assignmentId, reason);
  }

  /// Forgets assignments this Service still counts as active. Only used by the
  /// user-initiated slot reset after those assignments were cancelled; Cloud
  /// reconciles their final state on the next synchronization.
  void forgetActiveAssignments() {
    _activeAssignments.clear();
    _cancelledBeforeStart.clear();
  }

  int _messageSequence = 0;
  int _heartbeatCount = 0;
  Map<String, Object?>? syncResponse;
  final _activeAssignments = <String>{};
  final _cancelledBeforeStart = <String>{};

  /// Capability advertised in the hello so Cloud requires a start permit
  /// before this Service launches an Engine process for an assignment.
  static const startPermitCapability = 'assignment.start_permit.v1';
  static const _startPermitTimeout = Duration(seconds: 15);
  static const _startPermitResendInterval = Duration(seconds: 3);
  static const _prefetchedStartPermitRetention = Duration(minutes: 2);
  final _pendingStartPermits = <String, Completer<DateTime?>>{};
  final _startPermitContexts = <String, WorkspaceAssignmentContext>{};
  final _prefetchedStartPermits = <String, _PrefetchedStartPermit>{};
  final _pendingAssignmentsDuringSync = <Map<String, dynamic>>[];
  static const _maxPendingActivityEvents = 256;
  final _pendingActivityEvents = <_PendingWorkerActivity>[];
  final _activitySpaceWaiters = <Completer<void>>[];
  bool _drainingActivityEvents = false;

  void _notifyStateChanged() => onStateChanged?.call();

  Future<void> recordAssignmentDiagnostic(
    WorkspaceAssignmentContext context, {
    required String event,
    required String stage,
    String severity = 'info',
    String? errorCode,
    bool retryable = false,
    Map<String, Object?> contextData = const {},
  }) async {
    try {
      final store = diagnosticStoreForWorkerType?.call(_workerTypeId(context));
      if (store == null) return;
      await store.record(
        workerTypeId: _workerTypeId(context),
        workerVersion: workspaceVersion,
        protocolStage: 'assignment',
        event: event,
        requestId: _requestId(context),
        assignmentId: context.assignmentId,
        workspaceId: context.workspaceId,
        workspaceRuntimeId: context.workspaceRuntimeId,
        workerId: context.workerId,
        runId: context.runId,
        taskId: context.taskId,
        attemptId: context.attemptId,
        component: 'workspace_service',
        operation: 'assignment',
        stage: stage,
        level: severity,
        retryable: retryable,
        errorCode: errorCode,
        context: {
          ..._assignmentMetadata(context),
          ...contextData,
        },
      );
    } on Object {
      // Diagnostics must never change assignment behavior.
    }
  }

  static String _workerTypeId(WorkspaceAssignmentContext context) {
    final value = context.payload['workerTypeId'] ??
        (context.payload['snapshot'] is Map
            ? (context.payload['snapshot'] as Map)['workerTypeId']
            : null);
    return value is String && value.isNotEmpty ? value : context.workerId;
  }

  static String? _requestId(WorkspaceAssignmentContext context) {
    final value = context.payload['requestId'] ??
        context.payload['workRequestId'] ??
        (context.payload['input'] is Map
            ? (context.payload['input'] as Map)['workRequestId']
            : null);
    return value is String &&
            value.isNotEmpty &&
            value.length <= 128 &&
            RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)
        ? value
        : null;
  }

  static Map<String, Object?> _assignmentMetadata(
    WorkspaceAssignmentContext context,
  ) {
    final snapshot = context.payload['snapshot'];
    final values = <String, Object?>{
      if (context.payload['modelId'] != null)
        'modelId': context.payload['modelId'],
      if (context.payload['reasoningEffort'] != null)
        'effort': context.payload['reasoningEffort'],
      if (snapshot is Map) ...{
        if (snapshot['modelId'] != null) 'modelId': snapshot['modelId'],
        if (snapshot['reasoningEffort'] != null)
          'effort': snapshot['reasoningEffort'],
        if (snapshot['profileDefinitionId'] != null)
          'profileDefinitionId': snapshot['profileDefinitionId'],
        if (snapshot['profileReleaseVersion'] != null)
          'profileReleaseVersion': snapshot['profileReleaseVersion'],
        if (snapshot['providerToolVersion'] != null)
          'providerToolVersion': snapshot['providerToolVersion'],
        if (snapshot['engineVersion'] != null)
          'engineVersion': snapshot['engineVersion'],
      },
    };
    return values;
  }

  void _rememberClockProbe(String messageId) {
    while (_clockProbes.length >= 8) {
      _clockProbes.remove(_clockProbes.keys.first);
    }
    _clockProbes[messageId] = _ClockProbe();
  }

  /// Feeds hello/heartbeat acknowledgements into the clock-offset estimate.
  void _recordClockSample(Map<String, dynamic> decoded) {
    try {
      final type = decoded['type'];
      if (type != 'workspace.hello.ack' && type != 'workspace.heartbeat.ack') {
        return;
      }
      if (decoded['workspaceRuntimeId'] != workspaceRuntimeId ||
          decoded['executionWorkspaceId'] != workspaceId) {
        return;
      }
      final correlationId = decoded['correlationId'];
      final probe =
          correlationId is String ? _clockProbes.remove(correlationId) : null;
      final payload = decoded['payload'];
      final serverTime = payload is Map ? payload['serverTime'] : null;
      if (probe == null || serverTime is! String) return;
      final parsed = DateTime.tryParse(serverTime);
      if (parsed == null) return;
      final roundTrip = probe.timer.elapsed;
      clockOffset.addSample(
        sentAtUtc: probe.sentAt,
        roundTrip: roundTrip,
        serverTimeUtc: parsed.toUtc(),
      );
      startPermitClock.addSample(serverTimeUtc: parsed, roundTrip: roundTrip);
    } on Object {
      // Invalid samples must not disrupt transport. Permit expiry fails
      // closed until a usable clock estimate is available.
    }
  }

  /// Point-in-time transport and load facts attached to every trace event.
  Map<String, Object?> _traceContext() {
    int? queueLength;
    try {
      queueLength = localQueueLengthProvider?.call();
    } on Object {
      queueLength = null;
    }
    final offset = clockOffset.offsetMs;
    final rtt = clockOffset.roundTripMs;
    return {
      'traceEpochId': processTraceEpochId(),
      'transport': activeTransportMode ?? _pendingTransportMode ?? 'offline',
      'syncState': connectionStage.name,
      'activeAssignments': _activeAssignments.length,
      if (queueLength != null && queueLength >= 0)
        'localQueueLength': queueLength,
      if (offset != null) 'clockOffsetMs': offset,
      if (rtt != null) 'clockRttMs': rtt,
    };
  }

  /// Additive, bounded facts sent to Cloud in the `assignment.ack` payload so
  /// Cloud-side logs can place Service timings on the Cloud clock.
  Map<String, Object?> _serviceTracePayload(String assignmentId) {
    final context = _traceContext();
    return {
      for (final key in const [
        'traceEpochId',
        'syncState',
        'activeAssignments',
        'localQueueLength',
        'clockOffsetMs',
        'clockRttMs',
      ])
        if (context[key] != null) key: context[key],
      if (traceRecorder.elapsedMs(assignmentId) != null)
        'receiveToAckMs': traceRecorder.elapsedMs(assignmentId),
    };
  }

  /// Starts the Service-side trace (T5) the moment the command comes off the
  /// transport, before any synchronization deferral or validation, so time
  /// spent waiting is attributed correctly. Detached and non-throwing.
  void _traceAssignmentReceived(Map<String, dynamic> decoded) {
    try {
      final id = decoded['assignmentId'];
      if (id is! String || id.isEmpty || id.length > 128) return;
      final first = traceRecorder.begin(id, note: connectionStage.name);
      if (first == null) return;
      final payload = decoded['payload'];
      if (payload is! Map<String, dynamic>) return;
      const requiredFields = [
        'executionWorkspaceId',
        'workspaceRuntimeId',
        'workerId',
        'runId',
        'taskId',
        'attemptId',
        'idempotencyKey',
      ];
      if (requiredFields.any((field) => decoded[field] is! String)) return;
      final context = WorkspaceAssignmentContext(
        workspaceId: decoded['executionWorkspaceId'] as String,
        workspaceRuntimeId: decoded['workspaceRuntimeId'] as String,
        workerId: decoded['workerId'] as String,
        runId: decoded['runId'] as String,
        taskId: decoded['taskId'] as String,
        attemptId: decoded['attemptId'] as String,
        assignmentId: id,
        idempotencyKey: decoded['idempotencyKey'] as String,
        payload: Map<String, Object?>.from(_flattenAssignmentPayload(payload)),
      );
      final traceContext = _traceContext();
      runDetachedTelemetry(() => recordAssignmentDiagnostic(
            context,
            event: 'assignment.trace',
            stage: 'trace',
            contextData: {
              ...traceContext,
              'traceStage': 'service_received',
              'monotonicMs': first.monotonicMs,
              'durationMs': 0,
            },
          ));
    } on Object {
      // Telemetry must never affect command handling.
    }
  }

  /// Records a Service-side latency stage for [context]. Synchronous and
  /// non-throwing; the diagnostic write is detached from the caller.
  void traceAssignmentStage(
    WorkspaceAssignmentContext context,
    String stage, {
    Map<String, Object?> extra = const {},
  }) {
    try {
      final mark = traceRecorder.mark(context.assignmentId, stage);
      if (mark == null) return;
      _publishAssignmentStartup(context, stage, extra);
      final traceContext = _traceContext();
      runDetachedTelemetry(() => recordAssignmentDiagnostic(
            context,
            event: 'assignment.trace',
            stage: 'trace',
            contextData: {
              ...traceContext,
              ...extra,
              'traceStage': stage,
              'monotonicMs': mark.monotonicMs,
              'durationMs': mark.sinceLastMs,
            },
          ));
    } on Object {
      // Telemetry must never affect command handling.
    }
  }

  static const _startupWireStages = <String, String>{
    'worker_resolved': 'worker_resolved',
    'profile_ready': 'profile_ready',
    'waiting_for_space': 'waiting_for_space',
    'queued_for_slot': 'queued_for_slot',
    'slot_reserved': 'slot_reserved',
    'engine_process_created': 'engine_spawned',
    'engine_initialized': 'engine_initialized',
  };

  /// Publishes a pre-start milestone to Cloud so a queued or starting
  /// assignment is visible. Best effort: dropped when the transport is down or
  /// Cloud did not announce [assignmentStartupCapability]; never throws.
  void _publishAssignmentStartup(
    WorkspaceAssignmentContext context,
    String traceStage,
    Map<String, Object?> detail,
  ) {
    try {
      final wireStage = _startupWireStages[traceStage];
      final socket = _transport;
      if (wireStage == null ||
          socket == null ||
          sessionId == null ||
          !_cloudAcceptsStartup) {
        return;
      }
      int? integer(String key, {int min = 0}) {
        final value = detail[key];
        return value is int && value >= min ? value : null;
      }

      final digest = detail['profileDigest'];
      final payload = <String, Object?>{
        'stage': wireStage,
        'at': DateTime.now().toUtc().toIso8601String(),
        if (integer('queuePosition', min: 1) case final value?)
          'queuePosition': value,
        if (integer('activeAssignments') case final value?)
          'activeSlots': value,
        if (integer('slotLimit', min: 1) case final value?) 'slotLimit': value,
        if (detail['waitingForSession'] is bool)
          'waitingForSession': detail['waitingForSession'],
        if (integer('queueWaitTimeoutMs') case final value?)
          'queueWaitTimeoutMs': value,
        if (digest is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(digest))
          'profileDigest': digest,
        if (integer('profileReleaseVersion') case final value?)
          'profileRevision': value,
      };
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.startup',
        _assignmentCorrelationForContext(context),
        payload,
      )));
    } on Object {
      // Progress reporting must never affect command handling.
    }
  }

  /// Bounded latency summary for diagnostics exports: transport and load
  /// facts plus p50/p95/p99 per stage interval.
  Map<String, Object?> latencySummary() => {
        ..._traceContext(),
        'openTraces': traceRecorder.activeTraceCount,
        'intervals': traceRecorder.summaryJson(),
      };

  /// Sends the Workspace-owned inventory projection. Secrets, credential
  /// references, and local paths must not be included by the caller.
  void reportWorkerInventory(
    List<Map<String, Object?>> workers, {
    List<Map<String, Object?>>? allowedFolders,
  }) {
    // Every Worker record carries the same Workspace-wide slot total.
    final slots = workers
        .map((worker) => worker['localConcurrencyLimit'])
        .whereType<int>()
        .firstOrNull;
    _sendIfConnected('worker.inventory', {
      'fullSnapshot': true,
      if (slots != null) 'parallelSlots': slots,
      'workers': workers,
      if (allowedFolders != null) 'allowedFolders': allowedFolders,
    });
  }

  Future<void> _reportCurrentWorkerInventory() async {
    final provider = workerInventoryProvider;
    if (provider == null) {
      _workerInventorySent = true;
      _completeSynchronizationWhenReady();
      return;
    }
    if (sessionId == null) return;
    try {
      List<Map<String, Object?>>? folders;
      try {
        folders = _cloudAcceptsAllowedFolders
            ? await allowedFolderProvider?.call()
            : null;
      } on Object {
        // An unreadable folder list must not hide Workers. Omitting the field
        // keeps Cloud's last known folders instead of clearing them.
        folders = null;
      }
      reportWorkerInventory(await provider(), allowedFolders: folders);
      lastInventorySyncAt = DateTime.now().toUtc();
      _workerInventorySent = true;
      _completeSynchronizationWhenReady();
    } on Object {
      lastConnectionError =
          'Workspace authenticated, but its Worker inventory could not be read.';
    }
  }

  /// Reports only logical Thread readiness. Local absolute paths and
  /// repository locations never cross the runtime boundary.
  void reportThreadStatus({
    required String spaceId,
    required String threadId,
    required String workingDirectoryState,
  }) {
    if (!const {'absent', 'ready', 'conflict', 'unavailable'}
        .contains(workingDirectoryState)) {
      throw ArgumentError.value(workingDirectoryState, 'workingDirectoryState');
    }
    _sendIfConnected('thread.status', {
      'spaceId': spaceId,
      'threadId': threadId,
      'workingDirectoryState': workingDirectoryState,
    });
  }

  /// Asks Cloud for permission to launch the Engine process for [context].
  ///
  /// Returns true only when Cloud grants a start permit bound to this
  /// assignment, attempt and runtime. Cloud denies the permit once the
  /// assignment has been revoked, so a timed-out or cancelled assignment that
  /// is still queued here can never launch late. The request fails closed: a
  /// denial, a missing reply within the timeout, or a lost connection returns
  /// false. A Cloud that does not require permits (older deployments) is
  /// signalled by the absence of `startPermit.required` in the assignment
  /// payload, in which case no round trip is made.
  Future<bool> requestStartPermit(WorkspaceAssignmentContext context) async {
    final startPermit = context.payload['startPermit'];
    if (startPermit is! Map || startPermit['required'] != true) return true;
    // A permit requested at admission saves the round trip here, but only
    // while it is still valid by Cloud's clock; otherwise ask again.
    final prefetched = _prefetchedStartPermits.remove(context.assignmentId);
    if (prefetched != null && prefetched.matches(context)) {
      final expiresAt = await prefetched.expiresAt;
      if (_startPermitStillValid(expiresAt)) return true;
    }
    final expiresAt = await _requestStartPermitExpiry(context);
    final granted = _startPermitStillValid(expiresAt);
    if (!granted) {
      await recordAssignmentDiagnostic(
        context,
        event: 'assignment.start_permit_denied',
        stage: 'startup',
        severity: 'warning',
        errorCode: 'start_permit_denied',
        retryable: false,
      );
    }
    return granted;
  }

  /// Requests the start permit right after admission so the grant overlaps
  /// local preparation instead of following it. Fencing is unchanged: the
  /// Engine still launches only after [requestStartPermit] sees a valid grant.
  void prefetchStartPermit(WorkspaceAssignmentContext context) {
    final startPermit = context.payload['startPermit'];
    if (startPermit is! Map || startPermit['required'] != true) return;
    final expiresAt = _requestStartPermitExpiry(context);
    _prefetchedStartPermits[context.assignmentId] =
        _PrefetchedStartPermit(context, expiresAt);
    // The entry is consumed by [requestStartPermit]; drop it if the
    // assignment ends before launch so it cannot outlive the attempt.
    unawaited(expiresAt.then((_) {
      Timer(WorkspaceCloudConnection._prefetchedStartPermitRetention, () {
        final current = _prefetchedStartPermits[context.assignmentId];
        if (identical(current?.expiresAt, expiresAt)) {
          _prefetchedStartPermits.remove(context.assignmentId);
        }
      });
    }));
  }

  bool _startPermitStillValid(DateTime? expiresAt) {
    final latestCloudNow = startPermitClock.latestServerTime;
    return expiresAt != null &&
        latestCloudNow != null &&
        expiresAt.isAfter(latestCloudNow);
  }

  /// Sends the permit request and resolves to the grant's expiry, or null
  /// when Cloud denies it, does not answer in time or the connection drops.
  Future<DateTime?> _requestStartPermitExpiry(
    WorkspaceAssignmentContext context,
  ) async {
    final assignmentId = context.assignmentId;
    final existing = _pendingStartPermits[assignmentId];
    if (existing != null) {
      final pending = _startPermitContexts[assignmentId];
      if (pending?.attemptId != context.attemptId ||
          pending?.workspaceRuntimeId != context.workspaceRuntimeId ||
          pending?.idempotencyKey != context.idempotencyKey) {
        return null;
      }
      return existing.future;
    }
    final completer = Completer<DateTime?>();
    _pendingStartPermits[assignmentId] = completer;
    _startPermitContexts[assignmentId] = context;
    final deadline = DateTime.now().add(_startPermitTimeout);
    Timer? resend;
    void send() {
      final socket = _transport;
      if (socket == null || sessionId == null) return;
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.start.permit.request',
        _assignmentCorrelationForContext(context),
        {'requestedAt': DateTime.now().toUtc().toIso8601String()},
      )));
    }

    try {
      send();
      resend = Timer.periodic(_startPermitResendInterval, (_) {
        if (completer.isCompleted) return;
        if (DateTime.now().isAfter(deadline)) return;
        send();
      });
      return await completer.future.timeout(
        _startPermitTimeout,
        onTimeout: () => null,
      );
    } finally {
      resend?.cancel();
      _pendingStartPermits.remove(assignmentId);
      _startPermitContexts.remove(assignmentId);
    }
  }

  void _handleStartPermitGrant(Map<String, dynamic> decoded) {
    final assignmentId = decoded['assignmentId'];
    final payload = decoded['payload'];
    if (assignmentId is! String || payload is! Map) return;
    final completer = _pendingStartPermits[assignmentId];
    if (completer == null || completer.isCompleted) return;
    // Bind the grant to the exact attempt that asked for it; a grant for a
    // previous attempt of the same assignment must never start this one.
    final context = _startPermitContexts[assignmentId];
    if (context == null) return;
    final correlation = _assignmentCorrelationForContext(context);
    for (final field in const [
      'executionWorkspaceId',
      'workspaceRuntimeId',
      'workerId',
      'runId',
      'taskId',
      'attemptId',
      'idempotencyKey',
    ]) {
      if (decoded[field] != correlation[field]) return;
    }
    final expiry = payload['expiresAt'];
    final expiresAt = expiry is String ? DateTime.tryParse(expiry) : null;
    final permitId = payload['permitId'];
    completer.complete(payload['granted'] == true &&
            permitId is String &&
            permitId.isNotEmpty &&
            _startPermitStillValid(expiresAt)
        ? expiresAt
        : null);
  }

  /// Records and reports the first evidence that the Engine and provider
  /// process have actually started. Admission acknowledgement alone is not a
  /// running signal.
  Future<void> reportWorkerStarted(WorkspaceAssignmentContext context) async {
    traceAssignmentStage(context, 'provider_started');
    await recordAssignmentDiagnostic(
      context,
      event: 'assignment.executing',
      stage: 'provider_execution',
    );
    await _recordAssignment(
      context.assignmentId,
      AssignmentStatus.running,
      context: context,
    );
    final socket = _transport;
    if (socket == null || sessionId == null) return;
    socket.send(jsonEncode(_assignmentEnvelope(
      'assignment.start.ack',
      _assignmentCorrelationForContext(context),
      {
        'started': true,
        'engineStarted': true,
        'providerStarted': true,
        'startedAt': DateTime.now().toUtc().toIso8601String(),
      },
    )));
  }

  /// Relays structured Worker Activity without throttling lifecycle events.
  /// Status-only events may replace an older queued status for the same
  /// assignment; tool lifecycle and terminal events apply backpressure until
  /// queue space is available. A disconnected transport retains the bounded
  /// queue so reconnect replay can forward the event independently of the
  /// provider process.
  Future<void> reportWorkerActivity(
    WorkspaceAssignmentContext context,
    WorkerActivity activity,
  ) async {
    if (activity.assignmentId != context.assignmentId) return;
    final replaceable = activity.eventType == 'model.status' ||
        activity.eventType == 'message.updated';
    final key =
        '${context.assignmentId}:${activity.eventType}:${activity.activityId ?? ''}';
    if (replaceable) {
      final index = _pendingActivityEvents.indexWhere(
        (item) => item.replaceableKey == key,
      );
      if (index >= 0) {
        _pendingActivityEvents[index] = _PendingWorkerActivity(
          context: context,
          activity: activity,
          replaceableKey: key,
        );
        _drainActivityEvents();
        return;
      }
    }
    if (_transport == null || sessionId == null) {
      if (_pendingActivityEvents.length >= _maxPendingActivityEvents) {
        unawaited(recordAssignmentDiagnostic(
          context,
          event: 'worker.activity.forwarding_skipped',
          stage: 'transport',
          severity: 'warning',
          errorCode: 'activity_forwarding_unavailable',
          contextData: {'eventType': activity.eventType},
        ));
        return;
      }
      _pendingActivityEvents.add(_PendingWorkerActivity(
        context: context,
        activity: activity,
        replaceableKey: replaceable ? key : null,
      ));
      return;
    }
    while (_pendingActivityEvents.length >= _maxPendingActivityEvents) {
      if (_transport == null || sessionId == null || _closing) {
        unawaited(recordAssignmentDiagnostic(
          context,
          event: 'worker.activity.forwarding_skipped',
          stage: 'transport',
          severity: 'warning',
          errorCode: 'activity_forwarding_unavailable',
          contextData: {'eventType': activity.eventType},
        ));
        return;
      }
      final waiter = Completer<void>();
      _activitySpaceWaiters.add(waiter);
      await waiter.future;
    }
    _pendingActivityEvents.add(_PendingWorkerActivity(
      context: context,
      activity: activity,
      replaceableKey: replaceable ? key : null,
    ));
    unawaited(_drainActivityEvents());
  }

  Future<void> _drainActivityEvents() async {
    if (_drainingActivityEvents) return;
    _drainingActivityEvents = true;
    try {
      while (_pendingActivityEvents.isNotEmpty &&
          _transport != null &&
          sessionId != null &&
          !_closing) {
        final item = _pendingActivityEvents.removeAt(0);
        _wakeActivitySpaceWaiter();
        final activity = item.activity;
        try {
          await _transport!.sendAndWait(jsonEncode(_assignmentEnvelope(
            'assignment.activity',
            _assignmentCorrelationForContext(item.context),
            {
              'assignmentId': item.context.assignmentId,
              'executionId': activity.executionId,
              'workerId': activity.workerId,
              'eventId': activity.eventId,
              'sequence': activity.sequence,
              'timestamp': activity.timestamp,
              'eventType': activity.eventType,
              'status': activity.status,
              'title': activity.title,
              if (activity.activityId != null)
                'activityId': activity.activityId,
              if (activity.percentage != null)
                'percentage': activity.percentage,
              if (activity.durationMs != null)
                'durationMs': activity.durationMs,
              if (activity.toolId != null) 'toolId': activity.toolId,
              if (activity.toolName != null) 'toolName': activity.toolName,
              if (activity.details != null) 'details': activity.details,
            },
          )));
        } on Object catch (error) {
          unawaited(recordAssignmentDiagnostic(
            item.context,
            event: 'worker.activity.forwarding_failed',
            stage: 'transport',
            severity: 'warning',
            errorCode: 'activity_forwarding_failed',
            contextData: {
              'eventType': activity.eventType,
              'errorType': error.runtimeType.toString(),
            },
          ));
        }
      }
    } finally {
      _drainingActivityEvents = false;
      if (_pendingActivityEvents.isNotEmpty &&
          _transport != null &&
          sessionId != null &&
          !_closing) {
        unawaited(_drainActivityEvents());
      }
    }
  }

  void _wakeActivitySpaceWaiter() {
    if (_activitySpaceWaiters.isEmpty) return;
    final waiter = _activitySpaceWaiters.removeAt(0);
    if (!waiter.isCompleted) waiter.complete();
  }

  void _wakeAllActivitySpaceWaiters() {
    while (_activitySpaceWaiters.isNotEmpty) {
      final waiter = _activitySpaceWaiters.removeAt(0);
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  Map<String, Object?> _assignmentCorrelationForContext(
    WorkspaceAssignmentContext context,
  ) =>
      {
        'executionWorkspaceId': context.workspaceId,
        'workspaceRuntimeId': context.workspaceRuntimeId,
        'workerId': context.workerId,
        'runId': context.runId,
        'taskId': context.taskId,
        'attemptId': context.attemptId,
        'assignmentId': context.assignmentId,
        'idempotencyKey': context.idempotencyKey,
      };

  void _sendIfConnected(String type, Map<String, Object?> payload) {
    final socket = _transport;
    if (socket == null || sessionId == null) return;
    socket.send(jsonEncode(_envelope(type, payload)));
  }

  static const protocol = workspaceRuntimeProtocolName;
  static const protocolVersion = workspaceRuntimeProtocolVersion;

  static bool _isCompatibleProtocolVersion(String remote) {
    final localParts = protocolVersion.split('.').map(int.parse).toList();
    final remoteParts = remote.split('.').map(int.tryParse).toList();
    if (remoteParts.length < 2 || remoteParts.any((part) => part == null)) {
      return false;
    }
    return remoteParts[0] == localParts[0] && remoteParts[1]! >= localParts[1];
  }

  static Map<String, Object?> _defaultCapabilities() {
    final operatingSystem = switch (Platform.operatingSystem) {
      'macos' => 'macos',
      'linux' => 'linux',
      'windows' => 'windows',
      _ => 'linux',
    };
    return {
      'os': operatingSystem,
      'arch': _architecture(),
      'workspaceVersion': syntilaWorkspaceAppVersion,
      'supportedRuntimes': <String>['dart'],
      'customCapabilities': <String>[
        startPermitCapability,
        serviceReadinessCapability,
      ],
      'maxConcurrentWorkers': 1,
    };
  }

  static String _architecture() {
    final hint =
        '${Platform.environment['PROCESSOR_ARCHITECTURE'] ?? ''} ${Platform.environment['HOSTTYPE'] ?? ''} ${Platform.version}'
            .toLowerCase();
    return hint.contains('arm64') || hint.contains('aarch64') ? 'arm64' : 'x64';
  }

  Future<void> connect() async {
    _closing = false;
    lastConnectionAttemptAt = DateTime.now().toUtc();
    connectionStage = WorkspaceConnectionStage.validating;
    try {
      validateConfiguration();
    } on Object catch (error) {
      lastConnectionError = error.toString();
      connectionStage = WorkspaceConnectionStage.offline;
      rethrow;
    }
    try {
      await _open();
    } on Object catch (error) {
      _scheduleReconnect(error);
      rethrow;
    }
  }

  /// Fully tears down any existing timers, subscriptions, and socket objects
  /// with a timeout guarantee so reconnects can never hang on dead resources.
  /// Commands that arrived while this Service was still synchronizing must not
  /// wait silently for a Cloud deadline when the connection ends first. Each
  /// gets an explicit, retryable rejection (best effort: the transport may
  /// already be gone, in which case Cloud's session loss reports it).
  void _rejectPendingAssignmentsDuringSync(String reason) {
    if (_pendingAssignmentsDuringSync.isEmpty) return;
    final pending = List<Map<String, dynamic>>.from(
      _pendingAssignmentsDuringSync,
    );
    _pendingAssignmentsDuringSync.clear();
    final socket = _transport;
    if (socket == null || sessionId == null) return;
    for (final message in pending) {
      if (!_hasAssignmentCorrelation(message)) continue;
      try {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.ack',
          _assignmentCorrelation(message),
          {'accepted': false, 'reason': reason},
        )));
      } on Object {
        // Best effort only.
      }
    }
  }

  /// A command buffered during synchronization is dropped when the Cloud
  /// state in the sync result shows it is no longer startable (finished, or
  /// being revoked). Starting it would only be cancelled again.
  bool _cloudSupersededPendingAssignment(Map<String, dynamic> message) {
    final assignmentId = message['assignmentId'];
    final states = syncResponse?['assignmentStates'];
    if (assignmentId is! String || states is! List) return false;
    for (final entry in states) {
      if (entry is Map && entry['assignmentId'] == assignmentId) {
        return const {
          'completed',
          'failed',
          'cancelled',
          'timed_out',
          'lost',
          'revocation_pending',
          'reconciling',
        }.contains(entry['status']);
      }
    }
    return false;
  }

  Future<void> _cleanCurrentTransport() async {
    startPermitClock.reset();
    _clockProbes.clear();
    _rejectPendingAssignmentsDuringSync('service_connection_ended');
    _transportGeneration++;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatTimeoutTimer?.cancel();
    _heartbeatTimeoutTimer = null;
    _protocolHandshakeTimer?.cancel();
    _protocolHandshakeTimer = null;
    _syncTimer?.cancel();
    _syncTimer = null;
    _terminalRedeliveryTimer?.cancel();
    _terminalRedeliveryTimer = null;
    _terminalRedeliveryAttempt = 0;
    _webSocketProbeTimer?.cancel();
    _webSocketProbeTimer = null;
    final sub = _subscription;
    _subscription = null;
    if (sub != null) {
      await sub.cancel().catchError((_) {});
    }
    final transport = _transport;
    _transport = null;
    activeTransportMode = null;
    _pendingTransportMode = null;
    sessionId = null;
    _wakeAllActivitySpaceWaiters();
    if (transport != null) {
      try {
        await transport.close().timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            // Transport closure timed out; proceed with teardown.
          },
        );
      } catch (_) {
        // Ignore errors on transport close
      }
    }
  }

  /// Requests an immediate transport retry without recreating local Workers
  /// or interrupting their assignment processes.
  Future<void> retryNow() async {
    if (_closing) _closing = false;
    _reconnectAttempt = 0;
    final wakeup = _reconnectWakeup;
    if (_reconnecting) {
      if (wakeup != null && !wakeup.isCompleted) wakeup.complete();
      return;
    }
    await _cleanCurrentTransport();
    try {
      await _open();
    } on Object catch (error) {
      _scheduleReconnect(error);
      rethrow;
    }
  }

  void _scheduleReconnect(Object error) {
    if (_closing || _reconnecting || _isTerminalWebSocketFailure(error)) return;
    unawaited(_reconnect());
  }

  Future<void> _open({WorkspaceTransport? preparedWebSocket}) async {
    await _cleanCurrentTransport();
    if (_closing && preparedWebSocket != null) {
      await preparedWebSocket.close();
      return;
    }
    lastConnectionAttemptAt = DateTime.now().toUtc();
    connectionStage = WorkspaceConnectionStage.connecting;
    lastHelloSentAt = null;
    _helloMessageId = null;
    _syncRequestMessageId = null;
    activeTransportMode = null;
    _pendingTransportMode = null;
    _workerInventorySent = workerInventoryProvider == null;
    _syncResultReceived = false;
    _syncReconciliationComplete = false;
    _syncRequested = false;
    _helloAcknowledged = false;
    _cloudAcceptsReadiness = false;
    _cloudAcceptsStartup = false;
    _cloudAcceptsAllowedFolders = false;
    _cloudAcceptsPluginExecutors = false;
    _readyCallbackSessionId = null;
    late final WorkspaceTransport socket;
    var selectedWebSocket = false;
    try {
      final fallback = fallbackFactory;
      final gatewayPath = uri.path.indexOf('/api/workspace-gateway');
      final basePath =
          gatewayPath < 0 ? '' : uri.path.substring(0, gatewayPath);
      final httpUri = uri.replace(
        scheme: uri.scheme == 'wss' ? 'https' : 'http',
        path: basePath,
        query: null,
        fragment: null,
      );
      if (preparedWebSocket != null) {
        socket = preparedWebSocket;
        selectedWebSocket = true;
      } else if (_preferFallbackTransport && fallback != null) {
        try {
          socket = await fallback(httpUri).timeout(
            protocolHandshakeTimeout,
            onTimeout: () => throw const SocketException(
              'HTTP fallback connection timed out',
            ),
          );
        } on Object {
          socket = await factory(uri).timeout(
            protocolHandshakeTimeout,
            onTimeout: () => throw const SocketException(
              'WebSocket connection timed out',
            ),
          );
          selectedWebSocket = true;
        }
      } else {
        Object? lastWebSocketError;
        var connected = false;
        final attempts =
            fallback == null ? 1 : webSocketFailureLimit.clamp(1, 5);
        for (var attempt = 0; attempt < attempts; attempt++) {
          try {
            socket = await factory(uri).timeout(
              protocolHandshakeTimeout,
              onTimeout: () => throw const SocketException(
                'WebSocket connection timed out',
              ),
            );
            selectedWebSocket = true;
            connected = true;
            break;
          } on Object catch (error) {
            lastWebSocketError = error;
            _recordWebSocketFailure(error);
            if (_isTerminalWebSocketFailure(error) || attempt + 1 >= attempts) {
              break;
            }
            final delay = Duration(
              microseconds: (reconnectBaseDelay.inMicroseconds * (attempt + 1))
                  .clamp(0, reconnectMaxDelay.inMicroseconds),
            );
            if (delay > Duration.zero) await Future<void>.delayed(delay);
          }
        }
        if (!connected) {
          if (fallback == null ||
              _isTerminalWebSocketFailure(lastWebSocketError)) {
            throw lastWebSocketError ??
                StateError('WebSocket connection failed');
          }
          socket = await fallback(httpUri).timeout(
            protocolHandshakeTimeout,
            onTimeout: () => throw const SocketException(
              'HTTP fallback connection timed out',
            ),
          );
          selectedWebSocket = false;
        }
      }
    } on Object catch (error) {
      lastConnectionError = _describeConnectionError(error);
      if (!selectedWebSocket && fallbackFactory != null) {
        fallbackHealthStatus = 'unavailable';
      }
      if (error is WebSocketException) {
        lastHttpStatusCode = error.httpStatusCode;
        if (selectedWebSocket) _recordWebSocketFailure(error);
        lastDnsTlsStatus =
            error.httpStatusCode == null ? 'not confirmed' : 'passed';
      } else {
        lastDnsTlsStatus = 'not confirmed (${error.runtimeType})';
      }
      connectionStage = _closing || !_reconnecting
          ? WorkspaceConnectionStage.offline
          : WorkspaceConnectionStage.reconnecting;
      rethrow;
    }
    _transport = socket;
    lastHttpStatusCode = null;
    _pendingTransportMode = selectedWebSocket ? 'websocket' : 'http_long_poll';
    activeTransportMode =
        _probingWebSocket && _pendingTransportMode == 'websocket'
            ? 'switching_to_websocket'
            : _pendingTransportMode;
    if (_pendingTransportMode == 'http_long_poll') {
      fallbackHealthStatus = 'connecting';
    } else if (fallbackFactory != null) {
      fallbackHealthStatus = 'standby';
    }
    if (selectedWebSocket) {
      _preferFallbackTransport = false;
      lastWebSocketUpgradeAt = DateTime.now().toUtc();
    } else {
      _preferFallbackTransport = true;
    }
    lastDnsTlsStatus = 'passed';
    sessionId = null;
    _reconnectAttempt = 0;
    connectionStage = WorkspaceConnectionStage.authenticating;
    await _subscription?.cancel();
    _subscription = socket.messages.listen(
      _handleMessage,
      onDone: _handleTransportEnd,
      onError: (_) => _handleTransportEnd(),
    );
    final hello = _envelope('workspace.hello', {
      'workspaceRuntimeId': workspaceRuntimeId,
      'executionWorkspaceId': workspaceId,
      'name': name,
      'hostname': hostname,
      'workspaceVersion': workspaceVersion,
      'capabilities': capabilities,
    });
    _helloMessageId = hello['messageId'] as String;
    _rememberClockProbe(_helloMessageId!);
    socket.send(jsonEncode(hello));
    lastHelloSentAt = DateTime.now().toUtc();
    _protocolHandshakeTimer?.cancel();
    _protocolHandshakeTimer = Timer(protocolHandshakeTimeout, () {
      if (sessionId != null || _closing) return;
      if (_pendingTransportMode == 'websocket' && fallbackFactory != null) {
        _preferFallbackTransport = true;
      }
      lastConnectionError =
          'Runtime transport connected, but Cloud did not acknowledge workspace.hello '
          'within ${protocolHandshakeTimeout.inSeconds} seconds.';
      if (_pendingTransportMode == 'websocket') {
        lastWebSocketFailure = lastConnectionError;
        lastWebSocketFailureAt = DateTime.now().toUtc();
      }
      connectionStage = WorkspaceConnectionStage.reconnecting;
      _handleTransportEnd();
    });
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeat, (_) {
      final currentSessionId = sessionId;
      if (currentSessionId == null) return;
      _heartbeatTimeoutTimer ??= Timer(heartbeat * 2, () {
        _heartbeatTimeoutTimer = null;
        lastConnectionError = 'Cloud heartbeat acknowledgement timed out.';
        if (_pendingTransportMode == 'websocket') {
          lastWebSocketFailure = lastConnectionError;
          lastWebSocketFailureAt = DateTime.now().toUtc();
        }
        connectionStage = WorkspaceConnectionStage.reconnecting;
        _handleTransportEnd();
      });
      final heartbeatMessage = _envelope('workspace.heartbeat', {
        'workspaceRuntimeId': workspaceRuntimeId,
        'executionWorkspaceId': workspaceId,
        'sessionId': currentSessionId,
        'status': 'online',
        'activeWorkers': activeWorkerIds.length,
        'activeAssignments': _activeAssignments.length,
        'readiness': _readinessPayload(),
        ..._livenessPayload(),
      });
      unawaited(_refreshPendingTerminalIds());
      _rememberClockProbe(heartbeatMessage['messageId'] as String);
      socket.send(jsonEncode(heartbeatMessage));
      _heartbeatCount++;
      if (_heartbeatCount >= 4) {
        _heartbeatCount = 0;
        unawaited(_reportCurrentWorkerInventory());
      }
    });
  }

  /// Assignments with a recorded outcome that Cloud has not acknowledged.
  /// Refreshed after each heartbeat, so it is at most one interval old.
  Set<String> _pendingTerminalIds = const {};

  Future<void> _refreshPendingTerminalIds() async {
    final journal = assignmentJournal;
    if (journal == null) return;
    try {
      _pendingTerminalIds = {
        for (final record in (await journal.reconcile()).values)
          if (const {
            AssignmentStatus.completed,
            AssignmentStatus.failed,
            AssignmentStatus.cancelled,
            AssignmentStatus.interrupted,
          }.contains(record.status))
            record.assignmentId,
      };
    } on Object {
      // Keep the previous answer; liveness is best effort.
    }
  }

  /// Which assignments still have an Engine process, so Cloud can fail a
  /// running assignment whose process vanished without an outcome. Omitted
  /// when the Service cannot probe processes.
  Map<String, Object?> _livenessPayload() {
    final provider = deadAssignmentIdsProvider;
    if (provider == null) return const {};
    final dead = provider();
    return {
      'liveAssignmentIds': [
        for (final id in _activeAssignments)
          if (!dead.contains(id)) id,
      ],
      'pendingTerminalAssignmentIds': _pendingTerminalIds.toList(),
    };
  }

  Map<String, Object?> _envelope(String type, Map<String, Object?> payload) => {
        'protocol': protocol,
        'protocolVersion': protocolVersion,
        'messageId':
            'dart-${DateTime.now().microsecondsSinceEpoch}-${++_messageSequence}',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': type,
        'payload': payload,
      };

  void _handleMessage(Object? raw) {
    if (raw is! String) return;
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final remoteProtocolVersion = decoded['protocolVersion'];
    if (remoteProtocolVersion is! String ||
        !_isCompatibleProtocolVersion(remoteProtocolVersion)) {
      return;
    }
    try {
      WorkspaceRuntimeMessage.parse(decoded);
    } on ProtocolException {
      return;
    }
    _recordClockSample(decoded);
    if (decoded['type'] == 'workspace.hello.ack') {
      final payload = decoded['payload'];
      final runtimeId = decoded['workspaceRuntimeId'];
      final executionWorkspaceId = decoded['executionWorkspaceId'];
      if (runtimeId != workspaceRuntimeId ||
          executionWorkspaceId != workspaceId ||
          decoded['correlationId'] != _helloMessageId) {
        lastConnectionError =
            'Cloud hello acknowledgement did not match this Workspace runtime.';
        if (_pendingTransportMode == 'websocket') {
          lastWebSocketFailure = lastConnectionError;
          lastWebSocketFailureAt = DateTime.now().toUtc();
        }
        connectionStage = WorkspaceConnectionStage.reconnecting;
        _handleTransportEnd();
        return;
      }
      if (payload is Map<String, dynamic> &&
          payload['sessionId'] is String &&
          (payload['sessionId'] as String).isNotEmpty) {
        _protocolHandshakeTimer?.cancel();
        _protocolHandshakeTimer = null;
        lastHelloAcknowledgedAt = DateTime.now().toUtc();
        _helloAcknowledged = true;
        final cloudCapabilities = payload['cloudCapabilities'];
        _cloudAcceptsReadiness = cloudCapabilities is List &&
            cloudCapabilities.contains(serviceReadinessCapability);
        _cloudAcceptsStartup = cloudCapabilities is List &&
            cloudCapabilities.contains(assignmentStartupCapability);
        _cloudAcceptsAllowedFolders = cloudCapabilities is List &&
            cloudCapabilities.contains(allowedFoldersCapability);
        _cloudAcceptsPluginExecutors = cloudCapabilities is List &&
            cloudCapabilities.contains(pluginExecutorsCapability);
        connectionStage = WorkspaceConnectionStage.synchronizing;
        sessionId = payload['sessionId'] as String;
        unawaited(_drainActivityEvents());
        _syncTimer?.cancel();
        _syncTimer = Timer(syncTimeout, () {
          if ((_syncResultReceived &&
                  _syncReconciliationComplete &&
                  _workerInventorySent) ||
              _closing) {
            return;
          }
          lastConnectionError = !_syncResultReceived
              ? 'Workspace authenticated, but Cloud synchronization did '
                  'not complete within ${syncTimeout.inSeconds} seconds.'
              : !_syncReconciliationComplete
                  ? 'Workspace synchronization completed, but assignment '
                      'reconciliation did not finish within '
                      '${syncTimeout.inSeconds} seconds.'
                  : 'Cloud synchronization completed, but the Worker inventory '
                      'did not finish within ${syncTimeout.inSeconds} seconds.';
          if (_pendingTransportMode == 'websocket') {
            lastWebSocketFailure = lastConnectionError;
            lastWebSocketFailureAt = DateTime.now().toUtc();
          }
          connectionStage = WorkspaceConnectionStage.reconnecting;
          _handleTransportEnd();
        });
        authorizedWorkspaceIds
          ..clear()
          ..add(workspaceId);
        unawaited(_sendSyncRequest());
        unawaited(_reportCurrentWorkerInventory());
      }
    } else if (decoded['type'] == 'workspace.sync.result') {
      if (decoded['workspaceRuntimeId'] != workspaceRuntimeId ||
          decoded['executionWorkspaceId'] != workspaceId ||
          decoded['correlationId'] != _syncRequestMessageId) {
        lastConnectionError =
            'Cloud synchronization response did not match this runtime session.';
        if (_pendingTransportMode == 'websocket') {
          lastWebSocketFailure = lastConnectionError;
          lastWebSocketFailureAt = DateTime.now().toUtc();
        }
        connectionStage = WorkspaceConnectionStage.reconnecting;
        _handleTransportEnd();
        return;
      }
      final payload = decoded['payload'];
      if (payload is Map<String, dynamic>) {
        syncResponse = Map<String, Object?>.from(payload);
        _syncResultReceived = true;
        unawaited(_finishSyncReconciliation(syncResponse!));
      }
    } else if (decoded['type'] == 'workspace.update') {
      final payload = decoded['payload'];
      final handler = workspaceUpdateAvailableHandler;
      if (payload is Map<String, dynamic> && handler != null) {
        unawaited(
          handler(Map<String, Object?>.from(payload)).catchError((_) {}),
        );
      }
    } else if (decoded['type'] == 'workspace.heartbeat.ack') {
      _heartbeatTimeoutTimer?.cancel();
      _heartbeatTimeoutTimer = null;
    } else if (decoded['type'] == 'thread.status') {
      // Runtime readiness is currently informational. The payload is not
      // persisted here and contains no local path.
    } else if (decoded['type'] == 'assignment.ack') {
      final payload = decoded['payload'];
      if (payload is Map<String, dynamic> && payload['terminal'] == true) {
        unawaited(_handleTerminalAcknowledgement(decoded, payload));
      }
    } else if (decoded['type'] == 'assignment.start') {
      _traceAssignmentReceived(decoded);
      if (connectionStage != WorkspaceConnectionStage.ready) {
        final assignmentId = decoded['assignmentId'];
        if (assignmentId is! String ||
            !_pendingAssignmentsDuringSync.any(
              (item) => item['assignmentId'] == assignmentId,
            )) {
          if (_pendingAssignmentsDuringSync.length >= 256) {
            final socket = _transport;
            if (socket != null) {
              unawaited(_sendAssignmentError(
                socket,
                decoded,
                'provider_unavailable',
                retryable: true,
                diagnostic: jsonEncode({
                  'schemaVersion': 1,
                  'component': 'workspace_service',
                  'stage': 'assignment_sync_queue',
                  'errorCode': 'provider_unavailable',
                  'detail':
                      'Assignment queue is full while synchronization is pending',
                }),
              ));
            }
          } else {
            _pendingAssignmentsDuringSync.add(decoded);
          }
        }
      } else {
        unawaited(_handleAssignmentStart(decoded));
      }
    } else if (decoded['type'] == 'assignment.start.permit.grant') {
      _handleStartPermitGrant(decoded);
    } else if (decoded['type'] == 'assignment.cancel') {
      unawaited(_handleAssignmentCancel(decoded));
    } else if (decoded['type'] == 'diagnostic.probe') {
      _handleDeliveryProbe(decoded);
    } else if (decoded['type'] == 'worker.usage.request') {
      unawaited(_handleWorkerUsageRequest(decoded));
    } else if (decoded['type'] == 'input.available') {
      inputAvailableHandler?.call();
    }
  }

  /// Answers a Cloud usage request by running the Worker Profile's usage
  /// command through the Engine. Failures are reported as a bounded result so
  /// the requester never waits for the timeout.
  Future<void> _handleWorkerUsageRequest(Map<String, dynamic> decoded) async {
    final payload = decoded['payload'];
    if (payload is! Map) return;
    final requestId = payload['requestId'];
    final workerId = payload['workerId'];
    if (requestId is! String ||
        requestId.isEmpty ||
        requestId.length > 128 ||
        workerId is! String ||
        workerId.isEmpty ||
        workerId.length > 128) {
      return;
    }
    Map<String, Object?> result;
    final provider = workerUsageProvider;
    if (provider == null) {
      result = {
        'status': 'unavailable',
        'errorCode': 'usage_not_supported',
        'errorMessage': 'This Workspace cannot read Worker usage.',
      };
    } else {
      try {
        result = await provider(workerId);
      } on Object {
        result = {
          'status': 'error',
          'errorCode': 'provider_failure',
          'errorMessage': 'The usage command could not be run.',
        };
      }
    }
    final socket = _transport;
    if (socket == null || sessionId == null) return;
    try {
      socket.send(jsonEncode({
        ..._envelope('worker.usage.result', {
          'requestId': requestId,
          ...result,
        }),
        'correlationId': decoded['messageId'],
      }));
    } on Object {
      // The requester times out; never disturb the connection for this.
    }
  }

  /// Acknowledges a Cloud delivery probe immediately from the message loop.
  /// The probe involves no assignment, Worker or Engine process, so its round
  /// trip isolates transport and Service message-handling latency.
  void _handleDeliveryProbe(Map<String, dynamic> decoded) {
    try {
      final receivedAt = DateTime.now().toUtc();
      final socket = _transport;
      final payload = decoded['payload'];
      if (socket == null || sessionId == null || payload is! Map) return;
      final probeId = payload['probeId'];
      if (probeId is! String || probeId.isEmpty || probeId.length > 128) {
        return;
      }
      final context = _traceContext();
      socket.send(jsonEncode({
        ..._envelope('diagnostic.probe.ack', {
          'probeId': probeId,
          'receivedAt': receivedAt.toIso8601String(),
          'ackedAt': DateTime.now().toUtc().toIso8601String(),
          for (final key in const [
            'traceEpochId',
            'transport',
            'syncState',
            'localQueueLength',
            'activeAssignments',
            'clockOffsetMs',
            'clockRttMs',
          ])
            if (context[key] != null) key: context[key],
        }),
        'correlationId': decoded['messageId'],
      }));
    } on Object {
      // A probe is diagnostic only; never disturb the connection for it.
    }
  }

  void _completeSynchronizationWhenReady() {
    if (!_syncResultReceived ||
        !_syncReconciliationComplete ||
        !_workerInventorySent ||
        sessionId == null) {
      return;
    }
    _syncTimer?.cancel();
    _syncTimer = null;
    final becameReady = connectionStage != WorkspaceConnectionStage.ready;
    if (becameReady) _syncGeneration += 1;
    connectionStage = WorkspaceConnectionStage.ready;
    activeTransportMode = _pendingTransportMode ?? activeTransportMode;
    _pendingTransportMode = null;
    fallbackHealthStatus = activeTransportMode == 'http_long_poll'
        ? 'healthy'
        : fallbackFactory == null
            ? 'not configured'
            : 'standby';
    if (activeTransportMode == 'websocket') _webSocketProbeFailures = 0;
    lastReadyAt = DateTime.now().toUtc();
    lastConnectionError = null;
    lastHttpStatusCode = null;
    final readyCallback = onSessionReady;
    final readySessionId = sessionId;
    if (readyCallback != null &&
        readySessionId != null &&
        readySessionId != _readyCallbackSessionId) {
      _readyCallbackSessionId = readySessionId;
      unawaited(readyCallback().catchError((_) {}));
    }
    if (_pendingAssignmentsDuringSync.isNotEmpty) {
      final pending = List<Map<String, dynamic>>.from(
        _pendingAssignmentsDuringSync,
      );
      _pendingAssignmentsDuringSync.clear();
      for (final message in pending) {
        if (_cloudSupersededPendingAssignment(message)) continue;
        unawaited(_handleAssignmentStart(message));
      }
    }
    // Publish after the buffered commands are admitted: from here on a new
    // command is handled immediately.
    if (becameReady) _publishReadiness(reason: 'sync_complete');
    _scheduleWebSocketProbe();
  }

  Future<void> _finishSyncReconciliation(Map<String, Object?> payload) async {
    try {
      await _reconcileSyncResponse(payload);
      _syncReconciliationComplete = true;
      _completeSynchronizationWhenReady();
    } on Object catch (error) {
      lastConnectionError =
          'Workspace sync reconciliation failed (${error.runtimeType}).';
      connectionStage = WorkspaceConnectionStage.reconnecting;
      _handleTransportEnd();
    }
  }

  Future<void> _handleTerminalAcknowledgement(
    Map<String, dynamic> message,
    Map<String, dynamic> payload,
  ) async {
    final assignmentId = message['assignmentId'];
    if (assignmentId is! String ||
        message['executionWorkspaceId'] != workspaceId ||
        message['workspaceRuntimeId'] != workspaceRuntimeId) {
      return;
    }
    final journal = assignmentJournal;
    if (journal == null) return;
    final record = await journal.find(assignmentId);
    if (record == null || record.status == AssignmentStatus.reconciled) {
      return;
    }
    final acknowledgedStatus = payload['status'];
    final expectedStatus = switch (record.status) {
      AssignmentStatus.completed => 'completed',
      AssignmentStatus.failed => 'failed',
      AssignmentStatus.cancelled => 'cancelled',
      AssignmentStatus.interrupted => 'failed',
      _ => null,
    };
    if (expectedStatus == null || acknowledgedStatus != expectedStatus) {
      return;
    }
    await _recordAssignment(
      assignmentId,
      AssignmentStatus.reconciled,
      correlation: _assignmentCorrelation(message),
      result: record.result,
    );
  }

  void _scheduleWebSocketProbe() {
    _webSocketProbeTimer?.cancel();
    if (_closing ||
        fallbackFactory == null ||
        activeTransportMode != 'http_long_poll' ||
        connectionStage != WorkspaceConnectionStage.ready ||
        webSocketProbeInterval <= Duration.zero) {
      return;
    }
    _webSocketProbeTimer = Timer(nextWebSocketProbeDelay, () {
      unawaited(_probeWebSocket());
    });
  }

  Duration get nextWebSocketProbeDelay => Duration(
        microseconds: (webSocketProbeInterval.inMicroseconds *
                (1 << _webSocketProbeFailures.clamp(0, 8)))
            .clamp(0, webSocketProbeMaxInterval.inMicroseconds),
      );

  /// Wake/network recovery should not wait for a backed-off periodic retry.
  Future<void> retryWebSocketNow() async {
    if (_closing) return;
    _webSocketProbeFailures = 0;
    _webSocketProbeTimer?.cancel();
    await _probeWebSocket();
  }

  Future<void> _probeWebSocket() async {
    if (_closing ||
        _probingWebSocket ||
        activeTransportMode != 'http_long_poll' ||
        connectionStage != WorkspaceConnectionStage.ready) {
      return;
    }
    _probingWebSocket = true;
    _webSocketProbeTimer?.cancel();
    final generation = _transportGeneration;
    var expired = false;
    var handedOver = false;
    try {
      // Each factory call creates fresh WSS resources. Keep HTTPS alive until
      // Cloud accepts the upgrade; its single-session fence then requires handover.
      final pending = factory(uri);
      unawaited(pending.then<void>((candidate) async {
        if (expired || _closing || generation != _transportGeneration) {
          await candidate.close();
        }
      }, onError: (Object _) {}).catchError((Object _) {}));
      final candidate = await pending.timeout(protocolHandshakeTimeout);
      if (_closing || generation != _transportGeneration) return;
      connectionStage = WorkspaceConnectionStage.switchingToWebSocket;
      handedOver = true;
      await _open(preparedWebSocket: candidate);
    } on Object catch (error) {
      expired = true;
      if (!_closing && generation == _transportGeneration) {
        _recordWebSocketFailure(error);
        _webSocketProbeFailures++;
      } else if (!_closing && handedOver) {
        _preferFallbackTransport = true;
        unawaited(_reconnect());
      }
    } finally {
      _probingWebSocket = false;
      if (!_closing && connectionStage == WorkspaceConnectionStage.ready) {
        _scheduleWebSocketProbe();
      }
    }
  }

  String _describeConnectionError(Object error) {
    if (error is WebSocketException && error.httpStatusCode != null) {
      return 'Cloud rejected the WebSocket upgrade with HTTP '
          '${error.httpStatusCode}.';
    }
    if (error is WebSocketException) {
      return 'WebSocket upgrade failed.';
    }
    if (error is TimeoutException) {
      return 'Connection timed out (${error.message ?? 'timeout'}).';
    }
    if (error is SocketException) {
      return 'Socket connection failed (${error.message}).';
    }
    return 'WebSocket connection failed (${error.runtimeType}).';
  }

  void _recordWebSocketFailure(Object error) {
    lastWebSocketFailure = _describeConnectionError(error);
    lastWebSocketHttpStatusCode =
        error is WebSocketException ? error.httpStatusCode : null;
    lastWebSocketFailureAt = DateTime.now().toUtc();
  }

  /// Re-sends the local terminal outcome. Cloud acknowledges it with a
  /// terminal `assignment.ack`, which is what marks the record reconciled.
  Future<void> _sendRecoveredTerminal(
    WorkspaceTransport socket,
    AssignmentRecord record,
    Map<String, Object?> correlation,
  ) async {
    if (record.status == AssignmentStatus.completed) {
      await socket.sendAndWait(jsonEncode(_assignmentEnvelope(
        'assignment.result',
        correlation,
        {
          'status': 'completed',
          'summary': record.result?['summary'] ?? 'Recovered assignment result',
          'output': record.result?['output'],
          'artifactIds': record.result?['artifactIds'] ?? const [],
          if (record.result?['evidence'] is Map)
            'evidence': record.result?['evidence'],
        },
      )));
    } else if (record.status == AssignmentStatus.failed) {
      await socket.sendAndWait(jsonEncode(_assignmentEnvelope(
        'assignment.error',
        correlation,
        {
          'status': 'failed',
          'error': {
            'code': record.errorCode ?? 'provider_unavailable',
            'message':
                record.result?['error'] ?? 'Recovered assignment failure',
            'retryable': false,
            if (record.processExitCode != null)
              'details': {'processExitCode': record.processExitCode},
          },
        },
      )));
    } else if (record.status == AssignmentStatus.cancelled) {
      await socket.sendAndWait(jsonEncode(_assignmentEnvelope(
        'assignment.cancelled',
        correlation,
        {
          'status': 'cancelled',
          'reason': 'Assignment was cancelled while the Workspace was offline',
        },
      )));
    } else {
      await socket.sendAndWait(jsonEncode(_assignmentEnvelope(
        'assignment.error',
        correlation,
        {
          'status': 'failed',
          'error': {
            'code': 'provider_unavailable',
            'message': executionErrorMessage('provider_unavailable'),
            'retryable': true,
            'details': {
              'recoveryState':
                  record.result?['recoveryState'] ?? 'workspace_restart',
            },
          },
        },
      )));
    }
  }

  void _scheduleTerminalRedelivery() {
    if (_closing || _terminalRedeliveryTimer != null) return;
    final factor =
        1 << (_terminalRedeliveryAttempt > 4 ? 4 : _terminalRedeliveryAttempt);
    _terminalRedeliveryAttempt++;
    _terminalRedeliveryTimer = Timer(terminalRedeliveryInterval * factor, () {
      _terminalRedeliveryTimer = null;
      unawaited(_redeliverPendingTerminals());
    });
  }

  /// A terminal send can fail while the transport stays up (timeout, Cloud
  /// restarting). Sync only runs on connect, so retry on a timer until Cloud
  /// acknowledges every locally recorded outcome. A reconnect cancels this
  /// timer and the connect-time sync takes over.
  Future<void> _redeliverPendingTerminals() async {
    final journal = assignmentJournal;
    final socket = _transport;
    if (_closing || journal == null) return;
    if (socket == null ||
        sessionId == null ||
        connectionStage != WorkspaceConnectionStage.ready) {
      // Mid-reconnect: keep the timer alive so an outcome recorded while the
      // connection was down is still delivered once the session is ready.
      _scheduleTerminalRedelivery();
      return;
    }
    final generation = _transportGeneration;
    var pending = false;
    for (final record in (await journal.reconcile()).values) {
      if (!const {
            AssignmentStatus.completed,
            AssignmentStatus.failed,
            AssignmentStatus.cancelled,
            AssignmentStatus.interrupted,
          }.contains(record.status) ||
          _activeAssignments.contains(record.assignmentId)) {
        continue;
      }
      final correlation = _recordCorrelation(record);
      if (correlation.values.any((value) => value is! String)) continue;
      pending = true;
      try {
        await _sendRecoveredTerminal(socket, record, correlation)
            .timeout(const Duration(seconds: 10));
      } on Object {
        // The next tick retries; the journal stays authoritative.
      }
      if (_closing || generation != _transportGeneration) return;
    }
    if (pending) {
      _scheduleTerminalRedelivery();
    } else {
      _terminalRedeliveryAttempt = 0;
    }
  }

  Future<void> _reconcileSyncResponse(Map<String, Object?> payload) async {
    final knownSpaces = payload['knownSpaceIds'];
    final onKnownSpaces = this.onKnownSpaces;
    if (knownSpaces is List && onKnownSpaces != null) {
      try {
        await onKnownSpaces(knownSpaces.whereType<String>().toSet());
      } on Object {
        // Housekeeping only; it must never block synchronization.
      }
    }
    final rawStates = payload['assignmentStates'];
    final journal = assignmentJournal;
    if (journal == null || rawStates is! List) return;
    final states = <String, Map<String, Object?>>{};
    for (final raw in rawStates.whereType<Map>()) {
      final state = Map<String, Object?>.from(raw);
      final assignmentId = state['assignmentId'];
      if (assignmentId is String) states[assignmentId] = state;
    }
    final records = await journal.reconcile();
    for (final record in records.values) {
      final state = states[record.assignmentId];
      if (state == null) continue;
      final cloudStatus = state['status'];
      if (cloudStatus is! String) continue;
      if (const {'completed', 'failed', 'cancelled', 'timed_out'}
          .contains(cloudStatus)) {
        if (record.status != AssignmentStatus.reconciled) {
          await _recordAssignment(
              record.assignmentId, AssignmentStatus.reconciled,
              correlation: _recordCorrelation(record), result: record.result);
        }
        continue;
      }
      if (_activeAssignments.contains(record.assignmentId)) {
        final liveCorrelation = _recordCorrelation(record);
        if (liveCorrelation.values.every((value) => value is String)) {
          _reassertLiveAssignment(
            liveCorrelation,
            record.status,
            cloudStatus: cloudStatus,
          );
        }
        continue;
      }
      if (!const {
        AssignmentStatus.completed,
        AssignmentStatus.failed,
        AssignmentStatus.cancelled,
        AssignmentStatus.interrupted,
      }.contains(record.status)) {
        continue;
      }
      final correlation = _recordCorrelation(record);
      if (correlation.values.any((value) => value is! String)) continue;
      final socket = _transport;
      if (socket == null || sessionId == null) continue;
      await _sendRecoveredTerminal(socket, record, correlation);
      // Keep terminal evidence pending until Cloud acknowledges it. This is
      // what makes delivery independently retryable across transport loss.
    }
  }

  /// Idempotently re-sends admission and provider-start evidence for an
  /// assignment that is still live in this process. Cloud may have missed the
  /// originals (socket dropped, HTTP fallback replay), and without them it
  /// would keep the assignment Dispatched/Acknowledged until a startup
  /// deadline fails work the Service is actually running. Cloud treats the
  /// messages as no-ops when it already holds the evidence, so re-sending is
  /// always safe; it never downgrades a newer Cloud state.
  void _reassertLiveAssignment(
    Map<String, Object?> correlation,
    AssignmentStatus localStatus, {
    String? cloudStatus,
  }) {
    final socket = _transport;
    if (socket == null || sessionId == null) return;
    final cloudBehind = cloudStatus == null ||
        const {'created', 'dispatched', 'acknowledged'}.contains(cloudStatus);
    if (!cloudBehind) return;
    final needsAdmission = cloudStatus == null ||
        cloudStatus == 'created' ||
        cloudStatus == 'dispatched';
    if (needsAdmission) {
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.ack',
        correlation,
        {'accepted': true, 'estimatedStartMs': 0},
      )));
    }
    if (localStatus == AssignmentStatus.running) {
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.start.ack',
        correlation,
        {
          'started': true,
          'engineStarted': true,
          'providerStarted': true,
        },
      )));
    }
  }

  Map<String, Object?> _recordCorrelation(AssignmentRecord record) => {
        'executionWorkspaceId': record.workspaceId,
        'workspaceRuntimeId': record.workspaceRuntimeId,
        'workerId': record.workerId,
        'runId': record.runId,
        'taskId': record.taskId,
        'attemptId': record.attemptId,
        'assignmentId': record.assignmentId,
        'idempotencyKey': record.idempotencyKey,
      };

  Map<String, Object?> _assignmentCorrelation(Map<String, dynamic> message) => {
        'executionWorkspaceId': message['executionWorkspaceId'],
        'workspaceRuntimeId': message['workspaceRuntimeId'],
        'workerId': message['workerId'],
        'runId': message['runId'],
        'taskId': message['taskId'],
        'attemptId': message['attemptId'],
        'assignmentId': message['assignmentId'],
        'idempotencyKey': message['idempotencyKey'],
      };

  Map<String, Object?> _assignmentEnvelope(
    String type,
    Map<String, Object?> correlation,
    Map<String, Object?> payload,
  ) =>
      {
        ..._envelope(type, payload),
        ...correlation,
      };

  Future<void> _sendSyncRequest() async {
    final socket = _transport;
    if (socket == null || sessionId == null) return;
    final recoveredAssignmentIds = <String>{...unreconciledAssignmentIds};
    final journal = assignmentJournal;
    if (journal != null) {
      final records = await journal.reconcile();
      for (final record in records.values) {
        // Include terminal local results until Cloud acknowledges them. This
        // closes the crash window after worker success but before the result
        // reaches Cloud.
        if (record.status != AssignmentStatus.reconciled) {
          recoveredAssignmentIds.add(record.assignmentId);
        }
      }
    }
    final request = _envelope('workspace.sync.request', {
      'workspaceRuntimeId': workspaceRuntimeId,
      'executionWorkspaceId': workspaceId,
      if (recoveredAssignmentIds.isNotEmpty)
        'unreconciledAssignmentIds': recoveredAssignmentIds.toList()..sort(),
    });
    _syncRequestMessageId = request['messageId'] as String;
    _syncRequested = true;
    socket.send(jsonEncode(request));
  }

  Future<void> _reconnect() async {
    if (_closing || _reconnecting) return;
    _reconnecting = true;
    sessionId = null;
    connectionStage = WorkspaceConnectionStage.reconnecting;
    await _cleanCurrentTransport();
    try {
      while (!_closing) {
        reconnectCount += 1;
        _notifyStateChanged();
        final multiplier = 1 << _reconnectAttempt.clamp(0, 8);
        final delay = Duration(
          microseconds: (reconnectBaseDelay.inMicroseconds * multiplier)
              .clamp(0, reconnectMaxDelay.inMicroseconds),
        );
        final wakeup = Completer<void>();
        _reconnectWakeup = wakeup;
        await Future.any([Future<void>.delayed(delay), wakeup.future]);
        if (identical(_reconnectWakeup, wakeup)) _reconnectWakeup = null;
        if (_closing) return;
        try {
          await _open();
          return;
        } on Object {
          _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 8);
        }
      }
    } finally {
      _reconnecting = false;
    }
  }

  void _handleTransportEnd() {
    startPermitClock.reset();
    _clockProbes.clear();
    if ((_pendingTransportMode ?? activeTransportMode) == 'websocket' &&
        fallbackFactory != null) {
      if (_pendingTransportMode == 'websocket') _webSocketProbeFailures++;
      _preferFallbackTransport = true;
      fallbackHealthStatus = 'connecting';
    } else if ((_pendingTransportMode ?? activeTransportMode) ==
            'http_long_poll' &&
        fallbackFactory != null) {
      fallbackHealthStatus = 'unavailable';
    }
    final wakeup = _reconnectWakeup;
    if (_reconnecting && wakeup != null && !wakeup.isCompleted) {
      wakeup.complete();
    } else {
      unawaited(_reconnect());
    }
  }

  bool _isTerminalWebSocketFailure(Object? error) {
    if (error is! WebSocketException) return false;
    // These responses indicate auth, ownership, or protocol remediation is
    // needed. Opening HTTP with the same runtime credential cannot fix them.
    return const {400, 401, 403, 409, 422, 426}.contains(error.httpStatusCode);
  }

  Future<void> close() async {
    _closing = true;
    // Tell Cloud first, so it stops routing new work here before the
    // connection goes away.
    _publishReadiness(reason: 'shutdown');
    final wakeup = _reconnectWakeup;
    if (wakeup != null && !wakeup.isCompleted) wakeup.complete();
    final cancelAssignment = assignmentCancellationHandler;
    if (cancelAssignment != null) {
      for (final assignmentId in _activeAssignments.toList(growable: false)) {
        try {
          await cancelAssignment(assignmentId, 'Workspace shutdown');
        } on Object {
          // Workspace shutdown must continue even if a cancellation callback
          // fails; the executor shutdown hook is the final cleanup boundary.
        }
      }
    }
    await _cleanCurrentTransport();
    lastHelloSentAt = null;
    connectionStage = WorkspaceConnectionStage.offline;
  }
}

/// A start permit requested at admission, bound to the exact attempt.
class _PrefetchedStartPermit {
  _PrefetchedStartPermit(this.context, this.expiresAt);

  final WorkspaceAssignmentContext context;
  final Future<DateTime?> expiresAt;

  bool matches(WorkspaceAssignmentContext other) =>
      context.attemptId == other.attemptId &&
      context.workspaceRuntimeId == other.workspaceRuntimeId &&
      context.idempotencyKey == other.idempotencyKey;
}
