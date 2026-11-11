import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_external_worker_conformance/syntila_external_worker_conformance.dart'
    show LineQueue, ExternalWorkerConnection;
import 'package:syntila_external_worker_protocol/syntila_external_worker_protocol.dart';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';

import 'mcp_host.dart';
import 'mcp_worker_runner.dart';
import 'external_worker_resource_monitor.dart';

/// Everything the Service has verified and resolved about one plugin launch.
/// The Engine trusts none of it blindly: it re-hashes the artifact itself.
class ExternalWorkerLaunch {
  const ExternalWorkerLaunch({
    required this.executable,
    required this.arguments,
    required this.artifactSha256,
    required this.pluginId,
    required this.version,
    required this.dataDirectory,
    required this.workingDirectory,
    required this.environment,
    required this.hostVersion,
    this.mcpToolPins,
  });

  /// Absolute path inside the Service's read-only plugin store.
  final String executable;
  final List<String> arguments;
  final String artifactSha256;
  final String pluginId;
  final String version;
  final String dataDirectory;
  final String workingDirectory;

  /// The complete child environment (use [ExternalWorkerProcessHost.buildEnvironment]).
  final Map<String, String> environment;
  final String hostVersion;

  /// The consented tool definition hashes of an MCP Worker (ADR-028). Null
  /// for an MCP tool server launch, which [ExternalWorkerProcessHost.run] refuses.
  final Map<String, String>? mcpToolPins;
}

class ExternalWorkerRunRequest {
  const ExternalWorkerRunRequest({
    required this.executeId,
    required this.prompt,
    required this.access,
    required this.deadline,
    this.model,
    this.sessionKey,
    this.sessionMode = 'new',
    this.conversation,
  }) : probeMode = null,
       discoverModels = false;

  /// A readiness probe (`passive` or `live`) instead of an execute.
  const ExternalWorkerRunRequest.probe({
    required this.executeId,
    required String mode,
    required this.deadline,
  }) : prompt = '',
       access = 'read_only',
       model = null,
       sessionKey = null,
       sessionMode = 'new',
       conversation = null,
       probeMode = mode,
       discoverModels = false;

  const ExternalWorkerRunRequest.models({
    required this.executeId,
    required this.deadline,
  }) : prompt = '',
       access = 'read_only',
       model = null,
       sessionKey = null,
       sessionMode = 'new',
       conversation = null,
       probeMode = null,
       discoverModels = true;

  final bool discoverModels;

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

  /// The exchange [prompt] carries, as separate turns (see
  /// `externalWorkerConversation`).
  final Map<String, Object?>? conversation;
}

sealed class ExternalWorkerRunOutcome {
  const ExternalWorkerRunOutcome();
}

