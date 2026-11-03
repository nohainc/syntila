import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_plugin_conformance/syntila_plugin_conformance.dart'
    show ConformanceLauncher, LineQueue, PluginConnection;
import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';

import 'plugin_redactor.dart';

/// Everything the Service has verified and resolved about one plugin launch.
/// The Engine trusts none of it blindly: it re-hashes the artifact itself.
class PluginLaunch {
  const PluginLaunch({
    required this.executable,
    required this.arguments,
    required this.artifactSha256,
    required this.pluginId,
    required this.version,
    required this.dataDirectory,
    required this.workingDirectory,
    required this.environment,
    required this.hostVersion,
  });

  /// Absolute path inside the Service's read-only plugin store.
  final String executable;
  final List<String> arguments;
  final String artifactSha256;
  final String pluginId;
  final String version;
  final String dataDirectory;
  final String workingDirectory;

  /// The complete child environment (use [PluginHost.buildEnvironment]).
  final Map<String, String> environment;
  final String hostVersion;
}

class PluginRunRequest {
  const PluginRunRequest({
    required this.executeId,
    required this.prompt,
    required this.access,
    required this.deadline,
    this.model,
    this.sessionKey,
    this.sessionMode = 'new',
  }) : probeMode = null;

  /// A readiness probe (`passive` or `live`) instead of an execute.
  const PluginRunRequest.probe({
    required this.executeId,
    required String mode,
    required this.deadline,
  }) : prompt = '',
       access = 'read_only',
       model = null,
       sessionKey = null,
       sessionMode = 'new',
       probeMode = mode;

  final String? probeMode;

  final String executeId;
  final String prompt;

  /// `read_only` or `read_write`; sent to the plugin, enforced only where the
  /// isolation tier says so.
  final String access;
  final Duration deadline;
  final String? model;
  final String? sessionKey;
  final String sessionMode;
}

sealed class PluginRunOutcome {
  const PluginRunOutcome();
}

final class PluginRunSuccess extends PluginRunOutcome {
  const PluginRunSuccess({
    required this.output,
    required this.artifacts,
    required this.sessionState,
    required this.droppedFrames,
  });
  final String output;
  final List<String> artifacts;
  final String? sessionState;
  final int droppedFrames;
}

final class PluginProbeSuccess extends PluginRunOutcome {
  const PluginProbeSuccess({
    required this.state,
    required this.issueCode,
    required this.checks,
  });

  /// `ready`, `setup_required`, `sign_in_required`, `unavailable` or `failed`.
  final String state;
  final String? issueCode;
  final List<Map<String, Object?>> checks;
}

final class PluginRunFailure extends PluginRunOutcome {
  const PluginRunFailure({
    required this.code,
    required this.message,
    this.retryable = false,
    this.fromPlugin = false,
    this.stderrTail = '',
  });

  /// A `PluginHostFailure` code, or a normalized plugin error code when
  /// [fromPlugin] is true.
  final String code;
  final String message;
  final bool retryable;
  final bool fromPlugin;
  final String stderrTail;
}

/// Supervises one plugin process for one execute: digest re-check, spawn,
/// handshake, work, heartbeats, cancel, shutdown and tree cleanup. Protocol
/// rules live in [PluginHostSession]; this class adds only process I/O.
class PluginHost {
  PluginHost({
    PlatformProcessSupervisor supervisor = const StandardProcessSupervisor(),
  }) : _supervisor = supervisor;

  final PlatformProcessSupervisor _supervisor;

  static const _stderrLimit = 64 * 1024;
  static const _tick = Duration(milliseconds: 250);

  /// Parent variables a plugin may inherit; `SYNTILA_*` is never inherited.
  static const inheritedParentKeys = <String>{
    'PATH',
    'HOME',
    'USER',
    'LOGNAME',
    'LANG',
    'LC_ALL',
    'TMPDIR',
    'TEMP',
    'TMP',
    'USERPROFILE',
    'APPDATA',
    'LOCALAPPDATA',
    'SYSTEMROOT',
    'XDG_CONFIG_HOME',
    'XDG_DATA_HOME',
    'XDG_STATE_HOME',
  };

