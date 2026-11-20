import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'artifact_launcher.dart';
import 'config.dart';
import 'connection.dart';
import 'engine.dart';
import 'faults.dart';
import 'identity.dart';
import 'journal.dart';
import 'lock.dart';
import 'paths.dart';
import 'profile_cache.dart';
import 'readiness.dart';
import 'server_api.dart';
import 'wire.dart';

/// One running Worker Agent: one Worker Instance, one credential, one journal,
/// one connection. It owns the data directory through [AgentLock].
class AgentRuntime {
  AgentRuntime._({
    required this.paths,
    required this.identity,
    required this.keyStore,
    required this.config,
    required this.api,
    required this.lock,
    required this.journal,
    required this.supervisor,
    required EngineLauncher engine,
    required this.readiness,
    required this.profiles,
    required this.permitTimeout,
    required this.permitResend,
    required this.onPoint,
    required SocketConnector? connector,
    required Duration baseDelay,
    required Duration heartbeatInterval,
    required Duration stepTimeout,
    required String clientVersion,
  }) {
    connection = AgentConnection(
      workerId: identity.workerId,
      serverUrl: identity.serverUrl,
      keyStore: keyStore,
      api: api,
      connector: connector,
      clientVersion: clientVersion,
      baseDelay: baseDelay,
      heartbeatInterval: heartbeatInterval,
      stepTimeout: stepTimeout,
      unreconciledIds: () async =>
          journal.unacknowledged.map((e) => e.assignmentId).toList()..sort(),
      onSync: _reconcile,
      onMessage: _onMessage,
      onSession: engine is ArtifactLauncher ? engine.holder.update : null,
      readiness: () async => (await readiness.evaluate()).toJson(),
    );
  }

  final AgentPaths paths;
  final AgentIdentity identity;
  final KeyStore keyStore;
  final AgentConfig config;
  final ServerApi api;
  final AgentLock lock;
  final AgentJournal journal;
  final EngineSupervisor supervisor;
  final ReadinessChecker readiness;
  final ProfileCache? profiles;
  final Duration permitTimeout;
  final Duration permitResend;
  final FaultPoint? onPoint;
  late final AgentConnection connection;

  final Set<String> _admitting = {};
  final Set<String> _executing = {};
  final Set<Future<void>> _inFlight = {};
  final Map<String, Completer<bool>> _permits = {};
  Future<void>? _connectionDone;
  StreamSubscription<ConnectionPhase>? _phaseSubscription;
  bool _stopping = false;
  bool _dead = false;
  static const _maxAdmitted = 64;

  /// Opens the Agent's private state: takes the data-directory lock, replays
  /// the journal (a damaged journal fails closed) and prepares the Engine
  /// supervisor. Nothing connects until [start].
  static Future<AgentRuntime> open({
    required AgentPaths paths,
    required AgentIdentity identity,
    required KeyStore keyStore,
    required EngineLauncher engine,
    ServerApi? api,
    SocketConnector? connector,
    ProfileCache? profiles,
    FaultPoint? onPoint,
    Duration baseDelay = const Duration(seconds: 1),
    Duration heartbeatInterval = const Duration(seconds: 30),
    Duration stepTimeout = const Duration(seconds: 30),
    Duration permitTimeout = const Duration(minutes: 2),
    Duration permitResend = const Duration(seconds: 5),
    String clientVersion = '0.1.0',
  }) async {
    await paths.ensure();
    final lock = await AgentLock.acquire(paths.lockFile);
    try {
      final config = await AgentConfig.load(paths.configFile);
      final journal = AgentJournal(
        paths.journalFile,
        beforeWrite: onPoint == null
            ? null
            : (id, event) => onPoint('before-$event', id),
        afterWrite: onPoint == null
            ? null
            : (id, event) => onPoint('after-$event', id),
      );
      await journal.open();
      final key = await keyStore.load();
      final checks = ReadinessChecker([
        ReadinessCheck(
          'credential',
          () async => key == null ? 'no_credential' : null,
        ),
        ReadinessCheck('engine', engine.probe),
      ]);
      return AgentRuntime._(
        paths: paths,
        identity: identity,
        keyStore: keyStore,
        config: config,
        api: api ?? ServerApi(identity.serverUrl),
        lock: lock,
        journal: journal,
        engine: engine,
        supervisor: EngineSupervisor(
          engine,
          maxConcurrent: config.maxConcurrent,
        ),
        readiness: checks,
        profiles: profiles,
        permitTimeout: permitTimeout,
        permitResend: permitResend,
        onPoint: onPoint,
        connector: connector,
        baseDelay: baseDelay,
        heartbeatInterval: heartbeatInterval,
        stepTimeout: stepTimeout,
        clientVersion: clientVersion,
      );
    } on Object {
      await lock.release();
      rethrow;
    }
  }

