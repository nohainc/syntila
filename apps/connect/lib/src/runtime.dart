import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'artifact_launcher.dart';
import 'config.dart';
import 'connection.dart';
import 'device.dart';
import 'folders.dart';
import 'engine.dart';
import 'faults.dart';
import 'identity.dart';
import 'inputs.dart';
import 'journal.dart';
import 'lock.dart';
import 'paths.dart';
import 'mcp_worker_allow_list.dart';
import 'mcp_worker_runner.dart';
import 'package:syntila_mcp_worker_store/syntila_mcp_worker_store.dart'
    show ExternalWorkerException;
import 'profile_cache.dart';
import 'readiness.dart';
import 'server_api.dart';
import 'wire.dart';
import 'work_root.dart';

/// One running Syntila Connect: one Worker Instance, one credential, one journal,
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
    this.plugins,
    this.mcpWorkerRunner,
    DeviceInfo? device,
    required this.permitTimeout,
    required this.permitResend,
    required this.onPoint,
    required SocketConnector? connector,
    required Duration baseDelay,
    required Duration heartbeatInterval,
    required Duration stepTimeout,
    required String clientVersion,
    this.folders,
    this.inputs,
  }) : _device = device {
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
      onSession: (grant) {
        _profileSession = grant;
        inputs?.session = grant;
        _foldersDirty = true;
        unawaited(_publishFolders());
        if (engine is ArtifactLauncher) engine.holder.update(grant);
        unawaited(_refreshIdentityMetadata(grant));
      },
      onRefreshModels: () => _startModelsRefresh(engine),
      onUsageRequest: (id) => _startUsageRead(engine, id),
      onWorkerName: (name) => unawaited(_saveIdentityNames(name, null)),
      readiness: () async {
        final report = (await readiness.evaluate()).toJson();
        unawaited(
          _log(
            'readiness ready=${report['ready']} failures=${report['failures']} engine=${engine.runtimeType}',
          ),
        );
        final items = await mcpWorkerRunner?.runnable() ?? const [];
        return {
          if (device != null) 'deviceId': device.deviceId,
          if (device != null) 'deviceName': device.deviceName,
          if (items.isNotEmpty) 'mcpWorkers': items,
          ...report,
        };
      },
    );
  }

  /// Keeps what was captured on this machine so `status` and the Connect app
  /// can show it, whether or not publishing to the cloud works.
  Future<void> _writeLocalModels(Map<String, Object?> report) async {
    try {
      final catalog = report['modelCatalog'];
      final entries = catalog is Map ? catalog['models'] : null;
      final models = <Map<String, Object?>>[
        if (entries is List)
          for (final entry in entries)
            if (entry is Map && entry['id'] is String)
              {
                'id': entry['id'],
                'name': entry['name'] is String ? entry['name'] : entry['id'],
                'efforts': entry['efforts'] is List
                    ? entry['efforts']
                    : const <Object?>[],
              },
      ];
      final file = paths.modelsFile;
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'status': report['status'],
          if (report['message'] is String) 'message': report['message'],
          'capturedAt': DateTime.now().toUtc().toIso8601String(),
          if (report['providerToolName'] != null)
            'providerToolName': report['providerToolName'],
          if (report['providerToolVersion'] != null)
            'providerToolVersion': report['providerToolVersion'],
          'models': models,
        }),
        flush: true,
      );
    } on Object {
      // A local copy is a convenience; never fail the capture over it.
    }
  }

  Timer? _modelsRequestTimer;

  final DeviceInfo? _device;

  /// This computer's allowed folders (machine-wide). Reported to the cloud so
  /// the owner can choose one for a Space.
  final AllowedFolders? folders;

  /// Downloads the person's files when a Step that needs them starts.
  final InputDelivery? inputs;

  bool _foldersDirty = false;
  bool _publishingFolders = false;
  DateTime? _foldersStamp;

  /// Publishes the allowed folders and the device name. Quiet on failure: the
  /// next tick tries again while [_foldersDirty] stays set.
  Future<void> _publishFolders() async {
    final session = _profileSession;
    final device = _device;
    final store = folders;
    if (_dead ||
        _publishingFolders ||
        session == null ||
        device == null ||
        store == null) {
      return;
    }
    _publishingFolders = true;
    try {
      // The Work Root is where Workers keep their own files, not a project
      // folder to choose for a Space, so it is never published.
      final workRoot = await WorkRoot(
        File(p.join(store.file.parent.path, 'work-root.json')),
        store,
      ).root();
      final listed = [
        for (final folder in await store.list())
          if (workRoot == null || folder['path'] != workRoot) folder,
      ];
      await api.publishFolders(
        workerId: identity.workerId,
        session: session,
        deviceId: device.deviceId,
        deviceName: device.deviceName,
        folders: [
          for (final folder in listed)
            {
              'id': folder['id']!,
              'name': _folderName(folder, listed),
              'mode': folder['mode'] ?? 'read',
            },
        ],
      );
      _foldersDirty = false;
      unawaited(_log('folders published count=${listed.length}'));
    } on Object catch (error) {
      unawaited(_log('folders publish failed $error'));
    } finally {
      _publishingFolders = false;
    }
  }

  /// The folder's name; when another allowed folder has the same name, the
  /// parent folder's name is added so the two can be told apart. Never a path.
  static String _folderName(
    Map<String, String> folder,
    List<Map<String, String>> all,
  ) {
    final label = _folderLabel(folder['path']!);
    final clashes =
        all.where((other) => _folderLabel(other['path']!) == label).length > 1;
    if (!clashes) return label;
    final parts = folder['path']!
        .split(RegExp(r'[\\/]'))
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.length < 2 ? label : '$label (${parts[parts.length - 2]})';
  }

  /// The folder's own name, never its path.
  static String _folderLabel(String path) {
    final parts = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
    return parts.isEmpty ? 'Folder' : parts.last;
  }

  /// Sends the folders again when the grants changed on disk (`folders add` or
  /// `remove` in another process) or the last send failed.
  Future<void> _publishFoldersIfChanged() async {
    final store = folders;
    if (store == null) return;
    try {
      final stamp = await store.file.exists()
          ? await store.file.lastModified()
          : null;
      if (stamp != _foldersStamp) {
        _foldersStamp = stamp;
        _foldersDirty = true;
      }
    } on Object {
      return;
    }
    if (_foldersDirty) await _publishFolders();
  }

  /// Starts a read of the models unless one is already running. Asked for by
  /// the owner (Workers page) or by the Connect app on this machine.
  void _startModelsRefresh(EngineLauncher launcher) {
    final session = _profileSession;
    unawaited(
      _log('models refresh requested busy=${_modelsPublished != null}'),
    );
    if (session == null || _modelsPublished != null) return;
    final run = _captureAndPublishModels(launcher, session);
    _modelsPublished = run;
    unawaited(
      run
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _modelsPublished = null),
    );
  }

  /// Watches for the request file `syntila-connect models refresh` leaves.
  void _watchModelsRequests(EngineLauncher launcher) {
    _modelsRequestTimer?.cancel();
    _modelsRequestTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_dead) return;
      unawaited(_publishFoldersIfChanged());
      try {
        final file = paths.modelsRequestFile;
        if (!await file.exists()) return;
        await file.delete();
        _startModelsRefresh(launcher);
      } on Object {
        // Try again on the next tick.
      }
    });
  }

  final Set<String> _usageRequests = {};

  /// Reads the provider's usage report for the owner and returns it to the
  /// Cloud once. A request id is answered at most once (the Cloud repeats it
  /// on heartbeats until it is answered).
  void _startUsageRead(EngineLauncher launcher, String requestId) {
    final session = _profileSession;
    if (session == null || _dead || !_usageRequests.add(requestId)) return;
    if (_usageRequests.length > 32) _usageRequests.remove(_usageRequests.first);
    unawaited(() async {
      Map<String, Object?> report;
      try {
        var source = launcher;
        final type = session.workerTypeId;
        final revision = session.profileRevision;
        final digest = session.profileDigest;
        if (type == null || revision == null || digest == null) {
          report = {
            'status': 'error',
            'errorCode': 'worker_not_ready',
            'errorMessage': 'The Worker Profile is not ready.',
          };
        } else if (source is! UsageSource) {
          report = {
            'status': 'error',
            'errorCode': 'engine_unavailable',
            'errorMessage': 'The Engine is not available on this computer.',
          };
        } else {
          report = await (source as UsageSource).readUsage({
            'profileDigest': digest,
            'workerTypeId': type,
            'profileRevision': revision,
          });
        }
      } on Object {
        report = {
          'status': 'error',
          'errorCode': 'usage_failed',
          'errorMessage': 'The usage report could not be read.',
        };
      }
      try {
        await api.publishUsage(
          workerId: identity.workerId,
          session: session,
          requestId: requestId,
          report: report,
        );
      } on Object catch (error) {
        await _log('usage publish failed ${error.runtimeType}');
      }
    }());
  }

  /// The capture-and-publish in progress, if any (null when idle).
  Future<String>? _modelsPublished;

  /// Captures the models and efforts the provider CLI offers (a passive probe of
  /// the Type's published Profile) and publishes them to this Worker, or
  /// publishes the reason it could not. Runs only when the owner asks for it
  /// on the Workers page; pairing and starting the service do none of this.
  Future<String> _captureAndPublishModels(
    EngineLauncher launcher,
    SessionGrant session,
  ) async {
    var status = 'probe_failed';
    var report = <String, Object?>{'status': status};
    try {
      final cache = profiles;
      final type = session.workerTypeId;
      final revision = session.profileRevision;
      final digest = session.profileDigest;
      var source = launcher;
      if (source is ArtifactLauncher) source = source.inner;
      if (cache == null || type == null || revision == null || digest == null) {
        report = {'status': 'profile_unavailable'};
      } else if (source is! ModelCatalogSource) {
        report = {'status': 'engine_unavailable'};
      } else {
        if (!await cache.has(digest)) {
          final fetched = await api.downloadProfile(
            workerId: identity.workerId,
            session: session,
            revision: revision,
            digest: digest,
          );
          await cache.putSnapshot(
            fetched.snapshot,
            workerTypeId: type,
            revision: revision,
            digest: digest,
            signature: fetched.proof,
          );
        }
        report = await (source as ModelCatalogSource).discoverModels({
          'profileDigest': digest,
          'workerTypeId': type,
          'profileRevision': revision,
        });
      }
    } on Object catch (error) {
      await _log('models capture failed ${error.runtimeType}');
      report = {'status': 'profile_unavailable'};
    }
    status = report['status'] as String? ?? 'probe_failed';
    await _writeLocalModels(report);
    final said = report['message'];
    await _log(
      'models captured status=$status'
      '${status != 'ok' && said is String && said.isNotEmpty ? ' message=${said.replaceAll(RegExp(r'\s+'), ' ')}' : ''}',
    );
    try {
      await api.publishModels(
        workerId: identity.workerId,
        session: session,
        report: report,
      );
    } on Object catch (error) {
      await _log('models publish failed ${error.runtimeType}');
      return 'publish_failed';
    }
    return status;
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

  /// MCP Workers the owner approved locally (ADR-041). Null approves none.
  final McpWorkerAllowList? plugins;
  final McpWorkerRunner? mcpWorkerRunner;
  final Duration permitTimeout;
  final Duration permitResend;
  final FaultPoint? onPoint;
  late final AgentConnection connection;
  SessionGrant? _profileSession;

  final Set<String> _admitting = {};
  final Set<String> _pendingCancels = {};
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
    McpWorkerAllowList? plugins,
    McpWorkerRunner? mcpWorkerRunner,
    DeviceInfo? device,
    AllowedFolders? folders,
    InputDelivery? inputs,
    FaultPoint? onPoint,
    Duration baseDelay = const Duration(seconds: 1),
    Duration heartbeatInterval = const Duration(seconds: 30),
    Duration stepTimeout = const Duration(seconds: 30),
    Duration permitTimeout = const Duration(minutes: 2),
    Duration permitResend = const Duration(seconds: 5),
    String clientVersion = '0.2.1',
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
        supervisor: EngineSupervisor(engine),
        readiness: checks,
        profiles: profiles,
        plugins: plugins,
        mcpWorkerRunner: mcpWorkerRunner,
        device: device,
        folders: folders,
        inputs: inputs,
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
    _watchModelsRequests(supervisor.launcher);
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
    'agent_restarted': 'The Syntila Connect restarted while this was running',
    'agent_stopped': 'The Syntila Connect was stopped while this was running',
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
      if (_pendingCancels.remove(id)) {
        await journal.recordCancelIntent(id);
        await journal.record(id, LocalStatus.accepted);
        await _point('before-ack', id);
        _ack(correlation, true);
        await _settle(journal.find(id)!, TerminalKind.cancelled, {
          'reason': 'Cancelled before Worker launch',
        });
        return;
      }
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
    final plugin = payload['plugin'];
    if (plugin != null) {
      // Only an MCP Worker the owner approved here, by exact digest, may run.
      final approved =
          plugin is Map &&
          plugin['id'] is String &&
          plugin['version'] is String &&
          plugin['manifestDigest'] is String &&
          await (plugins?.isApproved(
                plugin['id'] as String,
                plugin['version'] as String,
                plugin['manifestDigest'] as String,
              ) ??
              Future.value(false));
      if (!approved) return 'mcp_worker_not_approved';
      final runner = mcpWorkerRunner;
      if (runner == null) return 'mcp_worker_runner_unavailable';
      try {
        await runner.prepare(plugin);
        return null; // The launcher rechecks before starting the Engine.
      } on ExternalWorkerException catch (error) {
        return error.code;
      } on Object {
        return 'worker_not_ready';
      }
    }
    final digest = payload['profileDigest'];
    if (profiles != null) {
      if (digest is! String) return 'profile_unavailable';
      if (!await profiles!.has(digest)) {
        final session = _profileSession;
        final type = payload['workerTypeId'];
        final revision = payload['profileRevision'];
        if (session == null || type is! String || revision is! int) {
          return 'profile_unavailable';
        }
        try {
          final fetched = await api.downloadProfile(
            workerId: identity.workerId,
            session: session,
            revision: revision,
            digest: digest,
          );
          await profiles!.putSnapshot(
            fetched.snapshot,
            workerTypeId: type,
            revision: revision,
            digest: digest,
            signature: fetched.proof,
          );
        } on Object {
          return 'profile_unavailable';
        }
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
      if (_admitting.contains(id)) {
        _pendingCancels.add(id);
        _send('assignment.cancel.ack', correlation, {'cancelled': true});
        return;
      }
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
        onActivity: (activity) {
          if (_dead || activity.assignmentId != id) return;
          try {
            _send('assignment.activity', first.correlation, {
              'assignmentId': activity.assignmentId,
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
            });
          } on Object {
            // Progress is best effort; a disconnected socket must not fail work.
          }
        },
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
      if (outcome.kind == TerminalKind.failed) {
        unawaited(
          _log(
            'assignment failed code=${outcome.payload['errorCode']} '
            'type=${outcome.payload['diagnostic'] ?? '-'}',
          ),
        );
      }
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
        // The Cloud accepts only its own codes, each with its canonical safe
        // message; anything else is rejected and the assignment would stay
        // "running". Agent-local reasons therefore end as `execution_failed`.
        final raw = terminal['errorCode'];
        final code = raw is String && _cloudErrorMessages.containsKey(raw)
            ? raw
            : 'execution_failed';
        return _send('assignment.error', entry.correlation, {
          'status': 'failed',
          'error': {
            'code': code,
            'message': _cloudErrorMessages[code],
            'retryable': terminal['retryable'] == true,
            // What the provider CLI said, short and readable (the Cloud allows
            // a bounded string value).
            if (terminal['detail'] is String)
              'details': {'diagnostic': terminal['detail']},
          },
          // The provider's own failure details; the Cloud stores them encrypted.
          if (terminal['providerFailure'] is Map)
            'providerFailure': terminal['providerFailure'],
        });
      case TerminalKind.cancelled:
        return _send('assignment.cancelled', entry.correlation, {
          'status': 'cancelled',
          'reason': terminal['reason'] ?? 'Cancelled',
        });
    }
  }

  /// The Cloud's execution error codes and their canonical messages
  /// (`packages/protocol` EXECUTION_ERROR_MESSAGES).
  static const _cloudErrorMessages = {
    'worker_not_ready': 'The selected Worker is not ready.',
    'cli_not_found': 'The required local CLI could not be found.',
    'authentication_required':
        'Sign in to the configured provider on this computer.',
    'unsupported_cli_version':
        'The installed local CLI version is not supported.',
    'model_not_supported':
        'The selected model is not supported by this Worker.',
    'permission_denied':
        'A local permission required for this assignment was denied.',
    'space_folder_exists':
        "A folder with this Space's name already exists on this computer and is not empty. Confirm to use it.",
    'quota_exhausted': "The provider's usage limit has been reached.",
    'provider_unavailable': 'The provider is temporarily unavailable.',
    'timeout': 'The assignment exceeded its time limit.',
    'cancelled': 'The assignment was cancelled.',
    'execution_failed': 'The assignment could not be completed.',
    'context_limit_exceeded':
        'This conversation exceeds the supported context limit. Clear AI History and retry; the latest answer is kept as context.',
    'additional_folders_unsupported':
        "This Worker cannot use the Space's additional folders yet. Detach the additional folders or choose another Worker.",
    'worker_offline':
        'The selected Worker is offline. Start its Agent and try again.',
  };

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
    _modelsRequestTimer?.cancel();
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
    _modelsRequestTimer?.cancel();
    for (final waiting in _permits.values) {
      if (!waiting.isCompleted) waiting.complete(false);
    }
    await connection.stop();
    await _phaseSubscription?.cancel();
    await journal.abandon();
    await lock.release();
  }

  Future<void> _refreshIdentityMetadata(SessionGrant grant) async {
    if (_dead) return;
    await _saveIdentityNames(grant.workerName, grant.workerType);
  }

  Future<void> _saveIdentityNames(String? name, String? type) async {
    if (_dead) return;
    final serverName = name?.trim();
    final serverType = type?.trim();
    if ((serverName == null || serverName.isEmpty) &&
        (serverType == null || serverType.isEmpty)) {
      return;
    }
    try {
      final current = await AgentIdentity.load(paths.identityFile);
      if (current == null) return;
      final nextName = (serverName != null && serverName.isNotEmpty)
          ? serverName
          : (current.workerName != null &&
                current.workerName!.trim().isNotEmpty)
          ? current.workerName
          : serverType;
      final nextType = (serverType != null && serverType.isNotEmpty)
          ? serverType
          : current.workerType;
      if (nextName == current.workerName && nextType == current.workerType) {
        return;
      }
      await AgentIdentity(
        workerId: current.workerId,
        serverUrl: current.serverUrl,
        pairedAt: current.pairedAt,
        workerName: nextName,
        workerType: nextType,
      ).save(paths.identityFile);
    } on Object {
      // Metadata update is non-fatal.
    }
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