  /// The built (not copied) environment: the allow-list plus the names the
  /// user consented to, minus anything starting with `SYNTILA_`.
  static Map<String, String> buildEnvironment({
    Iterable<String> consentedNames = const [],
    Map<String, String>? parentEnvironment,
  }) {
    final parent = parentEnvironment ?? Platform.environment;
    final built = const CliEnvironmentBuilder(
      allowedParentKeys: inheritedParentKeys,
    ).build(parentEnvironment: parent);
    for (final name in consentedNames) {
      final value = parent[name];
      if (value != null && !name.startsWith('SYNTILA_')) built[name] = value;
    }
    built.removeWhere((key, _) => key.startsWith('SYNTILA_'));
    return built;
  }

  Future<String> sha256OfFile(String path) async =>
      (await sha256.bind(File(path).openRead()).first).toString();

  /// Runs one execute. [cancel] completes to request a cooperative cancel.
  Future<PluginRunOutcome> run(
    PluginLaunch launch,
    PluginRunRequest request, {
    void Function(PluginFrame frame)? onFrame,
    void Function()? onWorkStarted,
    Future<void>? cancel,
  }) async {
    final redactor = PluginRedactor(secrets: launch.environment.values);
    final String digest;
    try {
      digest = await sha256OfFile(launch.executable);
    } on Object {
      return const PluginRunFailure(
        code: PluginHostFailure.digestMismatch,
        message: 'The plugin artifact could not be read.',
      );
    }
    if (digest != launch.artifactSha256) {
      return const PluginRunFailure(
        code: PluginHostFailure.digestMismatch,
        message: 'The plugin artifact does not match its pinned digest.',
      );
    }

    final Process process;
    try {
      process = await _supervisor.startIsolatedProcess(
        launch.executable,
        launch.arguments,
        workingDirectory: launch.workingDirectory,
        environment: launch.environment,
        includeParentEnvironment: false,
      );
    } on Object {
      return const PluginRunFailure(
        code: PluginHostFailure.crashed,
        message: 'The plugin process could not be started.',
      );
    }

    final session = PluginHostSession(
      expectedPluginId: launch.pluginId,
      expectedVersion: launch.version,
    );
    final done = Completer<PluginRunOutcome>();
    final stderrBytes = BytesBuilder(copy: false);
    var sentExecute = false;
    var timedOut = false;
    var cancelRequested = false;
    var killImmediately = false;
    Timer? ticker;
    Timer? deadlineTimer;

    String stderrTail() {
      final all = stderrBytes.toBytes();
      final tail = all.length > _stderrLimit
          ? all.sublist(all.length - _stderrLimit)
          : all;
      return redactor.redact(utf8.decode(tail, allowMalformed: true));
    }

    void finish(PluginRunOutcome outcome, {bool kill = false}) {
      if (done.isCompleted) return;
      killImmediately = kill;
      done.complete(outcome);
    }

    void fail(String code, String message, {bool fromPlugin = false}) => finish(
      PluginRunFailure(
        code: code,
        message: redactor.redact(message),
        fromPlugin: fromPlugin,
        stderrTail: stderrTail(),
      ),
      kill: !fromPlugin,
    );

    void write(PluginFrame frame) {
      try {
        process.stdin.writeln(frame.encode());
      } on Object {
        // A closed pipe surfaces as a process exit.
      }
    }

    void sendCancel(String reason) {
      cancelRequested = true;
      // Before `execute` is sent there is nothing to cancel on the plugin side;
      // the request is honored the moment the handshake completes.
      if (session.phase != PluginSessionPhase.executing) return;
      write(session.requestCancel(reason: reason));
    }

    void onLine(String line) {
      final PluginFrame frame;
      try {
        frame = decodePluginFrame(line, PluginDirection.pluginToHost);
      } on PluginFrameException catch (error) {
        fail(PluginHostFailure.protocolViolation, error.message);
        return;
      }
      final verdict = session.onPluginFrame(frame);
      for (final reply in session.takeReplies()) {
        write(reply);
      }
      if (verdict.isViolation) {
        fail(verdict.code!, verdict.detail ?? 'Protocol violation.');
        return;
      }
      if (verdict.kind != FrameVerdictKind.accept) return;
      switch (frame.type) {
        case 'hello.result':
          if (cancelRequested && !sentExecute) {
            sentExecute = true;
            finish(
              PluginRunFailure(
                code: timedOut ? 'timeout' : 'cancelled',
                message: 'Cancelled before the plugin started work.',
                stderrTail: stderrTail(),
              ),
            );
          } else if (!sentExecute && request.probeMode != null) {
            sentExecute = true;
            write(
              session.beginProbe(
                id: request.executeId,
                mode: request.probeMode!,
              ),
            );
          } else if (!sentExecute) {
            sentExecute = true;
            onWorkStarted?.call();
            write(
              session.beginExecute(
                PluginFrame.execute(
                  id: request.executeId,
                  deadlineMs: request.deadline.inMilliseconds.clamp(
                    1,
                    PluginProtocolLimits.maxTimeoutMs,
                  ),
                  prompt: request.prompt,
                  workingDirectory: launch.workingDirectory,
                  access: request.access,
                  model: request.model,
                  sessionKey: request.sessionKey,
                  sessionMode: request.sessionMode,
                ),
              ),
            );
          }
        case 'probe.result':
          final rawChecks = (frame.json['checks'] as List?) ?? const [];
          finish(
            PluginProbeSuccess(
              state: frame.json['state'] as String,
              issueCode: frame.json['issueCode'] as String?,
              checks: [
                for (final raw in rawChecks)
                  _redactedCheck(
                    Map<String, Object?>.from(raw as Map),
                    redactor,
                  ),
              ],
            ),
          );
        case 'progress' || 'activity':
          onFrame?.call(_redactedFrame(frame, redactor));
        case 'result':
          final artifacts = <String>[];
          for (final entry in (frame.json['artifacts'] as List?) ?? const []) {
            artifacts.add((entry as Map)['path'] as String);
          }
          final bad = _artifactProblem(launch.workingDirectory, artifacts);
          if (bad != null) {
            fail(PluginHostFailure.artifactPathInvalid, bad);
            return;
          }
          final sessionJson = frame.json['session'];
          finish(
            PluginRunSuccess(
              output: frame.json['output'] as String,
              artifacts: artifacts,
              sessionState: sessionJson is Map
                  ? sessionJson['state'] as String?
                  : null,
              droppedFrames: session.droppedFrames,
            ),
          );
        case 'error':
          var code = normalizePluginErrorCode(frame.json['code'] as String);
          if (timedOut && code == 'cancelled') code = 'timeout';
          finish(
            PluginRunFailure(
              code: code,
              message: redactor.redact(
                (frame.json['message'] as String?) ?? '',
              ),
              retryable: frame.json['retryable'] == true,
              fromPlugin: true,
              stderrTail: stderrTail(),
            ),
          );
      }
    }

    final framer = _LineFramer(
      onLine: onLine,
      onOversize: () => fail(
        PluginHostFailure.protocolViolation,
        'A frame exceeded the byte limit.',
      ),
    );
    final stdoutDone = process.stdout.listen(
      framer.add,
      onError: (_) {},
      cancelOnError: false,
    );
    final stderrSub = process.stderr.listen((chunk) {
      stderrBytes.add(chunk);
      if (stderrBytes.length > _stderrLimit * 2) {
        final tail = stderrBytes.takeBytes();
        stderrBytes.add(tail.sublist(tail.length - _stderrLimit));
      }
    }, onError: (_) {});
    unawaited(process.stdin.done.catchError((_) {}));

    unawaited(
      process.exitCode.then((code) {
        if (done.isCompleted) return;
        fail(
          PluginHostFailure.crashed,
          'The plugin exited with status $code before finishing.',
        );
      }),
    );
    if (cancel != null) {
      unawaited(cancel.then((_) => sendCancel('user')));
    }
    ticker = Timer.periodic(_tick, (_) {
      if (done.isCompleted) return;
      if (session.handshakeOverdue) {
        fail(
          PluginHostFailure.handshakeFailed,
          'The plugin did not complete the handshake in time.',
        );
      } else if (session.unresponsive) {
        fail(PluginHostFailure.unresponsive, 'The plugin stopped responding.');
      } else if (session.cancelOverdue) {
        fail(
          timedOut ? 'timeout' : 'cancelled',
          'The plugin did not stop within the cancel grace period.',
        );
      } else {
        final ping = session.nextPing();
        if (ping != null) write(ping);
      }
    });
    deadlineTimer = Timer(request.deadline, () {
      timedOut = true;
      if (request.probeMode != null) {
        fail('timeout', 'The plugin did not answer the probe in time.');
        return;
      }
      sendCancel('timeout');
    });

    write(
      session.startHandshake(
        id: 'hello-${request.executeId}',
        hostVersion: launch.hostVersion,
        dataDir: launch.dataDirectory,
      ),
    );

    final outcome = await done.future;
    ticker.cancel();
    deadlineTimer.cancel();

    // Orderly stop when the plugin is healthy; otherwise terminate the tree.
    if (!killImmediately) {
      try {
        process.stdin.writeln(PluginFrame.shutdown().encode());
        await process.stdin.flush();
        await process.stdin.close();
      } on Object {
        // Falls through to the exit wait and forced cleanup.
      }
      try {
        await process.exitCode.timeout(PluginProtocolLimits.shutdownGrace);
      } on TimeoutException {
        await _supervisor.terminateProcessTree(process, force: true);
      }
    } else {
      await _supervisor.terminateProcessTree(process, force: true);
    }
    await stdoutDone.cancel();
    await stderrSub.cancel();
    return outcome;
  }