  bool get isDead => _dead;

  /// Recovers from the journal, then connects. New work starts only after the
  /// reconnect sequence has reconciled with the server.
  Future<void> start() async {
    await supervisor.launcher.recoverOrphans();
    await _recoverFromJournal();
    _phaseSubscription = connection.phases.listen((phase) {
      unawaited(_writeState());
      if (phase == ConnectionPhase.ready) unawaited(_resumeWork());
    });
    await _writeState();
    _connectionDone = connection.run();
  }

  /// Settles what a previous run left behind. An Engine may already have been
  /// started for `starting` and `running` entries, so those attempts are never
  /// started again: they end as a retryable failure and the server retries on
  /// a new attempt.
  Future<void> _recoverFromJournal() async {
    for (final entry in journal.unacknowledged) {
      switch (entry.status) {
        case LocalStatus.received:
          // Journaled but not acknowledged: admit it now.
          if (entry.command != null) {
            await journal.record(entry.assignmentId, LocalStatus.accepted);
          } else {
            await _settle(
              entry,
              TerminalKind.failed,
              _failure('command_unavailable', retryable: true),
            );
          }
        case LocalStatus.starting:
        case LocalStatus.running:
          await _settle(
            entry,
            TerminalKind.failed,
            _failure('agent_restarted', retryable: true),
          );
        case LocalStatus.accepted:
        case LocalStatus.terminal:
        case LocalStatus.acknowledged:
          break;
      }
    }
  }

  Map<String, Object?> _failure(String code, {required bool retryable}) => {
    'errorCode': code,
    'message': _messages[code] ?? 'The Worker could not finish the assignment',
    'retryable': retryable,
  };

  static const _messages = {
    'agent_restarted': 'The Worker Agent restarted while this was running',
    'agent_stopped': 'The Worker Agent was stopped while this was running',
    'start_not_authorized': 'The server did not authorize starting this work',
    'command_unavailable': 'The command could not be recovered locally',
    'engine_failed': 'The Engine could not run this assignment',
    'unknown_to_server': 'The server no longer knows this assignment',
  };