final class ExternalWorkerRunSuccess extends ExternalWorkerRunOutcome {
  const ExternalWorkerRunSuccess({
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

final class ExternalWorkerProbeSuccess extends ExternalWorkerRunOutcome {
  const ExternalWorkerProbeSuccess({
    required this.state,
    required this.issueCode,
    required this.checks,
    this.capabilities = const {},
  });

  /// `ready`, `setup_required`, `sign_in_required`, `unavailable` or `failed`.
  final String state;
  final String? issueCode;
  final List<Map<String, Object?>> checks;
  final Map<String, Object?> capabilities;
}

final class ExternalWorkerModelsSuccess extends ExternalWorkerRunOutcome {
  const ExternalWorkerModelsSuccess(this.models);
  final List<Map<String, Object?>> models;
}

final class ExternalWorkerRunFailure extends ExternalWorkerRunOutcome {
  const ExternalWorkerRunFailure({
    required this.code,
    required this.message,
    this.retryable = false,
    this.fromPlugin = false,
    this.stderrTail = '',
  });

  /// A `ExternalWorkerHostFailure` code, or a normalized plugin error code when
  /// [fromPlugin] is true.
  final String code;
  final String message;
  final bool retryable;
  final bool fromPlugin;
  final String stderrTail;
}

/// Starts and supervises External Worker processes: digest re-check, built
/// environment, resource limits and tree cleanup. MCP Worker runs go through
/// [McpWorkerRunner]; the MCP client drives the protocol.
class ExternalWorkerProcessHost {
  ExternalWorkerProcessHost({
    PlatformProcessSupervisor supervisor = const StandardProcessSupervisor(),
    this.resourceLimits = const ExternalWorkerResourceLimits(),
  }) : _supervisor = supervisor;

  final PlatformProcessSupervisor _supervisor;
  final ExternalWorkerResourceLimits resourceLimits;

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

  late final McpHost _mcp = McpHost(pluginHost: this);
  late final McpWorkerRunner _runner = McpWorkerRunner(_mcp);

  /// Stops every warm MCP Worker server. The Engine calls this when its input
  /// ends so no server process or idle timer keeps the Engine alive.
  Future<void> close() => _mcp.closeAll();

  /// Runs one execute, probe or model listing on an MCP Worker (ADR-028).
  /// [cancel] completes to request a cooperative cancel.
  Future<ExternalWorkerRunOutcome> run(
    ExternalWorkerLaunch launch,
    ExternalWorkerRunRequest request, {
    void Function(int? percentage, String message)? onProgress,
    void Function()? onWorkStarted,
    Future<void>? cancel,
  }) {
    final pins = launch.mcpToolPins;
    if (pins == null) {
      return Future.value(
        const ExternalWorkerRunFailure(
          code: ExternalWorkerHostFailure.protocolUnsupported,
          message: 'Only MCP Workers (kind: "mcp") are supported.',
        ),
      );
    }
    final spec = McpServerSpec(
      serverId: launch.pluginId,
      workspaceId: 'engine',
      launch: launch,
      requireWorkerProfile: true,
      pins: ToolPins(pins),
    );
    if (request.discoverModels) return _runner.models(spec);
    final probe = request.probeMode;
    if (probe != null) return _runner.probe(spec, probe);
    onWorkStarted?.call();
    return _runner.run(
      spec,
      request,
      cancel: cancel,
      workingDirectory: launch.workingDirectory,
      onProgress: onProgress,
    );
  }

  /// Opens a raw line-oriented connection to a verified artifact: digest
  /// re-check before spawn, built environment, no shell, and process-tree
  /// cleanup. The caller (the MCP client) drives the protocol itself.
  Future<ExternalWorkerConnection> connect(ExternalWorkerLaunch launch) async {
    final String digest;
    try {
      digest = await sha256OfFile(launch.executable);
    } on Object {
      throw const ExternalWorkerLaunchException(
        ExternalWorkerHostFailure.digestMismatch,
        'The plugin artifact could not be read.',
      );
    }
    if (digest != launch.artifactSha256) {
      throw const ExternalWorkerLaunchException(
        ExternalWorkerHostFailure.digestMismatch,
        'The plugin artifact does not match its pinned digest.',
      );
    }
    final quotaProblem = await resourceLimits.checkDataDirectory(
      launch.dataDirectory,
    );
    if (quotaProblem != null) {
      throw ExternalWorkerLaunchException(
        'plugin_resource_limit',
        quotaProblem,
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
      throw const ExternalWorkerLaunchException(
        ExternalWorkerHostFailure.crashed,
        'The plugin process could not be started.',
      );
    }
    return _HostConnection(
      process,
      _supervisor,
      launch.dataDirectory,
      resourceLimits,
    );
  }
}

class ExternalWorkerLaunchException implements Exception {
  const ExternalWorkerLaunchException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class _HostConnection implements ExternalWorkerConnection {
  _HostConnection(
    this._process,
    this._supervisor,
    String dataDirectory,
    ExternalWorkerResourceLimits limits,
  ) {
    _resources = ExternalWorkerResourceMonitor(
      process: _process,
      dataDirectory: dataDirectory,
      limits: limits,
      onViolation: (_) => unawaited(kill()),
    )..start();
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
  late final ExternalWorkerResourceMonitor _resources;
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
    _resources.stop();
    await _supervisor.terminateProcessTree(_process, force: true);
    await _subscription.cancel();
  }
}