  /// Opens a raw line-oriented connection for the conformance suite with the
  /// same guarantees as [run]: digest re-check before spawn, built
  /// environment, no shell, and process-tree cleanup. The caller drives the
  /// protocol itself.
  Future<PluginConnection> connect(PluginLaunch launch) async {
    final String digest;
    try {
      digest = await sha256OfFile(launch.executable);
    } on Object {
      throw const PluginLaunchException(
        PluginHostFailure.digestMismatch,
        'The plugin artifact could not be read.',
      );
    }
    if (digest != launch.artifactSha256) {
      throw const PluginLaunchException(
        PluginHostFailure.digestMismatch,
        'The plugin artifact does not match its pinned digest.',
      );
    }
    final Process process;
    try {
      process = await _supervisor.startIsolatedProcess(
        launch.executable,
        launch.arguments,
        workingDirectory: launch.workingDirectory,
        environment: launch.environment,
        includeParentEnvironment: false,
      );
    } on Object {
      throw const PluginLaunchException(
        PluginHostFailure.crashed,
        'The plugin process could not be started.',
      );
    }
    return _HostConnection(process, _supervisor);
  }

  /// Declared artifacts must exist inside the working directory after symlink
  /// resolution.
  static String? _artifactProblem(String workingDirectory, List<String> paths) {
    final String base;
    try {
      base = Directory(workingDirectory).resolveSymbolicLinksSync();
    } on Object {
      return 'The working directory is not available.';
    }
    for (final relative in paths) {
      final candidate = File(
        '$workingDirectory${Platform.pathSeparator}$relative',
      );
      try {
        final resolved = candidate.resolveSymbolicLinksSync();
        if (resolved != base &&
            !resolved.startsWith('$base${Platform.pathSeparator}')) {
          return 'An artifact resolves outside the working directory.';
        }
      } on FileSystemException {
        return 'A declared artifact does not exist.';
      }
    }
    return null;
  }