  /// Called after the server's sync answer, before the connection is ready.
  Future<void> _reconcile(Map<String, Object?> payload) async {
    final states = <String, String>{};
    final raw = payload['assignmentStates'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map &&
            item['assignmentId'] is String &&
            item['status'] is String) {
          states[item['assignmentId'] as String] = item['status'] as String;
        }
      }
    }
    const terminalOnServer = {'completed', 'failed', 'cancelled', 'timed_out'};
    for (final entry in journal.unacknowledged) {
      final server = states[entry.assignmentId];
      if (server == null) {
        // Outside the server's reporting window. Settle without sending.
        if (!entry.isTerminal && !_executing.contains(entry.assignmentId)) {
          await _settle(entry, TerminalKind.cancelled, {
            'reason': _messages['unknown_to_server'],
          }, send: false);
          await _acknowledge(entry.assignmentId);
        }
        continue;
      }
      if (terminalOnServer.contains(server)) {
        if (!entry.isTerminal) {
          await supervisor.cancel(entry.assignmentId);
          await _settle(entry, TerminalKind.cancelled, {
            'reason': 'Ended on the server',
          }, send: false);
        }
        await _acknowledge(entry.assignmentId);
      }
    }
  }

  /// Runs once the connection is ready: re-sends terminal results the server
  /// has not acknowledged and starts admitted work that never started.
  Future<void> _resumeWork() async {
    for (final entry in journal.unacknowledged) {
      if (_dead || _stopping) return;
      if (entry.status == LocalStatus.terminal) {
        _sendTerminal(entry);
      } else if (entry.status == LocalStatus.accepted) {
        _track(_execute(entry.assignmentId));
      }
    }
  }

  void _track(Future<void> work) {
    _inFlight.add(work);
    work.whenComplete(() => _inFlight.remove(work));
  }

  bool get _accepting =>
      !_dead && !_stopping && connection.phase == ConnectionPhase.ready;

  void _onMessage(Map<String, Object?> message) {
    if (_dead) return;
    switch (message['type']) {
      case 'assignment.start':
        _track(_guard(() => _handleStart(message)));
      case 'assignment.cancel':
        _track(_guard(() => _handleCancel(message)));
      case 'assignment.start.permit.grant':
        _handlePermitGrant(message);
      case 'assignment.ack':
        _track(_guard(() => _handleTerminalAck(message)));
    }
  }

  /// Runs [action]; a [SimulatedCrash] kills the Agent like a dead process.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on SimulatedCrash {
      await kill();
    } on Object catch (error) {
      await _log('error ${error.runtimeType}');
    }
  }

  Future<void> _point(String point, String assignmentId) async {
    if (_dead) throw SimulatedCrash('dead before $point');
    await onPoint?.call(point, assignmentId);
  }

  bool _send(
    String type,
    Map<String, Object?> correlation,
    Map<String, Object?> payload,
  ) {
    if (_dead) return false;
    return connection.send(
      envelope(connection.ids, type, payload, correlation: correlation),
    );
  }

  void _ack(Map<String, Object?> correlation, bool accepted, {String? reason}) {
    _send('assignment.ack', correlation, {
      'accepted': accepted,
      if (accepted) 'estimatedStartMs': 0,
      if (reason != null) 'reason': reason,
    });
  }

  Future<void> _handleStart(Map<String, Object?> message) async {
    final correlation = correlationOf(message);
    final payload = message['payload'];
    if (correlation == null || payload is! Map<String, Object?>) return;
    final id = correlation['assignmentId'] as String;
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id)) {
      _ack(correlation, false, reason: 'invalid_assignment');
      return;
    }
    if (correlation['workerId'] != identity.workerId) {
      _ack(correlation, false, reason: 'wrong_worker');
      return;
    }
    final snapshot = payload['snapshot'];
    if (snapshot is! Map<String, Object?> ||
        snapshot['assignmentId'] != id ||
        snapshot['workerId'] != identity.workerId ||
        snapshot['attemptId'] != correlation['attemptId'] ||
        (snapshot['profileDigest'] != null &&
            snapshot['profileDigest'] is! String) ||
        snapshot['timeoutMs'] is! int ||
        (snapshot['timeoutMs'] as int) < 1000 ||
        (snapshot['timeoutMs'] as int) > 2147483647) {
      _ack(correlation, false, reason: 'invalid_assignment');
      return;
    }
    final existing = journal.find(id);
    if (existing != null) {
      if (existing.context.attemptId != correlation['attemptId']) {
        _ack(correlation, false, reason: 'attempt_mismatch');
        return;
      }
      existing.correlation = correlation;
      await _replay(existing);
      return;
    }
    if (!_admitting.add(id)) return; // a duplicate while the first is admitted
    try {
      if (!_accepting) {
        _ack(
          correlation,
          false,
          reason: _stopping ? 'worker_stopping' : 'worker_not_ready',
        );
        return;
      }
      if (_executing.length + _admitting.length > _maxAdmitted) {
        _ack(correlation, false, reason: 'worker_busy');
        return;
      }
      final blocked = await _admissionBlock(snapshot);
      if (blocked != null) {
        _ack(correlation, false, reason: blocked);
        return;
      }
      final context = AssignmentContext(
        runId: correlation['runId'] as String,
        taskId: correlation['taskId'] as String,
        attemptId: correlation['attemptId'] as String,
        idempotencyKey: correlation['idempotencyKey'] as String,
        snapshotDigest: snapshot['profileDigest'] as String?,
      );
      // Durable before acknowledged.
      await journal.record(
        id,
        LocalStatus.received,
        context: context,
        command: message,
        correlation: correlation,
      );
      await journal.record(id, LocalStatus.accepted);
      await _point('before-ack', id);
      _ack(correlation, true);
    } finally {
      _admitting.remove(id);
    }
    _track(_execute(id));
  }

  Future<String?> _admissionBlock(Map<String, Object?> payload) async {
    final report = await readiness.evaluate();
    if (!report.ready) return 'worker_not_ready';
    final digest = payload['profileDigest'];
    if (profiles != null) {
      if (digest is! String || !await profiles!.has(digest)) {
        return 'profile_unavailable';
      }
    }
    return null;
  }

  /// A command seen before: answer from the record and never start again.
  Future<void> _replay(JournalEntry entry) async {
    final correlation = entry.correlation;
    switch (entry.status) {
      case LocalStatus.received:
      case LocalStatus.accepted:
      case LocalStatus.starting:
        _ack(correlation, true);
      case LocalStatus.running:
        _ack(correlation, true);
        _send('assignment.start.ack', correlation, {
          'started': true,
          'engineStarted': true,
          'providerStarted': true,
          'startedAt': entry.updatedAt.toUtc().toIso8601String(),
        });
      case LocalStatus.terminal:
      case LocalStatus.acknowledged:
        _ack(correlation, true);
        _sendTerminal(entry);
    }
  }

  Future<void> _handleCancel(Map<String, Object?> message) async {
    final correlation = correlationOf(message);
    if (correlation == null) return;
    final id = correlation['assignmentId'] as String;
    final entry = journal.find(id);
    if (entry == null) {
      // Cancelled before the command ever arrived (for example while this
      // Worker was offline): record it so the command can never run.
      await journal.record(
        id,
        LocalStatus.received,
        context: AssignmentContext(
          runId: correlation['runId'] as String,
          taskId: correlation['taskId'] as String,
          attemptId: correlation['attemptId'] as String,
          idempotencyKey: correlation['idempotencyKey'] as String,
        ),
        correlation: correlation,
      );
      await journal.recordCancelIntent(id);
      await _settle(journal.find(id)!, TerminalKind.cancelled, {
        'reason': 'Cancelled before Worker launch',
      });
      return;
    }
    if (entry.isTerminal) {
      _send('assignment.cancel.ack', correlation, {
        'cancelled': true,
        'alreadyTerminated': true,
      });
      return;
    }
    await journal.recordCancelIntent(id);
    _send('assignment.cancel.ack', correlation, {'cancelled': true});
    // A start permit still being waited for is no longer wanted.
    final waiting = _permits[id];
    if (waiting != null && !waiting.isCompleted) waiting.complete(false);
    if (_executing.contains(id)) {
      await supervisor.cancel(id);
    } else if (entry.status == LocalStatus.accepted ||
        entry.status == LocalStatus.received) {
      await _settle(entry, TerminalKind.cancelled, {
        'reason': 'Cancelled before Worker launch',
      });
    }
  }

  void _handlePermitGrant(Map<String, Object?> message) {
    final id = message['assignmentId'];
    final payload = message['payload'];
    if (id is! String || payload is! Map) return;
    final waiting = _permits[id];
    final entry = journal.find(id);
    if (waiting == null || waiting.isCompleted || entry == null) return;
    // A grant is bound to the exact attempt that asked for it.
    if (message['attemptId'] != entry.context.attemptId) return;
    final expiry = payload['expiresAt'];
    final expiresAt = expiry is String ? DateTime.tryParse(expiry) : null;
    final permit = payload['permitId'];
    waiting.complete(
      payload['granted'] == true &&
          permit is String &&
          permit.isNotEmpty &&
          (expiresAt == null || expiresAt.isAfter(DateTime.now())),
    );
  }

  Future<bool> _requestPermit(JournalEntry entry) async {
    final id = entry.assignmentId;
    final waiting = _permits[id] = Completer<bool>();
    final timer = Timer.periodic(permitResend, (_) {
      if (!waiting.isCompleted) _sendPermitRequest(entry);
    });
    _sendPermitRequest(entry);
    try {
      return await waiting.future.timeout(
        permitTimeout,
        onTimeout: () => false,
      );
    } finally {
      timer.cancel();
      _permits.remove(id);
    }
  }

  void _sendPermitRequest(JournalEntry entry) => _send(
    'assignment.start.permit.request',
    entry.correlation,
    {'requestedAt': DateTime.now().toUtc().toIso8601String()},
  );

  Future<void> _execute(String id) => _guard(() async {
    if (!_executing.add(id)) return;
    connection.activeAssignments = _executing.length;
    try {
      final first = journal.find(id);
      if (first == null || first.status != LocalStatus.accepted) return;
      final command = first.command;
      final payload = command?['payload'];
      if (command == null || payload is! Map<String, Object?>) {
        await _settle(
          first,
          TerminalKind.failed,
          _failure('command_unavailable', retryable: true),
        );
        return;
      }
      if (first.cancelRequested) {
        await _settle(first, TerminalKind.cancelled, {
          'reason': 'Cancelled before Worker launch',
        });
        return;
      }
      final snapshot = payload['snapshot'];
      if (snapshot is! Map<String, Object?>) {
        await _settle(
          first,
          TerminalKind.failed,
          _failure('command_unavailable', retryable: false),
        );
        return;
      }
      final timeoutMs = snapshot['timeoutMs'];
      final request = EngineRequest(
        assignmentId: id,
        attemptId: first.context.attemptId,
        payload: payload,
        timeout: timeoutMs is int
            ? Duration(milliseconds: timeoutMs)
            : const Duration(minutes: 30),
      );
      EngineRun? run;
      try {
        run = await supervisor.start(
          request,
          authorize: () async {
            final granted = await _requestPermit(first);
            return granted && !(journal.find(id)?.cancelRequested ?? true);
          },
          // Recorded right before the Engine process is created.
          onLaunching: () async {
            await journal.record(id, LocalStatus.starting);
          },
        );
      } on EngineAlreadyStartedException {
        await _settleIfOpen(
          id,
          TerminalKind.failed,
          _failure('engine_failed', retryable: false),
        );
        return;
      } on SimulatedCrash {
        rethrow;
      } on Object {
        await _settleIfOpen(
          id,
          TerminalKind.failed,
          _failure('engine_failed', retryable: true),
        );
        return;
      }
      final launched = journal.find(id)!;
      if (run == null) {
        final cancelled = launched.cancelRequested;
        await _settle(
          launched,
          cancelled ? TerminalKind.cancelled : TerminalKind.failed,
          cancelled
              ? {'reason': 'Cancelled before Worker launch'}
              : _failure('start_not_authorized', retryable: true),
        );
        return;
      }
      await _point('after-engine-launch', id);
      final providerStarted = run is EngineStartEvidence
          ? await (run as EngineStartEvidence).providerStarted
          : true;
      if (_dead) return;
      if (providerStarted) {
        await journal.record(id, LocalStatus.running);
        _send('assignment.start.ack', launched.correlation, {
          'started': true,
          'engineStarted': true,
          'providerStarted': true,
          'startedAt': DateTime.now().toUtc().toIso8601String(),
        });
      }
      final outcome = await run.outcome;
      if (_dead) return;
      final running = journal.find(id)!;
      if (outcome.kind == TerminalKind.cancelled &&
          _stopping &&
          !running.cancelRequested) {
        await _settle(
          running,
          TerminalKind.failed,
          _failure('agent_stopped', retryable: true),
        );
      } else {
        await _settle(running, outcome.kind, outcome.payload);
      }
    } finally {
      _executing.remove(id);
      connection.activeAssignments = _executing.length;
    }
  });

  Future<void> _settleIfOpen(
    String id,
    TerminalKind kind,
    Map<String, Object?> payload,
  ) async {
    final current = journal.find(id);
    if (current != null && !current.isTerminal) {
      await _settle(current, kind, payload);
    }
  }

  /// Records the terminal result durably, then sends it. Returns false when
  /// the assignment was already terminal.
  Future<bool> _settle(
    JournalEntry entry,
    TerminalKind kind,
    Map<String, Object?> payload, {
    bool send = true,
  }) async {
    try {
      await journal.record(
        entry.assignmentId,
        LocalStatus.terminal,
        kind: kind,
        terminal: payload,
      );
    } on IllegalTransitionException {
      return false;
    }
    if (send) {
      _sendTerminal(journal.find(entry.assignmentId)!);
      await _point('after-terminal-send', entry.assignmentId);
    }
    return true;
  }

  bool _sendTerminal(JournalEntry entry) {
    final kind = entry.terminalKind;
    if (kind == null) return false;
    final terminal = entry.terminal ?? const <String, Object?>{};
    switch (kind) {
      case TerminalKind.completed:
        return _send('assignment.result', entry.correlation, {
          'status': 'completed',
          'summary': terminal['summary'] ?? 'Completed',
          if (terminal['output'] != null) 'output': terminal['output'],
          'artifactIds': terminal['artifactIds'] ?? const <String>[],
        });
      case TerminalKind.failed:
        return _send('assignment.error', entry.correlation, {
          'status': 'failed',
          'error': {
            'code': terminal['errorCode'] ?? 'execution_failed',
            'message':
                terminal['message'] ??
                'The Worker could not finish the assignment',
            'retryable': terminal['retryable'] == true,
          },
        });
      case TerminalKind.cancelled:
        return _send('assignment.cancelled', entry.correlation, {
          'status': 'cancelled',
          'reason': terminal['reason'] ?? 'Cancelled',
        });
    }
  }

  Future<void> _handleTerminalAck(Map<String, Object?> message) async {
    final payload = message['payload'];
    final id = message['assignmentId'];
    if (payload is! Map || payload['terminal'] != true || id is! String) return;
    final entry = journal.find(id);
    if (entry == null || entry.status != LocalStatus.terminal) return;
    if (payload['status'] != entry.terminalKind?.name) return;
    await _acknowledge(id);
  }

  Future<void> _acknowledge(String id) async {
    final entry = journal.find(id);
    if (entry == null || entry.status != LocalStatus.terminal) return;
    await journal.record(id, LocalStatus.acknowledged);
    if (journal.entries.length > 200) await journal.compact();
  }

  /// Graceful stop: running work ends as a retryable failure, the connection
  /// closes, the journal is flushed and the lock released.
  Future<void> stop() async {
    if (_dead) return;
    _stopping = true;
    await supervisor.cancelAll();
    await Future.wait(
      _inFlight.toList(),
    ).timeout(const Duration(seconds: 10), onTimeout: () => const []);
    await connection.stop();
    await _connectionDone;
    await _phaseSubscription?.cancel();
    await journal.close();
    await _writeState(phase: 'stopped');
    await lock.release();
    api.close();
  }

  /// Stands in for the process dying: nothing more is written or sent, handles
  /// close and the lock is released, with no goodbye to the server.
  Future<void> kill() async {
    if (_dead) return;
    _dead = true;
    for (final waiting in _permits.values) {
      if (!waiting.isCompleted) waiting.complete(false);
    }
    await connection.stop();
    await _phaseSubscription?.cancel();
    await journal.abandon();
    await lock.release();
  }

  Future<void> _writeState({String? phase}) async {
    if (_dead) return;
    try {
      final session = connection.session;
      final temp = File('${paths.tracesDir.path}/state.json.tmp');
      await temp.writeAsString(
        jsonEncode({
          'pid': pid,
          'phase': phase ?? connection.phase.name,
          'workerId': identity.workerId,
          if (session != null) 'sessionId': session.sessionId,
          if (session != null) 'epoch': session.epoch,
          'activeAssignments': _executing.length,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      await temp.rename('${paths.tracesDir.path}/state.json');
    } on Object {
      // State is informational; it must never break the Agent.
    }
  }

  /// One privacy-safe line: ids and codes only, never prompts, output, paths
  /// or credentials. The file is cut at 1 MiB.
  Future<void> _log(String line) async {
    if (_dead) return;
    try {
      final file = paths.logFile;
      if (await file.exists() && await file.length() > 1024 * 1024) {
        await file.rename('${file.path}.1');
      }
      await file.writeAsString(
        '${DateTime.now().toUtc().toIso8601String()} $line\n',
        mode: FileMode.append,
      );
    } on Object {
      // Logging must never break the Agent.
    }
  }
}