  static Map<String, Object?> _redactedCheck(
    Map<String, Object?> check,
    PluginRedactor redactor,
  ) {
    final message = check['message'];
    if (message is String) check['message'] = redactor.redact(message);
    return check;
  }

  static PluginFrame _redactedFrame(PluginFrame frame, PluginRedactor r) {
    final json = Map<String, Object?>.from(frame.json);
    final message = json['message'];
    if (message is String) json['message'] = r.redact(message);
    final title = json['title'];
    if (title is String) json['title'] = r.redact(title);
    final details = json['details'];
    if (details != null) {
      try {
        json['details'] = jsonDecode(r.redact(jsonEncode(details)));
      } on FormatException {
        json['details'] = const <String, Object?>{};
      }
    }
    return PluginFrame(frame.type, json);
  }
}

/// Splits stdout bytes into lines without ever buffering more than one frame.
class _LineFramer {
  _LineFramer({required this.onLine, required this.onOversize});

  final void Function(String line) onLine;
  final void Function() onOversize;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  bool _overflowed = false;

  void add(List<int> data) {
    if (_overflowed) return;
    final chunk = data is Uint8List ? data : Uint8List.fromList(data);
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 0x0A) continue;
      _buffer.add(Uint8List.sublistView(chunk, start, i));
      _emit();
      if (_overflowed) return;
      start = i + 1;
    }
    if (start < chunk.length) {
      _buffer.add(Uint8List.sublistView(chunk, start));
      if (_buffer.length > PluginProtocolLimits.maxFrameBytes) {
        _overflowed = true;
        _buffer.clear();
        onOversize();
      }
    }
  }

  void _emit() {
    final bytes = _buffer.takeBytes();
    if (bytes.length + 1 > PluginProtocolLimits.maxFrameBytes) {
      _overflowed = true;
      onOversize();
      return;
    }
    if (bytes.isEmpty) return;
    onLine(utf8.decode(bytes, allowMalformed: true));
  }
}

class PluginLaunchException implements Exception {
  const PluginLaunchException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Starts a fresh supervised plugin process per conformance case.
class PluginHostLauncher implements ConformanceLauncher {
  PluginHostLauncher(this.host, this.target);

  final PluginHost host;
  final PluginLaunch target;

  @override
  Future<PluginConnection> launch() => host.connect(target);
}

class _HostConnection implements PluginConnection {
  _HostConnection(this._process, this._supervisor) {
    _subscription = _process.stdout.listen(
      _queue.add,
      onDone: _queue.close,
      onError: (_) => _queue.close(),
    );
    _process.stderr.drain<void>().catchError((_) {});
    unawaited(_process.stdin.done.catchError((_) {}));
  }

  final Process _process;
  final PlatformProcessSupervisor _supervisor;
  final LineQueue _queue = LineQueue();
  late final StreamSubscription<List<int>> _subscription;

  @override
  Future<void> send(String line) async {
    try {
      _process.stdin.writeln(line);
      await _process.stdin.flush();
    } on Object {
      // A closed pipe is observed through the exit.
    }
  }

  @override
  Future<String?> readLine(Duration timeout) => _queue.next(timeout);

  @override
  Future<void> closeInput() async {
    try {
      await _process.stdin.close();
    } on Object {
      // Already closed.
    }
  }

  @override
  Future<int?> waitForExit(Duration timeout) async {
    try {
      return await _process.exitCode.timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }

  @override
  Future<void> kill() async {
    await _supervisor.terminateProcessTree(_process, force: true);
    await _subscription.cancel();
  }
}
