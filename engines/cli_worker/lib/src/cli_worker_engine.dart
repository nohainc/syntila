import 'execution_selection_snapshot.dart';
import 'worker_session.dart';
import 'model_discovery.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_runtime/src/cli_command_runner.dart';
import 'package:syntila_cli_worker_runtime/src/cli_environment_builder.dart';
import 'package:syntila_cli_worker_runtime/src/cli_executable_locator.dart';
import 'package:syntila_cli_worker_runtime/src/cli_streaming_runner.dart';
import 'package:syntila_cli_worker_runtime/src/worker_process_cleanup.dart';
import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart'
    show ProfileVersionProbe, SafeProviderDiagnostics;
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';

import 'engine_logger.dart';
import 'engine_session_store.dart';
import 'conversation_execution_router.dart';
import 'provider_activity_adapter.dart';

const _compiledEngineVersion = String.fromEnvironment(
  'ENGINE_VERSION',
  defaultValue: 'dev',
);

class EngineOptions {
  EngineOptions({
    required this.profilePath,
    required this.engineVersion,
    required this.statePath,
  });

  final String profilePath;
  final String engineVersion;
  final String statePath;

  static EngineOptions parse(List<String> arguments) {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index++) {
      final key = arguments[index];
      if (!const {
            '--profile',
            '--engine-version',
            '--state-directory',
          }.contains(key) ||
          values.containsKey(key) ||
          index + 1 >= arguments.length) {
        throw const FormatException(
          'expected --profile, --engine-version, and --state-directory options',
        );
      }
      values[key] = arguments[++index];
    }
    final profile = values['--profile'];
    final version = values['--engine-version'];
    final state = values['--state-directory'];
    if (profile == null ||
        version == null ||
        state == null ||
        !File(profile).isAbsolute ||
        !Directory(state).isAbsolute ||
        !_isSemver(version) ||
        (_compiledEngineVersion != 'dev' &&
            version != _compiledEngineVersion)) {
      throw const FormatException('Engine options are incomplete or invalid');
    }
    return EngineOptions(
      profilePath: profile,
      engineVersion: version,
      statePath: state,
    );
  }
}

/// Generic Protocol 4.0 process loop. Provider behavior comes from one admitted Profile.
class CliWorkerEngine {
  CliWorkerEngine({
    required this.options,
    CliExecutableLocator locator = const CliExecutableLocator(),
    CliCommandRunner commandRunner = const CliCommandRunner(
      maxOutputBytes: 64 * 1024,
    ),
    CliStreamingRunner? streamingRunner,
    EngineLogger logger = const EngineLogger(),
    this.providerStallLimit = const Duration(minutes: 60),
  }) : _locator = locator,
       _commandRunner = commandRunner,
       _streamingRunner =
           streamingRunner ??
           CliStreamingRunner(cleanup: const WorkerProcessCleanup()),
       _logger = logger;

  final EngineOptions options;

  /// A provider CLI that writes nothing and runs no child process for this
  /// long is considered stuck and stopped. Output, or a running command,
  /// keeps it alive up to the request's overall deadline.
  final Duration providerStallLimit;
  final CliExecutableLocator _locator;
  final CliCommandRunner _commandRunner;
  final CliStreamingRunner _streamingRunner;
  final EngineLogger _logger;
  late EngineProfile _profile;
  late EngineProfile _admittedProfile;
  late int _profileRevision;
  late final EngineSessionStore _sessions;
  String? _resolvedExecutable;
  String? _providerVersion;
  ProviderActivityAdapter? _providerActivityAdapter;
  DiscoveredModelCatalog? _modelCatalog;
  bool _discoveryUsedCache = false;
  bool _initialized = false;
  final _operationStarts = <String, Stopwatch>{};
  final _activitySequences = <String, int>{};
  int? _providerExitCode;

  Future<void> run({Stream<List<int>>? input, IOSink? output}) async {
    final profileFile = File(options.profilePath);
    final size = await profileFile.length();
    if (size < 1 || size > maxProfileBytes)
      throw const FormatException('Tool Profile payload is empty or oversized');
    final bytes = await profileFile.readAsBytes();
    _profile = EngineProfile.parse(bytes);
    _admittedProfile = _profile;
    _providerActivityAdapter = ProviderActivityAdapter.fromProfile(
      _profile.json,
    );
    if (!engineVersionCompatible(_profile, options.engineVersion)) {
      throw const FormatException(
        'Engine version is outside Profile compatibility',
      );
    }
    _sessions = EngineSessionStore(Directory(options.statePath));
    final lines = (input ?? stdin)
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final sink = output ?? stdout;
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final frame = decodeWorkerFrame(line);
        switch (frame) {
          case InitializeRequest():
            await _initialize(frame, sink);
          case ProbeRequest():
            await _probe(frame, sink);
          case UsageRequest():
            await _usage(frame, sink);
          case ExecuteRequest():
            await _execute(frame, sink);
          default:
            throw FormatException('unsupported request frame: ${frame.type}');
        }
      } on FormatException catch (error) {
        _logger.log(
          'warning',
          'engine.frame_rejected',
          context: {'errorCode': WorkerIssueCode.malformedFrame},
        );
        await _write(
          sink,
          WorkerErrorFrame(
            requestId: _requestIdFromLine(line),
            code: WorkerIssueCode.malformedFrame,
            message: error.message.length > 256
                ? 'Malformed protocol frame'
                : error.message,
          ),
        );
      } on Object {
        _logger.log(
          'error',
          'engine.request_failed',
          context: {'errorCode': WorkerIssueCode.workerInternalFailure},
        );
        await _write(
          sink,
          WorkerErrorFrame(
            requestId: _requestIdFromLine(line),
            code: WorkerIssueCode.workerInternalFailure,
            message: 'Engine request failed',
          ),
        );
      }
    }
  }

  Future<void> _initialize(InitializeRequest request, IOSink sink) async {
    if (request.workerTypeId != _admittedProfile.workerTypeId) {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.workerTypeMismatch,
          message: 'Logical Worker Type does not match the admitted Profile',
        ),
      );
      return;
    }
    if (request.expectedEngineVersion != options.engineVersion) {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.engineVersionMismatch,
          message: 'Engine version does not match Workspace admission',
        ),
      );
      return;
    }
    if (request.profileDefinitionId != _admittedProfile.definitionId ||
        request.profileDigest != _admittedProfile.digest) {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.profileIdentityMismatch,
          message: 'Engine Profile identity does not match Workspace admission',
        ),
      );
      return;
    }
    // Workspace supplies the immutable resolved revision. Older direct
    // Engine callers may still send an opaque Profile release token; retain
    // that input for protocol compatibility while using the Profile's
    // declared integer only as a local fallback.
    _profileRevision =
        int.tryParse(request.profileReleaseVersion) ??
        _admittedProfile.releaseVersion;
    _initialized = true;
    _logger.log(
      'info',
      'engine.initialize.completed',
      context: _diagnosticContext(
        requestId: request.requestId,
        probeStage: 'initialize',
      ),
    );
    await _write(
      sink,
      InitializeResult(
        protocolVersion: request.protocolVersion,
        requestId: request.requestId,
        workerTypeId: _admittedProfile.workerTypeId,
        engineVersion: options.engineVersion,
        profileDefinitionId: _admittedProfile.definitionId,
        profileReleaseVersion: _profileRevision.toString(),
        profileSchemaVersion: _admittedProfile.schemaVersion,
        // Kept on the wire for protocol compatibility; capability metadata is
        // no longer sourced from or enforced by Tool Profiles.
        capabilities: const [],
      ),
    );
  }

  /// Runs the Profile-declared usage command and returns its output verbatim.
  /// Syntila deliberately never interprets the text: each provider calculates
  /// usage differently, so the Profile owns the command and the UI shows it.
  Future<void> _usage(UsageRequest request, IOSink sink) async {
    if (!_initialized) return _write(sink, _notInitialized(request.requestId));
    final spec = _profile.usage;
    if (spec == null) {
      return _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.providerFailure,
          message: 'Profile does not define a usage command',
        ),
      );
    }
    try {
      final executable = await _resolveTool();
      final workingDirectory = Directory.current.path;
      final context = ProfileVersionProbe.buildContext(
        profile: _profile,
        workingDirectory: workingDirectory,
        homeDirectory: _hostHome ?? workingDirectory,
        workerStateDirectory: options.statePath,
      );
      final profileTimeoutMs = _int(spec['timeoutMs']);
      final timeoutMs = profileTimeoutMs < request.timeoutMs
          ? profileTimeoutMs
          : request.timeoutMs;
      final arguments = _stringList(
        spec['arguments'],
      ).map((argument) => _template(argument, context)).toList();
      final rpc = spec['jsonRpc'];
      final CliCommandResult result;
      if (rpc is Map) {
        // The Profile names the app-server method; the result is returned
        // as pretty-printed JSON without interpretation.
        final rpcResult = await readAppServerResult(
          executable: executable,
          arguments: arguments,
          environment: _environment(),
          workingDirectory: workingDirectory,
          method: _string(rpc['method']),
          framing: rpc['framing'] as String? ?? 'newline',
          timeout: Duration(milliseconds: timeoutMs),
        );
        result = CliCommandResult(
          exitCode: 0,
          stdout: '${const JsonEncoder.withIndent('  ').convert(rpcResult)}\n',
          stderr: '',
        );
      } else {
        result = await _commandRunner.run(
          executable,
          arguments,
          environment: _environment(),
          workingDirectory: workingDirectory,
          timeout: Duration(milliseconds: timeoutMs),
        );
      }
      const limit = WorkerProtocolLimits.maxUsageOutputChars;
      final out = _stripAnsi(result.stdout);
      final err = _stripAnsi(result.stderr);
      await _write(
        sink,
        UsageResult(
          requestId: request.requestId,
          output: out.length > limit ? out.substring(0, limit) : out,
          errorOutput: err.length > limit ? err.substring(0, limit) : err,
          exitCode: result.exitCode,
          truncated: out.length > limit || err.length > limit,
        ),
      );
    } on EngineProviderException catch (error) {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: error.issueCode,
          message: error.safeMessage,
        ),
      );
    } on ProcessException {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.providerToolUnavailable,
          message: 'Provider CLI could not be started.',
        ),
      );
    } on TimeoutException {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.deadlineExceeded,
          message: 'Provider usage command exceeded its deadline.',
        ),
      );
    } on Object {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.providerFailure,
          message: 'Provider usage command failed.',
        ),
      );
    }
  }

  Future<void> _probe(ProbeRequest request, IOSink sink) async {
    if (!_initialized) return _write(sink, _notInitialized(request.requestId));
    final timer = Stopwatch()..start();
    _operationStarts[request.requestId] = timer;
    Duration remaining({int? profileLimitMs}) {
      final remainingMs = request.timeoutMs - timer.elapsedMilliseconds;
      if (remainingMs <= 0) {
        throw TimeoutException('Worker probe exceeded its deadline');
      }
      return Duration(
        milliseconds: profileLimitMs == null || remainingMs < profileLimitMs
            ? remainingMs
            : profileLimitMs,
      );
    }

    final checks = <ProbeCheck>[];
    String? issue;
    try {
      final executable = await _resolveTool();
      final discovery = _map(_profile.providerTool['discovery']);
      final env = _environment();
      final workingDirectory = Directory.current.path;
      final versionContext = ProfileVersionProbe.buildContext(
        profile: _profile,
        workingDirectory: workingDirectory,
        homeDirectory: _hostHome ?? workingDirectory,
        workerStateDirectory: options.statePath,
      );
      final versionEnvironment = Map<String, String>.from(env);
      if (discovery['allowPathSearch'] != true) {
        versionEnvironment.remove('PATH');
      }
      final versionResult = await ProfileVersionProbe.run(
        profile: _profile,
        executable: executable,
        commandRunner: _commandRunner,
        environment: versionEnvironment,
        workingDirectory: workingDirectory,
        context: versionContext,
        deadline: remaining(),
      );
      final version = versionResult.version;
      if (versionResult.exitCode != 0 || version == null) {
        // The CLI must start and answer its version command; which version
        // it reports is informational only.
        throw const EngineProviderException(
          WorkerIssueCode.providerToolUnavailable,
          'Provider CLI did not report a version',
        );
      }
      _providerVersion = version;
      _profile = _admittedProfile.resolveForProviderVersion(version);
      _providerActivityAdapter = ProviderActivityAdapter.fromProfile(
        _profile.json,
      );
      checks.add(
        ProbeCheck(
          code: 'provider_tool_version',
          status: ProbeCheckStatus.passed,
          message: 'Provider CLI version $version detected.',
        ),
      );
      if (_profile.model['discovery'] is Map) {
        _modelCatalog = await _discoverModels(
          executable,
          env,
          version,
          refresh: true,
          timeout: remaining(profileLimitMs: 10000),
        );
        checks.add(
          ProbeCheck(
            code: 'model_discovery',
            status: _discoveryUsedCache
                ? ProbeCheckStatus.warning
                : ProbeCheckStatus.passed,
            message: _discoveryUsedCache
                ? 'Model refresh failed; last successful catalog retained.'
                : 'Provider model catalog discovered; listed models are not execution tests.',
          ),
        );
      }
      final passive = _map(_profile.probe['passive']);
      final commands = passive['checks'];
      if (commands is List) {
        for (final raw in commands) {
          final check = _map(raw);
          final result = await _commandRunner.run(
            executable,
            _stringList(
              check['arguments'],
            ).map((argument) => _template(argument, versionContext)).toList(),
            environment: env,
            workingDirectory: Directory.current.path,
            timeout: remaining(profileLimitMs: _int(check['timeoutMs'])),
          );
          final success = _intList(
            check['successExitCodes'],
          ).contains(result.exitCode);
          final id = _string(check['id']);
          checks.add(
            ProbeCheck(
              code: id.replaceAll('-', '_'),
              status: success
                  ? ProbeCheckStatus.passed
                  : ProbeCheckStatus.failed,
              message: success
                  ? 'Local provider check passed.'
                  : 'Local provider check failed.',
            ),
          );
          if (!success) issue ??= _string(check['failureIssueCode']);
        }
      }
      final configChecks = passive['configChecks'];
      if (configChecks is List) {
        for (final rawCheck in configChecks) {
          final outcome = await _runConfigCheck(_map(rawCheck));
          checks.add(outcome.check);
          if (outcome.issueCode != null) issue ??= outcome.issueCode;
        }
      }
      if (request.mode == WorkerProbeMode.live && issue == null) {
        final usageSpec = _profile.usage;
        if (usageSpec != null) {
          final profileTimeoutMs = _int(usageSpec['timeoutMs']);
          final liveTimeout = remaining(profileLimitMs: profileTimeoutMs);
          final workingDirectory = Directory.current.path;
          final usageContext = ProfileVersionProbe.buildContext(
            profile: _profile,
            workingDirectory: workingDirectory,
            homeDirectory: _hostHome ?? workingDirectory,
            workerStateDirectory: options.statePath,
          );
          final usageArguments = _stringList(
            usageSpec['arguments'],
          ).map((argument) => _template(argument, usageContext)).toList();
          final rpc = usageSpec['jsonRpc'];
          final CliCommandResult result;
          if (rpc is Map) {
            CliCommandResult rpcOutcome;
            try {
              final rpcResult = await readAppServerResult(
                executable: executable,
                arguments: usageArguments,
                environment: _environment(),
                workingDirectory: workingDirectory,
                method: _string(rpc['method']),
                framing: rpc['framing'] as String? ?? 'newline',
                timeout: liveTimeout,
              );
              rpcOutcome = CliCommandResult(
                exitCode: 0,
                stdout:
                    '${const JsonEncoder.withIndent('  ').convert(rpcResult)}\n',
                stderr: '',
              );
            } on FormatException catch (error) {
              // Surface the provider's JSON-RPC error (for example "Not
              // authenticated") instead of a generic probe failure.
              rpcOutcome = CliCommandResult(
                exitCode: 1,
                stdout: '',
                stderr: error.message,
              );
            }
            result = rpcOutcome;
          } else {
            result = await _commandRunner.run(
              executable,
              usageArguments,
              environment: _environment(),
              workingDirectory: workingDirectory,
              timeout: liveTimeout,
            );
          }
          // Live mode checks the provider account through the Profile's
          // usage command instead of calling a model, so a limit on one
          // model cannot fail the whole Worker. The command must succeed and
          // print something.
          final livePassed =
              result.exitCode == 0 && result.stdout.trim().isNotEmpty;
          checks.add(
            ProbeCheck(
              code: 'provider_live_execution',
              status: livePassed
                  ? ProbeCheckStatus.passed
                  : ProbeCheckStatus.failed,
              message: livePassed
                  ? 'Provider answered the usage command.'
                  : 'Provider usage command '
                        '${result.exitCode == 0 ? 'returned no output' : 'failed (exit ${result.exitCode})'}. '
                        'Arguments: ${usageArguments.join(' ')}. '
                        'Stderr: ${_liveStderrExcerpt(result.stderr)}',
            ),
          );
          if (!livePassed) {
            issue ??= WorkerIssueCode.providerFailure;
          }
        } else {
          // Live mode is the usage check; it never calls a model. A Profile
          // without a usage command cannot be live-tested.
          checks.add(
            ProbeCheck(
              code: 'provider_live_execution',
              status: ProbeCheckStatus.failed,
              message: 'This Tool Profile declares no usage command.',
            ),
          );
          issue ??= WorkerIssueCode.providerFailure;
        }
      } else if (request.mode == WorkerProbeMode.live && issue != null) {
        checks.add(
          ProbeCheck(
            code: 'provider_live_execution',
            status: ProbeCheckStatus.warning,
            message: 'Live check was skipped because passive readiness failed.',
          ),
        );
      }
    } on EngineProviderException catch (error) {
      issue = error.issueCode;
      checks.add(
        ProbeCheck(
          code: 'provider_tool',
          status: ProbeCheckStatus.failed,
          message: error.safeMessage,
        ),
      );
    } on ProcessException {
      issue = WorkerIssueCode.providerToolUnavailable;
      checks.add(
        ProbeCheck(
          code: 'provider_tool',
          status: ProbeCheckStatus.failed,
          message: 'Provider CLI could not be started.',
        ),
      );
    } on TimeoutException {
      issue = WorkerIssueCode.deadlineExceeded;
      checks.add(
        ProbeCheck(
          code: 'provider_tool',
          status: ProbeCheckStatus.failed,
          message: 'Provider CLI probe exceeded its deadline.',
        ),
      );
    } on Object {
      issue = WorkerIssueCode.providerFailure;
      checks.add(
        ProbeCheck(
          code: 'provider_tool',
          status: ProbeCheckStatus.failed,
          message: 'Provider CLI probe failed.',
        ),
      );
    }
    await _write(
      sink,
      ProbeResult(
        requestId: request.requestId,
        mode: request.mode,
        ready: issue == null,
        providerToolName: _string(_profile.providerTool['name']),
        providerToolVersion: _providerVersion,
        modelCatalog: _modelCatalog,
        checks: checks,
        issueCode: issue,
      ),
    );
  }

  /// Bounded single-line stderr excerpt for probe diagnostics. The protocol
  /// redacts credential-looking values when the check message is built.
  String _liveStderrExcerpt(String stderr) {
    final text = stderr.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return '(empty)';
    return text.length <= 300 ? text : '${text.substring(0, 300)}...';
  }

  Future<DiscoveredModelCatalog> _discoverModels(
    String executable,
    Map<String, String> env,
    String version, {
    bool refresh = false,
    Duration? timeout,
  }) async {
    final cache = ModelDiscoveryCache(options.statePath);
    _discoveryUsedCache = false;
    final cached = await cache.load(_admittedProfile.digest, version);
    if (!refresh && cached != null) return cached;
    final spec = _map(_profile.model['discovery']);
    try {
      final format = _string(spec['format']);
      final models = format == 'codex_app_server'
          ? await discoverCodexAppServerModels(
              executable: executable,
              arguments: _stringList(spec['arguments']),
              environment: env,
              workingDirectory: options.statePath,
              idPrefix: _string(spec['idPrefix']),
              timeout:
                  timeout ?? Duration(milliseconds: _int(spec['timeoutMs'])),
            )
          : format == 'copilot_sdk_rpc'
          ? await _discoverCopilotModels(
              executable,
              env,
              spec,
              timeout ?? Duration(milliseconds: _int(spec['timeoutMs'])),
            )
          : format == 'clap_possible_values' || format == 'indented_list'
          ? await _discoverClapModels(
              executable,
              env,
              spec,
              timeout ?? Duration(milliseconds: _int(spec['timeoutMs'])),
            )
          : await _discoverTsvModels(
              executable,
              env,
              spec,
              timeout ?? Duration(milliseconds: _int(spec['timeoutMs'])),
            );
      final catalog = DiscoveredModelCatalog(
        schemaVersion: 2,
        profileDigest: _admittedProfile.digest,
        providerToolVersion: version,
        discoveredAt: DateTime.now().toUtc().toIso8601String(),
        models: normalizeCombinedModels(
          models,
          _profile.model['selectionMapping'],
          version,
          effortVariants: spec['effortVariants'],
        ).map((model) => _restoreModelStatus(model, cached)),
      );
      await cache.save(catalog);
      return catalog;
    } on EngineProviderException {
      // A sign-in problem must reach the user; a stale list would hide it.
      rethrow;
    } on Object {
      // Retain the last successful list only for this exact Profile and CLI.
      if (cached != null) {
        _discoveryUsedCache = true;
        return cached.withStale(true);
      }
      rethrow;
    }
  }

  Future<List<DiscoveredModel>> _discoverTsvModels(
    String executable,
    Map<String, String> env,
    Map<String, Object?> spec,
    Duration timeout,
  ) async {
    final result = await _commandRunner.run(
      executable,
      _stringList(spec['arguments']),
      environment: env,
      workingDirectory: options.statePath,
      timeout: timeout,
    );
    if (result.exitCode != 0) {
      throw const FormatException('Model discovery failed');
    }
    return parseDiscoveredModels(result.stdout, _string(spec['idPrefix']));
  }

  Future<List<DiscoveredModel>> _discoverCopilotModels(
    String executable,
    Map<String, String> env,
    Map<String, Object?> spec,
    Duration timeout,
  ) async {
    try {
      return await discoverCopilotSdkModels(
        executable: executable,
        arguments: _stringList(spec['arguments']),
        environment: env,
        workingDirectory: options.statePath,
        idPrefix: _string(spec['idPrefix']),
        excludeIds: spec['excludeIds'] == null
            ? const {}
            : _stringList(spec['excludeIds']).toSet(),
        timeout: timeout,
      );
    } on ProviderNotAuthenticatedException catch (error) {
      throw EngineProviderException(
        WorkerIssueCode.providerAuthenticationRequired,
        error.message,
      );
    }
  }

  /// The CLI rejects the bare flag, so the exit code is expected to be
  /// non-zero; the list is read from stdout and stderr.
  Future<List<DiscoveredModel>> _discoverClapModels(
    String executable,
    Map<String, String> env,
    Map<String, Object?> spec,
    Duration timeout,
  ) async {
    final result = await _commandRunner.run(
      executable,
      _stringList(spec['arguments']),
      environment: env,
      workingDirectory: options.statePath,
      timeout: timeout,
    );
    // clap prints possible values on stderr; a model list is ordinary stdout,
    // and indented stderr diagnostics must not read as model IDs.
    final indented = _string(spec['format']) == 'indented_list';
    final parse = indented ? parseIndentedModelList : parseClapPossibleValues;
    final models = parse(
      indented ? '${result.stdout}' : '${result.stdout}\n${result.stderr}',
      _string(spec['idPrefix']),
      catalog: [
        for (final entry in _profile.model['catalog'] as List? ?? const [])
          if (entry is Map) Map<String, Object?>.from(entry),
      ],
      defaultEfforts: _profile.model['supportedReasoningEfforts'] == null
          ? const []
          : _stringList(_profile.model['supportedReasoningEfforts']),
      // Both lists are optional in the Profile schema.
      excludeIds: spec['excludeIds'] == null
          ? const {}
          : _stringList(spec['excludeIds']).toSet(),
    );
    final probe = spec['effortProbe'];
    if (probe is! Map) return models;
    // One bounded call per model; the CLI rejects the invalid effort and
    // lists that model's efforts before any model request is made.
    final arguments = _stringList(probe['arguments']);
    final probeTimeout = Duration(milliseconds: _int(probe['timeoutMs']));
    // At most 32 probes; any further models keep their Profile efforts.
    return Future.wait([
      for (final model in models.take(32))
        _commandRunner
            .run(
              executable,
              [
                for (final argument in arguments)
                  argument.replaceAll('{{model}}', model.id),
              ],
              environment: env,
              workingDirectory: options.statePath,
              timeout: probeTimeout,
            )
            .then(
              (result) =>
                  parseUseOneOfEfforts('${result.stdout}\n${result.stderr}'),
              onError: (Object _) => const <String>[],
            )
            .then(
              (efforts) => DiscoveredModel(
                id: model.id,
                name: model.name,
                supportedReasoningEfforts: efforts,
              ),
            ),
    ]).then((probed) => [...probed, ...models.skip(32)]);
  }

  DiscoveredModel _restoreModelStatus(
    DiscoveredModel model,
    DiscoveredModelCatalog? cached,
  ) {
    final prior = cached?.models
        .where((m) => m.id == model.id && m.nativeId == model.nativeId)
        .firstOrNull;
    final statuses = {
      for (final e in model.supportedReasoningEfforts)
        if (prior?.variantStatuses[e] != null) e: prior!.variantStatuses[e]!,
    };
    final efforts = model.supportedReasoningEfforts
        .where((e) => statuses[e] != 'unavailable')
        .toList();
    final mode = _profile.model['selectionMode'] as String? ?? 'separate';
    final aggregate = statuses.isEmpty
        ? null
        : efforts.isEmpty
        ? 'unavailable'
        : efforts.every((e) => statuses[e] == 'verified')
        ? 'verified'
        : 'listed';
    return DiscoveredModel(
      id: model.id,
      nativeId: model.nativeId,
      name: model.name,
      selectionMode: mode,
      variantStatuses: statuses,
      supportedReasoningEfforts: efforts,
      defaultReasoningEffort: efforts.contains(model.defaultReasoningEffort)
          ? model.defaultReasoningEffort
          : null,
      status:
          aggregate ??
          (prior != null &&
                  jsonEncode(prior.supportedReasoningEfforts) ==
                      jsonEncode(model.supportedReasoningEfforts) &&
                  prior.defaultReasoningEffort == model.defaultReasoningEffort
              ? prior.status
              : 'listed'),
    );
  }

  Future<void> _recordModelOutcome(
    String? modelId,
    String status, [
    String? effort,
  ]) async {
    final catalog = _modelCatalog;
    if (modelId == null || catalog == null) return;
    final current = catalog.models.where((m) => m.id == modelId).firstOrNull;
    if (current?.selectionMode == 'combined' &&
        current!.supportedReasoningEfforts.isNotEmpty) {
      final selected = effort ?? current.defaultReasoningEffort;
      if (selected == null) return;
      final statuses = {...current.variantStatuses, selected: status};
      final family = parseModelSelectionMapping(
        _profile.model['selectionMapping'],
      ).where((m) => m.id == modelId).firstOrNull;
      final all = {...current.supportedReasoningEfforts, ...statuses.keys};
      final available = all.where((e) => statuses[e] != 'unavailable').toList();
      final replacement = DiscoveredModel(
        id: current.id,
        name: current.name,
        nativeId: current.nativeId,
        selectionMode: 'combined',
        variantStatuses: statuses,
        status: available.isEmpty
            ? 'unavailable'
            : available.every((e) => statuses[e] == 'verified')
            ? 'verified'
            : 'listed',
        supportedReasoningEfforts: available,
        defaultReasoningEffort: available.contains(family?.defaultEffort)
            ? family?.defaultEffort
            : null,
      );
      _modelCatalog = DiscoveredModelCatalog(
        schemaVersion: 2,
        stale: catalog.stale,
        profileDigest: catalog.profileDigest,
        providerToolVersion: catalog.providerToolVersion,
        discoveredAt: catalog.discoveredAt,
        models: catalog.models.map((m) => m.id == modelId ? replacement : m),
      );
      await ModelDiscoveryCache(options.statePath).save(_modelCatalog!);
      return;
    }
    _modelCatalog = DiscoveredModelCatalog(
      schemaVersion: catalog.schemaVersion,
      stale: catalog.stale,
      profileDigest: catalog.profileDigest,
      providerToolVersion: catalog.providerToolVersion,
      discoveredAt: catalog.discoveredAt,
      models: catalog.models.map(
        (m) => m.id == modelId
            ? DiscoveredModel(
                id: m.id,
                nativeId: m.nativeId,
                selectionMode: m.selectionMode,
                name: m.name,
                status: status,
                supportedReasoningEfforts: m.supportedReasoningEfforts,
                defaultReasoningEffort: m.defaultReasoningEffort,
              )
            : m,
      ),
    );
    await ModelDiscoveryCache(options.statePath).save(_modelCatalog!);
  }

  /// Loads the model catalog an assignment is validated against. Execution
  /// sends the prompt straight to the CLI: it reads the catalog saved by
  /// Workspace readiness (a file read, so a refreshed catalog is picked up)
  /// and runs the version and discovery commands only when no catalog exists
  /// for this Profile at all. Keeping the CLI unchanged between readiness
  /// checks is the user's responsibility.
  Future<void> _ensureModelCatalog() async {
    if (_profile.model['discovery'] is! Map) return;
    final cached = await ModelDiscoveryCache(
      options.statePath,
    ).loadForProfile(_admittedProfile.digest);
    if (cached != null) {
      _modelCatalog = cached;
      _providerVersion ??= cached.providerToolVersion;
      return;
    }
    final executable = await _resolveTool();
    final context = ProfileVersionProbe.buildContext(
      profile: _profile,
      workingDirectory: options.statePath,
      homeDirectory: _hostHome ?? options.statePath,
      workerStateDirectory: options.statePath,
    );
    final result = await ProfileVersionProbe.run(
      profile: _profile,
      executable: executable,
      commandRunner: _commandRunner,
      environment: _environment(),
      workingDirectory: options.statePath,
      context: context,
      deadline: const Duration(seconds: 10),
    );
    if (result.version == null) {
      throw const FormatException('Provider CLI version could not be read');
    }
    _providerVersion = result.version;
    _modelCatalog = await _discoverModels(
      executable,
      _environment(),
      result.version!,
    );
  }

  Future<_ProbeOutcome> _runConfigCheck(Map<String, Object?> spec) async {
    final id = _string(spec['id']).replaceAll('-', '_');
    final relative = _string(spec['relativePath']);
    if (spec['root'] != 'home' ||
        relative.startsWith('/') ||
        relative
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..') ||
        !RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(relative)) {
      throw const FormatException('unsafe Profile config check path');
    }
    final providerEnvironment = _environment();
    final home =
        providerEnvironment['HOME'] ?? providerEnvironment['USERPROFILE'];
    if (home == null || home.isEmpty) {
      return _configOutcome(
        id,
        _string(spec['onMissing']),
        WorkerIssueCode.providerFailure,
      );
    }
    final file = File(
      '$home${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}',
    );
    if (!await file.exists()) {
      return _configOutcome(
        id,
        _string(spec['onMissing']),
        WorkerIssueCode.providerFailure,
      );
    }
    final maxBytes = _int(spec['maxBytes']);
    if (maxBytes < 1 ||
        maxBytes > 64 * 1024 ||
        await file.length() > maxBytes) {
      return _configOutcome(
        id,
        _string(spec['onInvalid']),
        WorkerIssueCode.providerFailure,
      );
    }
    final homeRealPath = await Directory(home).resolveSymbolicLinks();
    final fileRealPath = await file.resolveSymbolicLinks();
    if (!fileRealPath.startsWith('$homeRealPath${Platform.pathSeparator}')) {
      throw const FormatException(
        'Profile config check escaped the home boundary',
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on Object {
      return _configOutcome(
        id,
        _string(spec['onInvalid']),
        WorkerIssueCode.providerFailure,
      );
    }
    final rules = _list(spec['rules']);
    for (final raw in rules) {
      final rule = _map(raw);
      if (!_matches(decoded, rule['when'])) continue;
      final required = rule['requiredEnvironmentAny'];
      if (required is List &&
          !required.any(
            (key) => providerEnvironment[key]?.isNotEmpty == true,
          )) {
        final missing = rule['whenEnvironmentMissing'];
        if (missing is Map) {
          final missingMap = _map(missing);
          return _configOutcome(
            id,
            _string(missingMap['result']),
            missingMap['issueCode'] is String
                ? missingMap['issueCode'] as String
                : WorkerIssueCode.providerAuthenticationRequired,
          );
        }
      }
      return _configOutcome(
        id,
        _string(rule['result']),
        rule['issueCode'] is String
            ? rule['issueCode'] as String
            : WorkerIssueCode.providerAuthenticationRequired,
      );
    }
    final noMatch = _map(spec['onNoMatch']);
    return _configOutcome(
      id,
      _string(noMatch['result']),
      noMatch['issueCode'] is String
          ? noMatch['issueCode'] as String
          : WorkerIssueCode.providerAuthenticationRequired,
    );
  }

  _ProbeOutcome _configOutcome(String id, String status, String issue) {
    final parsed = switch (status) {
      'passed' => ProbeCheckStatus.passed,
      'warning' => ProbeCheckStatus.warning,
      'failed' => ProbeCheckStatus.failed,
      _ => throw const FormatException('invalid config check status'),
    };
    return _ProbeOutcome(
      ProbeCheck(
        code: id,
        status: parsed,
        message: parsed == ProbeCheckStatus.passed
            ? 'Local configuration check passed.'
            : parsed == ProbeCheckStatus.warning
            ? 'Local configuration needs attention.'
            : 'Local configuration check failed.',
      ),
      parsed == ProbeCheckStatus.failed ||
              (parsed == ProbeCheckStatus.warning &&
                  issue == WorkerIssueCode.providerAuthenticationRequired)
          ? issue
          : null,
    );
  }

  WorkerErrorFrame _executionError(
    ExecuteRequest request, {
    required String code,
    required String message,
    required String stage,
    Object? detail,
    bool providerStarted = false,
    bool recovered = false,
  }) {
    _logger.log(
      'error',
      'engine.execution.failed',
      operation: 'execute',
      stage: stage,
      context: _diagnosticContext(
        requestId: request.requestId,
        assignmentId: request.assignmentId,
        errorCode: code,
        failureLayer: _failureLayer(code),
      ),
    );
    return WorkerErrorFrame(
      requestId: request.requestId,
      assignmentId: request.assignmentId,
      code: code,
      message: message,
      diagnostics: _executionDiagnostic(
        stage: stage,
        code: code,
        detail: detail,
        providerStarted: providerStarted,
        recovered: recovered,
      ),
    );
  }

  String? _executionDiagnostic({
    required String stage,
    required String code,
    Object? detail,
    required bool providerStarted,
    required bool recovered,
  }) {
    final safeDetail = detail == null
        ? null
        : SafeProviderDiagnostics.safeFailureDetail(detail, maxLength: 768);
    return SafeProviderDiagnostics.safeFailureDetail(
      jsonEncode({
        'schemaVersion': 1,
        'component': 'cli_worker_engine',
        'stage': stage,
        'errorCode': code,
        'providerStarted': providerStarted,
        'recovered': recovered,
        if (_providerExitCode != null) 'processExitCode': _providerExitCode,
        if (safeDetail != null) 'detail': safeDetail,
      }),
      maxLength: WorkerProtocolLimits.maxDiagnosticLength,
    );
  }

  String? _safeProviderStderr(String stderr) {
    if (stderr.trim().isEmpty) return null;
    final lines = stderr
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .take(16)
        .map(SafeProviderDiagnostics.parseStderrLine)
        .toList(growable: false);
    return lines.isEmpty ? null : jsonEncode(lines);
  }

  bool _canReconstructCorruptSession(String message) =>
      message == 'Engine session state is invalid' ||
      message == 'Missing local Worker Session' ||
      message == 'Engine session state exceeds its limit' ||
      message == staleSessionAheadOfCloudMessage;

  Future<void> _execute(ExecuteRequest request, IOSink sink) async {
    if (!_initialized ||
        request.sessionPolicy != WorkerSessionPolicy.durableSession) {
      return _executeSession(request, sink);
    }
    EngineSessionLease lease;
    try {
      lease = await _sessions.acquireExecution(
        sessionKey: request.sessionKey!,
        workerTypeId: _profile.workerTypeId,
        profileDefinitionId: _profile.definitionId,
        providerToolIdentity: _string(_profile.providerTool['name']),
      );
    } on EngineSessionBusy {
      return _write(
        sink,
        _executionError(
          request,
          code: WorkerIssueCode.providerUnavailable,
          message: 'This Worker session is already executing a request',
          stage: 'session_lock_acquisition',
          detail: 'The durable Worker Session is already locked',
        ),
      );
    }
    try {
      await _executeSession(request, sink);
    } finally {
      await lease.release();
    }
  }

  Future<void> _executeSession(ExecuteRequest request, IOSink sink) async {
    _operationStarts[request.requestId] = Stopwatch()..start();
    _providerExitCode = null;
    if (!_initialized)
      return _write(
        sink,
        _executionError(
          request,
          code: WorkerIssueCode.workerInternalFailure,
          message: 'Engine must complete initialize before this request',
          stage: 'engine_initialization',
        ),
      );
    await _emitActivity(
      sink,
      requestId: request.requestId,
      assignmentId: request.assignmentId,
      eventType: 'execution.started',
      status: 'running',
      title: 'Execution started',
    );
    // Read/write policy is resolved by Cloud and carried in the assignment.
    // Profile capability metadata is legacy and must not gate execution.
    final execution = _profile.execution;
    final sessionPolicy =
        request.sessionPolicy == WorkerSessionPolicy.durableSession
        ? 'durable'
        : 'stateless';
    final sessionProfile = _profile.session;
    try {
      await _ensureModelCatalog();
    } on Object catch (error) {
      return _write(
        sink,
        _executionError(
          request,
          code: WorkerIssueCode.providerFailure,
          message: 'Provider model catalog could not be loaded',
          stage: 'model_catalog_validation',
          detail: error,
        ),
      );
    }
    if (_modelCatalog?.stale == true ||
        (request.catalogRevision != null &&
            request.catalogRevision != _modelCatalog?.catalogRevision)) {
      return _write(
        sink,
        _executionError(
          request,
          code: WorkerIssueCode.modelNotSupported,
          message:
              'Execution catalog changed or is stale; refresh and revalidate the selection',
          stage: 'model_catalog_validation',
          detail: 'The selected model catalog revision is stale or mismatched',
        ),
      );
    }
    if (request.model != null) {
      final model = _profile.model;
      final allowlist = model['allowlist'];
      if ((model['discovery'] is Map &&
              !(_modelCatalog?.models.any(
                    (m) => m.id == request.model && m.status != 'unavailable',
                  ) ??
                  false)) ||
          model['supported'] != true ||
          (model['unknownModelPolicy'] == 'profile_allowlist' &&
              (allowlist is! List || !allowlist.contains(request.model)))) {
        return _write(
          sink,
          _executionError(
            request,
            code: WorkerIssueCode.modelNotSupported,
            message: 'Requested model is not supported by this Tool Profile',
            stage: 'model_validation',
            detail: 'Requested model was rejected by the admitted Profile',
          ),
        );
      }
    }
    final executionOptions = ProfileExecutionOptions(_profile.model);
    final dynamicModel = _profile.model['discovery'] is Map;
    final discovered = request.model == null
        ? null
        : _modelCatalog?.models
              .where((model) => model.id == request.model)
              .firstOrNull;
    final effortSupported = dynamicModel
        ? request.reasoningEffort == null ||
              (executionOptions.declaration['effortSupported'] != false &&
                  (discovered?.selectionMode == 'combined' ||
                      jsonEncode([
                        execution['arguments'],
                        execution['stdin'],
                        _profile.model['arguments'],
                      ]).contains('{{reasoningEffort}}')) &&
                  (discovered?.supportedReasoningEfforts.contains(
                        request.reasoningEffort!,
                      ) ??
                      false))
        : executionOptions.acceptsEffort(
            request.model,
            request.reasoningEffort,
          );
    if (!effortSupported ||
        (request.model != null &&
            discovered?.selectionMode == 'combined' &&
            discovered!.supportedReasoningEfforts.isNotEmpty &&
            request.reasoningEffort == null &&
            discovered.defaultReasoningEffort == null)) {
      return _write(
        sink,
        _executionError(
          request,
          code: WorkerIssueCode.modelNotSupported,
          message:
              'Requested effort is not supported by this model and Tool Profile',
          stage: 'model_validation',
          detail:
              'Requested reasoning effort was rejected by the admitted Profile',
        ),
      );
    }
    if (sessionPolicy == 'durable' && sessionProfile['supported'] != true) {
      return _write(
        sink,
        _executionError(
          request,
          code: WorkerIssueCode.sessionResumeFailed,
          message: 'This Tool Profile does not support durable sessions',
          stage: 'session_capability_validation',
          detail: 'The admitted Tool Profile does not support durable sessions',
        ),
      );
    }
    final providerTool = _profile.providerTool;
    final providerToolIdentity = _string(providerTool['name']);
    final compatibleSessionFormats = _list(
      sessionProfile['compatibleFormatIds'],
    ).cast<String>();
    String? priorSession;
    WorkerSession? storedSession;
    try {
      priorSession = request.sessionKey == null
          ? null
          : await _sessions.read(
              sessionKey: request.sessionKey!,
              workerTypeId: _profile.workerTypeId,
              profileDefinitionId: _profile.definitionId,
              providerToolIdentity: providerToolIdentity,
              compatibleFormatIds: compatibleSessionFormats,
              workerSession: request.workerSession,
              modelSwitchSupported: executionOptions.modelSwitchSupported,
              requestedModelId: request.model,
              requestedEffort: request.reasoningEffort,
              effortChangesNativeModel: discovered?.selectionMode == 'combined',
              allowModelReconstruction:
                  request.workerSession?.bootstrap != null,
              allowContextSynchronization:
                  request.workerSession?.bootstrap?.turnRevision != null,
              executionPolicy: request.executionPolicy.wireValue,
              executionPolicyBound:
                  sessionProfile['executionPolicyBound'] == true,
              onSessionRead: (value) => storedSession = value,
            );
    } on FormatException catch (error) {
      final bootstrap = request.workerSession?.bootstrap;
      // A turn with no prior canonical context (base revision 0) needs no
      // bootstrap to start a fresh native session after quarantine.
      final canRebuild =
          bootstrap != null ||
          (request.workerSession?.baseContextRevision ?? 0) == 0;
      if (canRebuild && _canReconstructCorruptSession(error.message)) {
        final quarantined = await _sessions.quarantine(
          sessionKey: request.sessionKey!,
          workerTypeId: _profile.workerTypeId,
          profileDefinitionId: _profile.definitionId,
          providerToolIdentity: providerToolIdentity,
        );
        _logger.log(
          'warning',
          'engine.session.recovery_required',
          operation: 'execute',
          stage: 'session_lookup',
          context: {
            ..._diagnosticContext(
              requestId: request.requestId,
              assignmentId: request.assignmentId,
              errorCode: WorkerIssueCode.sessionResumeFailed,
            ),
            'recovered': quarantined,
          },
        );
        priorSession = null;
        storedSession = null;
        if (!quarantined) {
          return _write(
            sink,
            _executionError(
              request,
              code: WorkerIssueCode.sessionResumeFailed,
              message: error.message,
              stage: 'session_recovery',
              detail: 'Corrupt local session state could not be quarantined',
            ),
          );
        }
      } else {
        return _write(
          sink,
          _executionError(
            request,
            code: WorkerIssueCode.sessionResumeFailed,
            message: error.message,
            stage: 'session_lookup',
            detail: error.message,
          ),
        );
      }
    }
    const router = ConversationExecutionRouter();
    late final ConversationExecutionPlan route;
    try {
      route = router.prepare(
        request,
        nativeSessionId: priorSession,
        storedSession: storedSession,
      );
    } on FormatException catch (error) {
      return _write(
        sink,
        _executionError(
          request,
          code: WorkerIssueCode.sessionResumeFailed,
          message: error.message,
          stage: 'conversation_routing',
          detail: error.message,
        ),
      );
    }
    final context = _context(request, priorSession);
    context['prompt'] = route.prompt;
    final selectionStore = ExecutionSelectionSnapshotStore(options.statePath);
    try {
      await selectionStore.write(request.requestId, {
        'schemaVersion': 1,
        'assignmentId': request.assignmentId,
        'invocationId': request.requestId,
        'workerTypeId': _admittedProfile.workerTypeId,
        'modelId': request.model,
        'modelName': discovered?.name ?? request.model,
        'effort': request.reasoningEffort,
        'resolvedNativeModelId': context['model'],
        'resolvedNativeEffort': context['reasoningEffort'],
        'profileReleaseVersion': _profileRevision,
        'profileDigest': _admittedProfile.digest,
        'providerToolVersion': _providerVersion,
        'catalogRevision': _modelCatalog?.catalogRevision,
      });
    } on Object catch (error) {
      return _write(
        sink,
        _executionError(
          request,
          code: WorkerIssueCode.workerInternalFailure,
          message: 'Engine could not persist the execution selection',
          stage: 'execution_selection_snapshot',
          detail: error,
        ),
      );
    }
    final bootstrap = route.bootstrap;

    if (request.workerSession != null) {
      _logger.log(
        'info',
        'engine.context.selected',
        context: {
          ..._diagnosticContext(
            requestId: request.requestId,
            assignmentId: request.assignmentId,
          ),
          'conversationRoute': route.action.name,
          'conversationId': request.workerSession!.conversationId,
          'workerSessionId': request.workerSession!.id,
          'baseContextRevision': request.workerSession!.baseContextRevision,
          if (storedSession != null)
            'synchronizedContextRevision':
                storedSession!.synchronizedContextRevision,
          if (storedSession != null)
            'synchronizedHistorySequence':
                storedSession!.synchronizedHistorySequence,
          if (bootstrap != null)
            'targetContextRevision':
                bootstrap.turnRevision ?? bootstrap.contextRevision,
          if (bootstrap != null) 'throughSequence': bootstrap.throughSequence,
        },
      );
    }

    final executionClock = Stopwatch()..start();
    var reconstructed = false;
    var emptyRetried = false;
    var providerStarted = false;
    var acceptingProviderEvents = true;
    try {
      final executable = await _resolveTool();
      if (request.compactContext) {
        final failure = await _compactNativeSession(
          request,
          executable,
          execution,
          context,
          priorSession,
          remainingMs: request.timeoutMs - executionClock.elapsedMilliseconds,
        );
        if (failure != null) {
          await _write(
            sink,
            _executionError(
              request,
              code: WorkerIssueCode.contextLimitExceeded,
              message: failure,
              stage: 'context_compaction',
              detail: failure,
            ),
          );
          return;
        }
      }
      while (true) {
        acceptingProviderEvents = true;
        final remainingMs =
            request.timeoutMs - executionClock.elapsedMilliseconds;
        if (remainingMs <= 0)
          throw TimeoutException('Execution deadline reached');
        final args = _expandArguments(
          _list(execution['arguments']),
          context,
          additionalDirectories: request.additionalDirectories,
        );
        final stdinText = _expandStdin(_map(execution['stdin']), context);
        final eventProgress = <String>{};
        var toolSeen = false;
        final stdout = StringBuffer();
        var stdoutBytes = 0;
        final result = await _streamingRunner.run(
          executable,
          args,
          environment: _environment(context),
          workingDirectory: context['workingDirectory']!,
          stdinText: stdinText,
          timeout: Duration(milliseconds: remainingMs),
          // The step limit is a generous hard cap. A CLI that is silent and
          // has nothing running is stopped sooner; one that is running a
          // command is left alone.
          stallLimit: providerStallLimit,
          onStarted: () {
            providerStarted = true;
            return _write(
              sink,
              WorkerProgress(
                requestId: request.requestId,
                assignmentId: request.assignmentId,
                percentage: 0,
                message: workerProviderExecutionStartedMessage,
              ),
            );
          },
          onStdoutLine: (line) async {
            if (!acceptingProviderEvents) return;
            stdoutBytes += utf8.encode(line).length + 1;
            if (stdoutBytes > 4 * 1024 * 1024) {
              throw const FormatException(
                'provider output exceeds Engine limit',
              );
            }
            stdout.writeln(line);
            for (final activity in _activitiesForLine(line, request)) {
              if (activity.eventType.startsWith('tool.')) toolSeen = true;
              await _write(sink, activity);
            }
            for (final progress in _progressActivitiesForLine(
              line,
              request,
              execution,
            )) {
              final key = '${progress.$1}:${progress.$2}';
              if (eventProgress.add(key)) {
                await _write(sink, progress.$3);
              }
            }
          },
        );
        _providerExitCode = result.exitCode;
        acceptingProviderEvents = false;
        final interpreted = _interpret(
          stdout.toString(),
          result.stderr,
          result.exitCode,
          execution,
          priorSession: priorSession,
          durable: request.sessionPolicy == WorkerSessionPolicy.durableSession,
        );
        if (_string(_map(execution['output'])['mode']) == 'jsonl' &&
            !interpreted.terminalObserved) {
          _logger.log(
            'warning',
            'engine.assignment.missing_terminal_event',
            context: _diagnosticContext(
              requestId: request.requestId,
              assignmentId: request.assignmentId,
              errorCode: 'missing_terminal_event',
              failureLayer: 'provider_tool',
              processExitCode: result.exitCode,
            ),
          );
        }
        if (interpreted.emptyResponse && !emptyRetried && !toolSeen) {
          // The provider said "success" but answered with nothing, and it did
          // not touch anything: running it once more is safe. A second empty
          // answer is reported as such below.
          emptyRetried = true;
          _logger.log(
            'warning',
            'engine.assignment.empty_response_retry',
            context: _diagnosticContext(
              requestId: request.requestId,
              assignmentId: request.assignmentId,
              errorCode: 'empty_provider_response',
              failureLayer: 'provider_tool',
              processExitCode: result.exitCode,
            ),
          );
          continue;
        }
        // A resumed provider conversation can get stuck answering nothing
        // (seen with long Gemini threads). After the plain retry also came
        // back empty, rebuild the conversation from Syntila's own history
        // exactly as for an unavailable session.
        final emptyAfterRetry =
            interpreted.emptyResponse && emptyRetried && !toolSeen;
        if (((interpreted.nativeSessionUnavailable &&
                    result.exitCode != 0 &&
                    eventProgress.isEmpty) ||
                emptyAfterRetry) &&
            priorSession != null &&
            !reconstructed) {
          // Validate the replacement prompt before invalidating any local state.
          final restoredPrompt =
              bootstrap == null || request.workerSession == null
              ? null
              : router.prepare(request, reconstruct: true).prompt;
          final invalidated = await _sessions.invalidate(
            sessionKey: request.sessionKey!,
            workerTypeId: _profile.workerTypeId,
            profileDefinitionId: _profile.definitionId,
            providerToolIdentity: providerToolIdentity,
            expectedNativeSessionId: priorSession,
          );
          if (invalidated) {
            _logger.log(
              'warning',
              'engine.session.invalidated',
              context: _diagnosticContext(
                requestId: request.requestId,
                assignmentId: request.assignmentId,
                errorCode: WorkerIssueCode.sessionResumeFailed,
              ),
            );
          }
          if (invalidated && restoredPrompt != null) {
            _logger.log(
              'warning',
              'engine.session.reconstructing',
              context: _diagnosticContext(
                requestId: request.requestId,
                assignmentId: request.assignmentId,
                errorCode: WorkerIssueCode.sessionResumeFailed,
              ),
            );
            reconstructed = true;
            priorSession = null;
            context.remove('sessionId');
            context['prompt'] = restoredPrompt;
            continue;
          }
        }
        if (interpreted.issueCode == WorkerIssueCode.modelNotSupported) {
          await _recordModelOutcome(
            request.model,
            'unavailable',
            request.reasoningEffort,
          );
        }
        if (interpreted.issueCode != null || result.exitCode != 0) {
          await selectionStore.write(request.requestId, {
            'schemaVersion': 1,
            'assignmentId': request.assignmentId,
            'status': 'failed',
            'providerExitCode': result.exitCode,
            'acceptedModelId': null,
            'acceptedEffort': null,
            'selectionObservation': 'unavailable',
          }, completion: true);
          final failureDetail = [
            if (_safeProviderStderr(result.stderr) case final stderr?) stderr,
            if (interpreted.reason case final reason?)
              'interpretation: $reason',
          ].join(' | ');
          final failureMessage = switch (interpreted.issueCode) {
            WorkerIssueCode.quotaExhausted =>
              'The provider\'s usage limit has been reached.',
            WorkerIssueCode.contextLimitExceeded =>
              'The conversation no longer fits the model\'s context window.',
            _ =>
              interpreted.emptyResponse
                  ? (toolSeen
                        ? 'The provider ran a tool and then stopped without an answer. Please retry.'
                        : 'The provider returned an empty answer${emptyRetried ? ' repeatedly' : ''}. Please retry.')
                  : 'Provider CLI execution failed',
          };
          await _write(
            sink,
            _executionError(
              request,
              code: interpreted.issueCode ?? WorkerIssueCode.providerFailure,
              message: failureMessage,
              stage: 'provider_execution',
              detail: failureDetail.isEmpty ? null : failureDetail,
              providerStarted: providerStarted,
            ),
          );
          return;
        }
        await _recordModelOutcome(
          request.model,
          'verified',
          request.reasoningEffort,
        );
        final sessionId = interpreted.sessionId;
        if (request.sessionPolicy == WorkerSessionPolicy.durableSession) {
          if (sessionId == null || sessionId.isEmpty) {
            await _write(
              sink,
              _executionError(
                request,
                code: WorkerIssueCode.providerFailure,
                message:
                    'Provider did not return the required durable session identity',
                stage: 'session_persistence',
                detail:
                    'Provider output did not contain a durable session identity',
                providerStarted: providerStarted,
              ),
            );
            return;
          }
          try {
            await _sessions.write(
              sessionKey: request.sessionKey!,
              workerTypeId: _profile.workerTypeId,
              profileDefinitionId: _profile.definitionId,
              providerToolIdentity: providerToolIdentity,
              profileReleaseVersion: _profileRevision,
              sessionFormatId: _string(sessionProfile['formatId']),
              sessionId: sessionId,
              workerSession: request.workerSession,
              modelId: request.model,
              effort: request.reasoningEffort,
              synchronizedContextRevision:
                  bootstrap?.turnRevision ?? bootstrap?.contextRevision,
              synchronizedHistorySequence: bootstrap?.throughSequence,
              executionPolicy: request.executionPolicy.wireValue,
            );
          } on Object catch (error) {
            await _write(
              sink,
              _executionError(
                request,
                code: WorkerIssueCode.workerInternalFailure,
                message: 'Engine could not persist the Worker Session',
                stage: 'session_persistence',
                detail: error,
                providerStarted: providerStarted,
              ),
            );
            return;
          }
        }
        if (request.workerSession != null) {
          _logger.log(
            'info',
            'engine.context.synchronized',
            context: {
              ..._diagnosticContext(
                requestId: request.requestId,
                assignmentId: request.assignmentId,
              ),
              'conversationId': request.workerSession!.conversationId,
              'workerSessionId': request.workerSession!.id,
              'baseContextRevision': request.workerSession!.baseContextRevision,
              'synchronizedContextRevision':
                  bootstrap?.turnRevision ??
                  bootstrap?.contextRevision ??
                  storedSession?.synchronizedContextRevision ??
                  0,
              'synchronizedHistorySequence':
                  bootstrap?.throughSequence ??
                  storedSession?.synchronizedHistorySequence ??
                  0,
            },
          );
        }
        if (reconstructed) {
          _logger.log(
            'info',
            'engine.session.reconstructed',
            context: _diagnosticContext(
              requestId: request.requestId,
              assignmentId: request.assignmentId,
            ),
          );
        }
        await selectionStore.write(request.requestId, {
          'schemaVersion': 1,
          'assignmentId': request.assignmentId,
          'status': 'completed',
          'providerExitCode': result.exitCode,
          // Current signed output contracts do not attest the actual model/effort.
          'acceptedModelId': null,
          'acceptedEffort': null,
          'selectionObservation': 'unavailable',
        }, completion: true);
        await _write(
          sink,
          WorkerResult(
            requestId: request.requestId,
            assignmentId: request.assignmentId,
            output: interpreted.finalText ?? '',
          ),
        );
        return;
      }
    } on TimeoutException catch (error) {
      acceptingProviderEvents = false;
      await _write(
        sink,
        _executionError(
          request,
          code: WorkerIssueCode.deadlineExceeded,
          message: 'Provider CLI execution exceeded its deadline',
          stage: providerStarted
              ? 'provider_execution'
              : 'provider_process_launch',
          detail: error,
          providerStarted: providerStarted,
        ),
      );
    } on ProcessException catch (error) {
      acceptingProviderEvents = false;
      await _write(
        sink,
        _executionError(
          request,
          code: WorkerIssueCode.providerToolUnavailable,
          message: 'Provider CLI could not be started',
          stage: 'provider_process_launch',
          detail: error,
          providerStarted: providerStarted,
        ),
      );
    } on Object catch (error) {
      acceptingProviderEvents = false;
      await _write(
        sink,
        _executionError(
          request,
          code: WorkerIssueCode.providerFailure,
          message: 'Provider CLI execution failed',
          stage: providerStarted
              ? 'provider_execution'
              : 'provider_process_launch',
          detail: error,
          providerStarted: providerStarted,
        ),
      );
    }
  }

  /// Runs the Profile's compaction prompt against the resumed native session,
  /// so the step prompt that follows fits again. Returns why it failed, or
  /// null once the provider confirmed the same session without an error.
  Future<String?> _compactNativeSession(
    ExecuteRequest request,
    String executable,
    Map<String, Object?> execution,
    Map<String, String> context,
    String? priorSession, {
    required int remainingMs,
  }) async {
    final compaction = _profile.context['compaction'];
    if (compaction is! Map) {
      return 'This Worker cannot compact its context. Clear AI History and retry.';
    }
    if (priorSession == null) {
      return 'There is no Worker session to compact. Clear AI History and retry.';
    }
    if (remainingMs <= 0) throw TimeoutException('Execution deadline reached');
    final compactionContext = {
      ...context,
      'prompt': _string(compaction['prompt']),
    };
    final arguments = compaction['arguments'] is List
        ? _list(compaction['arguments'])
        : _list(execution['arguments']);
    final stdout = StringBuffer();
    final result = await _streamingRunner.run(
      executable,
      _expandArguments(
        arguments,
        compactionContext,
        additionalDirectories: request.additionalDirectories,
      ),
      environment: _environment(compactionContext),
      workingDirectory: compactionContext['workingDirectory']!,
      stdinText: _expandStdin(_map(execution['stdin']), compactionContext),
      timeout: Duration(milliseconds: remainingMs),
      stallLimit: providerStallLimit,
      onStdoutLine: (line) {
        if (stdout.length <= 4 * 1024 * 1024) stdout.writeln(line);
      },
    );
    final interpreted = _interpret(
      stdout.toString(),
      result.stderr,
      result.exitCode,
      execution,
      priorSession: priorSession,
      durable: true,
    );
    // A compaction turn has no answer, so an empty result is expected; only
    // a provider-reported failure or a different session means it failed.
    final compacted =
        result.exitCode == 0 &&
        !interpreted.providerFailed &&
        interpreted.issueCode != WorkerIssueCode.contextLimitExceeded &&
        (interpreted.sessionId == null ||
            interpreted.sessionId == priorSession);
    _logger.log(
      compacted ? 'info' : 'warning',
      compacted
          ? 'engine.context.compacted'
          : 'engine.context.compaction_failed',
      context: _diagnosticContext(
        requestId: request.requestId,
        assignmentId: request.assignmentId,
        errorCode: compacted ? null : WorkerIssueCode.contextLimitExceeded,
        failureLayer: compacted ? null : 'provider_tool',
        processExitCode: result.exitCode,
      ),
    );
    return compacted
        ? null
        : 'The Worker could not compact the conversation. Clear AI History and retry.';
  }

  Map<String, String> _context(ExecuteRequest request, String? sessionId) => {
    'prompt': request.prompt,
    'workingDirectory': Directory.current.path,
    'home': _hostHome ?? Directory.current.path,
    'workerStateDirectory': options.statePath,
    'timeoutMs':
        '${(request.timeoutMs - _int(_profile.timeout['providerReserveMs'])).clamp(1, request.timeoutMs)}',
    'timeoutSeconds':
        '${((request.timeoutMs - _int(_profile.timeout['providerReserveMs'])).clamp(1, request.timeoutMs) / 1000).ceil()}',
    if (request.model != null) 'model': _nativeSelection(request),
    if (request.reasoningEffort != null &&
        _modelCatalog?.models
                .where((m) => m.id == request.model)
                .firstOrNull
                ?.selectionMode !=
            'combined')
      'reasoningEffort': ProfileExecutionOptions(
        _profile.model,
      ).mapEffort(request.reasoningEffort!),
    if (sessionId != null) 'sessionId': sessionId,
    'executionPolicy': request.executionPolicy.wireValue,
    'sessionPolicy': request.sessionPolicy == WorkerSessionPolicy.durableSession
        ? 'durable'
        : 'stateless',
  };

  String _nativeSelection(ExecuteRequest request) {
    final model = _modelCatalog?.models
        .where((m) => m.id == request.model)
        .firstOrNull;
    return model == null
        ? request.model!
        : resolveNativeSelection(
            model,
            request.reasoningEffort,
            _profile.model['selectionMapping'],
            _modelCatalog!.providerToolVersion,
            effortVariants: _map(_profile.model['discovery'])['effortVariants'],
          );
  }

  List<String> _expandArguments(
    List<Object?> source,
    Map<String, String> context, {
    List<String> additionalDirectories = const [],
  }) {
    final output = <String>[];
    // Folders are never dropped silently: a Profile that cannot pass them to
    // its CLI fails the execution instead of running without them.
    if (additionalDirectories.isNotEmpty &&
        !source.any(
          (part) =>
              part is Map && part.containsKey('forEachAdditionalDirectory'),
        )) {
      throw const FormatException(
        'Worker Profile does not support additional folders',
      );
    }
    final policy = context['executionPolicy']!;
    for (final part in source) {
      if (part is String) {
        output.add(_template(part, context));
      } else {
        final marker = _map(part);
        final keys = marker.keys.toSet();
        final knownMarker =
            (marker.length == 1 &&
                const {
                  'sandboxPolicyMapping',
                  'modelArguments',
                  'sessionResumeArguments',
                  'providerTimeoutArguments',
                  'autoCompactionArguments',
                  'forEachAdditionalDirectory',
                }.contains(marker.keys.single)) ||
            (marker.length == 2 && keys.containsAll({'ifPresent', 'values'})) ||
            (marker.length == 3 &&
                keys.containsAll({'ifAbsent', 'ifSessionPolicy', 'values'}));
        if (!knownMarker) {
          throw const FormatException('unknown structured argument form');
        }
        if (marker.containsKey('forEachAdditionalDirectory')) {
          final values = _stringList(marker['forEachAdditionalDirectory']);
          for (final directory in additionalDirectories) {
            final scoped = {...context, 'additionalDirectory': directory};
            output.addAll(values.map((v) => _template(v, scoped)));
          }
        } else if (marker['sandboxPolicyMapping'] == true) {
          output.addAll(
            _stringList(
              _map(_profile.sandbox['mappings'])[policy],
            ).map((v) => _template(v, context)),
          );
        } else if (marker['modelArguments'] == true &&
            context.containsKey('model')) {
          output.addAll(
            _stringList(
              _profile.model['arguments'],
            ).map((v) => _template(v, context)),
          );
        } else if (marker['sessionResumeArguments'] == true &&
            context.containsKey('sessionId')) {
          output.addAll(
            _stringList(
              _profile.session['resumeArguments'],
            ).map((v) => _template(v, context)),
          );
        } else if (marker['providerTimeoutArguments'] == true) {
          output.addAll(
            _stringList(
              _profile.timeout['providerArguments'],
            ).map((v) => _template(v, context)),
          );
        } else if (marker['autoCompactionArguments'] == true) {
          final autoCompaction = _profile.context['autoCompaction'];
          if (autoCompaction is Map) {
            output.addAll(
              _stringList(
                autoCompaction['arguments'],
              ).map((v) => _template(v, context)),
            );
          }
        } else if (marker['ifPresent'] == 'model' &&
                context.containsKey('model') ||
            marker['ifPresent'] == 'reasoningEffort' &&
                context.containsKey('reasoningEffort') ||
            marker['ifPresent'] == 'sessionId' &&
                context.containsKey('sessionId')) {
          output.addAll(
            _stringList(marker['values']).map((v) => _template(v, context)),
          );
        } else if (marker['ifAbsent'] == 'sessionId' &&
            !context.containsKey('sessionId') &&
            marker['ifSessionPolicy'] == context['sessionPolicy']) {
          output.addAll(
            _stringList(marker['values']).map((v) => _template(v, context)),
          );
        }
      }
      if (output.length > 128)
        throw const FormatException('expanded arguments exceed Engine limit');
    }
    return output;
  }

  String _expandStdin(Map<String, Object?> spec, Map<String, String> context) {
    if (spec['mode'] == 'raw_text') {
      final value = _template(_string(spec['value']), context);
      if (utf8.encode(value).length > 1024 * 1024) {
        throw const FormatException('provider stdin exceeds Engine limit');
      }
      return value;
    }
    final value = _expandJson(spec['value'], context);
    final encoded =
        '${jsonEncode(value)}${spec['appendNewline'] == true ? '\n' : ''}';
    if (utf8.encode(encoded).length > 1024 * 1024) {
      throw const FormatException('provider stdin exceeds Engine limit');
    }
    return encoded;
  }

  Object? _expandJson(
    Object? value,
    Map<String, String> context, [
    int depth = 0,
  ]) {
    if (depth > 16)
      throw const FormatException('JSON stdin template exceeds depth limit');
    if (value is String) return _template(value, context);
    if (value is List) {
      if (value.length > 64)
        throw const FormatException('JSON stdin array exceeds limit');
      return value
          .map((item) => _expandJson(item, context, depth + 1))
          .toList();
    }
    if (value is Map) {
      if (value.length > 64)
        throw const FormatException('JSON stdin object exceeds limit');
      return value.map(
        (key, item) =>
            MapEntry(key.toString(), _expandJson(item, context, depth + 1)),
      );
    }
    return value;
  }

  String _template(String value, Map<String, String> context) {
    final placeholders = RegExp(r'\{\{([^{}]+)\}\}');
    final scrubbed = value.replaceAll(placeholders, '');
    if (RegExp(r'\{\{|\}\}').hasMatch(scrubbed)) {
      throw const FormatException('malformed Profile placeholder');
    }
    return value.replaceAllMapped(placeholders, (match) {
      final key = match.group(1)!;
      final result = context[key];
      if (result == null)
        throw FormatException('Profile placeholder is unavailable: $key');
      return result;
    });
  }

  Map<String, String> _environment([Map<String, String> context = const {}]) {
    final env = _map(_profile.environment);
    final passthrough = _stringList(env['passthrough']).toSet();
    if (context['executionPolicy'] ==
        WorkerExecutionPolicy.fullAccess.wireValue) {
      // Full local access still uses an explicit allowlist. These variables
      // are needed by ordinary host Git/SSH/proxy/tool installations but do
      // not expose the entire parent environment or arbitrary secrets.
      passthrough.addAll(const {
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
        'XDG_CONFIG_HOME',
        'XDG_DATA_HOME',
        'XDG_CACHE_HOME',
      });
    }
    final parent = <String, String>{
      for (final key in passthrough)
        if (Platform.environment[key] case final value?) key: value,
    };
    final sets = _map(env['set']);
    final values = <String, String>{
      for (final entry in sets.entries)
        entry.key: _template(
          entry.value.toString(),
          context.isEmpty
              ? {
                  'home': _hostHome ?? Directory.current.path,
                  'workingDirectory': Directory.current.path,
                  'workerStateDirectory': options.statePath,
                  'prompt': '',
                  'timeoutMs': '1',
                  'timeoutSeconds': '1',
                }
              : context,
        ),
    };
    final environment = CliEnvironmentBuilder(
      allowedParentKeys: passthrough,
    ).build(values: values, parentEnvironment: parent);
    if (environment.length > 64 ||
        environment.entries.any(
          (entry) =>
              utf8.encode(entry.key).length > 128 ||
              utf8.encode(entry.value).length > 64 * 1024,
        ) ||
        environment.entries.fold<int>(
              0,
              (size, entry) =>
                  size +
                  utf8.encode(entry.key).length +
                  utf8.encode(entry.value).length,
            ) >
            256 * 1024) {
      throw const FormatException('Profile environment exceeds Engine limits');
    }
    return environment;
  }

  Future<String> _resolveTool() async {
    if (_resolvedExecutable != null) return _resolvedExecutable!;
    final tool = _profile.providerTool;
    final discovery = _map(tool['discovery']);
    final locations = _stringList(
      discovery['standardLocations'],
    ).map(_expandHomeLocation).toList();
    final candidates = _stringList(tool['executableCandidates']);
    // Resolve the executable against the same bounded Profile environment used
    // to launch it. This keeps discovery and execution consistent when a
    // Workspace supplies an approved runtime PATH (for example, a bundled
    // Dart or Node runtime used by a fixture or packaged Worker).
    final discoveryEnvironment = _environment();
    if (discovery['allowPathSearch'] != true) {
      discoveryEnvironment.remove('PATH');
    }
    for (final candidate in candidates) {
      final path = await _locator.locate(
        candidate,
        environment: discoveryEnvironment,
        standardPaths: locations,
        cacheFile: File(
          '${options.statePath}${Platform.pathSeparator}'
          'provider-path-${_profile.definitionId}.json',
        ),
        cacheIdentity: '${_profile.definitionId}:$candidate',
      );
      if (path != null) return _resolvedExecutable = path;
    }
    throw const EngineProviderException(
      WorkerIssueCode.providerToolUnavailable,
      'Provider CLI was not found',
    );
  }

  String _expandHomeLocation(String location) {
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']
        : Platform.environment['HOME'];
    if (location == '{{home}}') return home ?? '';
    if (location.startsWith('{{home}}/'))
      return '${home ?? ''}/${location.substring(9)}';
    const allowed = {'/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin'};
    if (!allowed.contains(location))
      throw const FormatException(
        'Profile discovery location is not Engine-approved',
      );
    return location;
  }

  List<(int, String)> _progressForLine(
    String line,
    Map<String, Object?> execution,
  ) {
    final output = _map(execution['output']);
    if (output['mode'] != 'jsonl') return const [];
    Object? event;
    try {
      event = jsonDecode(line);
    } on Object {
      return const [];
    }
    if (event is! Map) return const [];
    final progress = _profile.json['progress'];
    if (progress is! List) return const [];
    final result = <(int, String)>[];
    for (final ruleRaw in _list(execution['events'])) {
      final rule = _map(ruleRaw);
      if (!_matches(event, rule['when'])) continue;
      for (final actionRaw in _list(rule['actions'])) {
        final action = _map(actionRaw);
        if (action['type'] == 'emit_progress') {
          result.add((
            _int(action['percentage']),
            _string(action['messageKey']),
          ));
        }
      }
    }
    for (final ruleRaw in progress) {
      final rule = _map(ruleRaw);
      if (_matches(event, rule['when']))
        result.add((_int(rule['percentage']), _string(rule['messageKey'])));
    }
    return result;
  }

  List<(int, String, WorkerActivity)> _progressActivitiesForLine(
    String line,
    ExecuteRequest request,
    Map<String, Object?> execution,
  ) {
    return _progressForLine(line, execution)
        .map((progress) {
          final sequence = (_activitySequences[request.requestId] ?? 0) + 1;
          _activitySequences[request.requestId] = sequence;
          final activity = WorkerActivity(
            requestId: request.requestId,
            assignmentId: request.assignmentId,
            executionId: request.requestId,
            workerId: _profile.workerTypeId,
            eventId: '${request.requestId}:activity:$sequence',
            sequence: sequence,
            timestamp: DateTime.now().toUtc().toIso8601String(),
            eventType: 'message.updated',
            status: 'updated',
            title: progress.$2,
            percentage: progress.$1.toDouble(),
            details: const {'source': 'profile.milestone'},
          );
          return (progress.$1, progress.$2, activity);
        })
        .toList(growable: false);
  }

  List<WorkerActivity> _activitiesForLine(String line, ExecuteRequest request) {
    final output = _map(_profile.execution['output']);
    if (output['mode'] != 'jsonl') return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on Object {
      decoded = null;
    }
    final mapped = decoded is Map
        ? mapProfileActivityEvents(_profile.json, [decoded])
        : const <ProfileActivityMappingResult>[];
    final observations =
        _providerActivityAdapter?.normalizeLine(
          line,
          declarativeMatched: mapped.isNotEmpty,
        ) ??
        const <ProviderActivityObservation>[];
    if (mapped.isEmpty && observations.isEmpty) return const [];
    final events = <WorkerActivity>[];
    for (final mapping in mapped) {
      // With an adapter, unidentified tool events belong to the adapter, which
      // assigns a stable fallback id. Keeping both would report one invocation
      // twice and leave an unfinished row behind.
      if (_providerActivityAdapter != null &&
          mapping.activityId == null &&
          mapping.type.startsWith('tool.')) {
        continue;
      }
      final sequence = (_activitySequences[request.requestId] ?? 0) + 1;
      _activitySequences[request.requestId] = sequence;
      final presentation = decoded is Map
          ? _providerActivityAdapter?.toolPresentation(decoded, mapping.type)
          : null;
      final details = presentation?.summary == null
          ? mapping.details
          : <String, Object?>{
              ...mapping.details,
              'summary': presentation!.summary,
            };
      events.add(
        WorkerActivity(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          executionId: request.requestId,
          workerId: _profile.workerTypeId,
          eventId: '${request.requestId}:activity:$sequence',
          sequence: sequence,
          timestamp: DateTime.now().toUtc().toIso8601String(),
          eventType: mapping.type,
          status: mapping.status,
          title: presentation?.title ?? mapping.title,
          activityId: mapping.activityId,
          percentage: mapping.percentage?.toDouble(),
          toolId: mapping.type.startsWith('tool.') ? mapping.activityId : null,
          toolName: mapping.details['toolName'] is String
              ? mapping.details['toolName'] as String
              : mapping.details['toolKind'] is String
              ? mapping.details['toolKind'] as String
              : null,
          details: details.isEmpty ? null : details,
        ),
      );
    }
    for (final observation in observations) {
      final sequence = (_activitySequences[request.requestId] ?? 0) + 1;
      _activitySequences[request.requestId] = sequence;
      events.add(
        WorkerActivity(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          executionId: request.requestId,
          workerId: _profile.workerTypeId,
          eventId: '${request.requestId}:activity:$sequence',
          sequence: sequence,
          timestamp: DateTime.now().toUtc().toIso8601String(),
          eventType: observation.type,
          status: observation.status,
          title: observation.title,
          activityId: observation.activityId,
          toolId: observation.type.startsWith('tool.')
              ? observation.activityId
              : null,
          toolName: observation.details['toolName'] is String
              ? observation.details['toolName'] as String
              : observation.details['toolKind'] is String
              ? observation.details['toolKind'] as String
              : null,
          details: observation.details.isEmpty ? null : observation.details,
        ),
      );
    }
    return events;
  }

  Future<void> _emitActivity(
    IOSink sink, {
    required String requestId,
    required String assignmentId,
    required String eventType,
    required String status,
    required String title,
    String? activityId,
    String? message,
    Map<String, Object?>? details,
    double? percentage,
    int? durationMs,
  }) async {
    final sequence = (_activitySequences[requestId] ?? 0) + 1;
    _activitySequences[requestId] = sequence;
    final safeDetails = <String, Object?>{
      ...?details,
      if (message != null) 'message': message,
    };
    await _write(
      sink,
      WorkerActivity(
        requestId: requestId,
        assignmentId: assignmentId,
        executionId: requestId,
        workerId: _profile.workerTypeId,
        eventId: '$requestId:activity:$sequence',
        sequence: sequence,
        timestamp: DateTime.now().toUtc().toIso8601String(),
        eventType: eventType,
        status: status,
        title: title,
        activityId: activityId,
        percentage: percentage,
        durationMs: durationMs,
        details: safeDetails.isEmpty ? null : safeDetails,
      ),
    );
  }

  _InterpretedOutput _interpret(
    String stdout,
    String stderr,
    int exitCode,
    Map<String, Object?> execution, {
    String? priorSession,
    bool durable = false,
  }) {
    final mode = _string(_map(execution['output'])['mode']);
    if (mode == 'plain_text')
      return _InterpretedOutput(
        exitCode == 0 && stdout.trim().isNotEmpty ? stdout.trimRight() : null,
        null,
        exitCode == 0 && stdout.trim().isNotEmpty ? null : _mapExit(exitCode),
      );
    List<Object?> events;
    var skippedLines = 0;
    try {
      if (mode == 'single_json') {
        events = [jsonDecode(stdout)];
      } else {
        // One stray non-JSON line (a warning, a progress ticker) must not
        // discard a whole run's result: skip it and count it. Output with no
        // valid terminal event still fails below.
        events = <Object?>[];
        for (final line in stdout.split(RegExp(r'\r?\n'))) {
          if (line.isEmpty) continue;
          try {
            events.add(jsonDecode(line));
          } on Object {
            skippedLines += 1;
          }
        }
      }
    } on Object {
      return const _InterpretedOutput(
        null,
        null,
        WorkerIssueCode.providerFailure,
        reason: 'provider output is not valid JSON',
      );
    }
    Object? finalText;
    String? sessionId;
    String? terminalStatus;
    var markedSuccess = false;
    var markedFailure = false;
    var providerError = false;
    var providerErrorText = '';
    var terminalObserved = false;
    for (final event in events) {
      if (event is! Map) continue;
      final adapterFinalText = _providerActivityAdapter?.finalResponseText(
        event,
      );
      if (finalText == null && adapterFinalText != null) {
        finalText = adapterFinalText;
      }
      final profileSession = _profile.session;
      if (profileSession['supported'] == true &&
          profileSession['extract'] is String) {
        final value = _select(event, profileSession['extract'] as String);
        if (value is String && value.isNotEmpty) {
          if (!_validSessionId(value)) {
            return const _InterpretedOutput(
              null,
              null,
              WorkerIssueCode.providerFailure,
              reason: 'provider reported an invalid session id',
            );
          }
          if (sessionId != null && sessionId != value) {
            return const _InterpretedOutput(
              null,
              null,
              WorkerIssueCode.providerFailure,
              reason: 'provider reported two different session ids',
            );
          }
          sessionId = value;
        }
      }
      for (final ruleRaw in _list(execution['events'])) {
        final rule = _map(ruleRaw);
        if (!_matches(event, rule['when'])) continue;
        for (final actionRaw in _list(rule['actions'])) {
          final action = _map(actionRaw);
          final type = action['type'];
          final value = action['selector'] == null
              ? null
              : _select(event, _string(action['selector']));
          if (type == 'set_session' && value is String && value.isNotEmpty) {
            if (!_validSessionId(value)) {
              return const _InterpretedOutput(
                null,
                null,
                WorkerIssueCode.providerFailure,
                reason: 'provider reported an invalid session id',
              );
            }
            if (sessionId != null && sessionId != value) {
              return const _InterpretedOutput(
                null,
                null,
                WorkerIssueCode.providerFailure,
                reason: 'provider reported two different session ids',
              );
            }
            sessionId = value;
          }
          if (type == 'set_final_text' && value is String) finalText = value;
          // Providers that stream the answer only as chunks build it here.
          // The cap keeps one byte past the result limit so an oversized
          // answer still fails the limit check below instead of truncating.
          if (type == 'append_final_text' && value is String) {
            final joined = '${finalText is String ? finalText : ''}$value';
            finalText = joined.length > 512 * 1024 + 1
                ? joined.substring(0, 512 * 1024 + 1)
                : joined;
          }
          if (type == 'clear_final_text') finalText = null;
          if (type == 'set_terminal_status' && value is String)
            terminalStatus = value;
          if (type == 'set_provider_error' && value is List) {
            // A list-valued provider error is a list of actions the provider
            // refused to run (for example agy's `denied_actions`). The turn
            // may still report success, but the requested work was not done.
            // An empty list is not an error.
            if (value.isNotEmpty) {
              providerError = true;
              final names = _deniedActionNames(value);
              providerErrorText =
                  'Permission denied for: '
                  '${names.isEmpty ? 'an action' : names.join(', ')}';
            }
          } else if (type == 'set_provider_error' &&
              value != null &&
              value != false &&
              value != '') {
            providerError = true;
            providerErrorText = value is String
                ? value.substring(0, value.length.clamp(0, 4096))
                : 'provider error';
          }
          if (type == 'mark_success') markedSuccess = true;
          if (type == 'mark_failure') markedFailure = true;
        }
      }
    }
    if (markedSuccess &&
        !markedFailure &&
        !providerError &&
        (finalText is! String || finalText.trim().isEmpty)) {
      // The provider reported success with an empty result although it
      // streamed an answer; use what it streamed.
      finalText = _providerActivityAdapter?.streamedAnswer(events) ?? finalText;
    }
    if (finalText is String && _providerActivityAdapter != null) {
      // The live narration was already shown; do not repeat it in the answer.
      finalText =
          _providerActivityAdapter!.answerAfterNarration(events, finalText) ??
          finalText;
    }
    if (mode == 'single_json' && finalText == null) finalText = stdout;
    terminalObserved =
        markedSuccess ||
        markedFailure ||
        terminalStatus != null ||
        providerError;
    final text = finalText is String && finalText.length <= 512 * 1024
        ? finalText
        : null;
    final implicitTextSuccess = mode == 'plain_text' && exitCode == 0;
    final successful =
        exitCode == 0 &&
        !markedFailure &&
        !providerError &&
        (markedSuccess || implicitTextSuccess) &&
        text != null &&
        text.isNotEmpty;
    final requireMatch = _profile.session['requireObservedIdMatch'] == true;
    if (successful &&
        durable &&
        requireMatch &&
        (sessionId == null ||
            (priorSession != null && sessionId != priorSession))) {
      return _InterpretedOutput(
        null,
        null,
        WorkerIssueCode.providerFailure,
        terminalObserved: terminalObserved,
        reason: sessionId == null
            ? 'no session id observed'
            : 'observed session id differs from the prior session',
      );
    }
    if (successful) {
      return _InterpretedOutput(
        text,
        sessionId,
        null,
        terminalObserved: terminalObserved,
      );
    }

    if (_contextOverflow([stderr, providerErrorText, terminalStatus])) {
      return _InterpretedOutput(
        null,
        null,
        WorkerIssueCode.contextLimitExceeded,
        terminalObserved: terminalObserved,
        providerFailed: true,
        reason: [
          'exit=$exitCode',
          'matched context overflow marker',
          if (terminalStatus != null) 'status=$terminalStatus',
        ].join(', '),
      );
    }
    final mappings = _list(_map(_profile.json['errors'])['mappings']);
    for (final raw in mappings) {
      final mapping = _map(raw);
      final evidence = _map(mapping['evidence']);
      final kind = evidence['kind'];
      final matched = switch (kind) {
        'exit_code' => evidence['value'] == exitCode,
        'terminal_status' => evidence['value'] == terminalStatus,
        'missing_terminal' => !terminalObserved,
        'structured_provider_error' => providerError,
        'stderr_pattern' => _stderrPattern(
          _string(evidence['patternId']),
          providerErrorText.isNotEmpty ? providerErrorText : stderr,
        ),
        _ => false,
      };
      if (matched)
        return _InterpretedOutput(
          null,
          null,
          _string(mapping['issueCode']),
          providerFailed: markedFailure || providerError,
          nativeSessionUnavailable:
              kind == 'stderr_pattern' &&
              evidence['patternId'] == 'session_unavailable' &&
              mapping['issueCode'] == WorkerIssueCode.sessionResumeFailed &&
              finalText == null &&
              !markedSuccess,
          terminalObserved: terminalObserved,
          reason: [
            'exit=$exitCode',
            'matched $kind',
            if (terminalStatus != null) 'status=$terminalStatus',
            if (!terminalObserved) 'no terminal event',
            if (providerError) 'provider error reported',
            if (skippedLines > 0) 'skipped $skippedLines non-JSON lines',
            _eventShape(events),
          ].join(', '),
        );
    }
    return _InterpretedOutput(
      null,
      null,
      WorkerIssueCode.providerFailure,
      providerFailed: markedFailure || providerError,
      emptyResponse:
          exitCode == 0 &&
          (markedSuccess || implicitTextSuccess) &&
          !markedFailure &&
          !providerError &&
          (text == null || text.isEmpty),
      reason: [
        'exit=$exitCode',
        if (markedFailure) 'provider marked failure',
        if (providerError) 'provider error reported',
        if (!markedSuccess && !implicitTextSuccess) 'no success marker',
        if (terminalStatus != null) 'status=$terminalStatus',
        if (!terminalObserved) 'no terminal event',
        if (skippedLines > 0) 'skipped $skippedLines non-JSON lines',
        if (text == null || text.isEmpty) 'empty final text',
        if (text == null || text.isEmpty) _eventShape(events),
      ].join(', '),
    );
  }

  /// Counts only: which event kinds the provider sent and what its result
  /// reported. Never contains provider text.
  String _eventShape(List<Object?> events) {
    final kinds = <String, int>{};
    Map? result;
    for (final event in events) {
      if (event is! Map) continue;
      final name = _safeShapeName(event['event'] ?? event['type']);
      final step = event['step_update'];
      final kind = step is Map
          ? '$name/${_safeShapeName(step['step_type'])}'
          : name;
      kinds[kind] = (kinds[kind] ?? 0) + 1;
      if (event['event'] == 'result' && event['result'] is Map) {
        result = event['result'] as Map;
      }
    }
    final usage = result?['usage'];
    final parts = <String>[
      'events: ${kinds.entries.map((e) => '${e.key}=${e.value}').join(' ')}',
      if (result != null) 'result keys: ${result.keys.take(12).join(',')}',
      if (result?['response'] is String)
        'response chars: ${(result!['response'] as String).length}',
      if (result?['num_turns'] is int) 'turns: ${result!['num_turns']}',
      if (usage is Map && usage['output_tokens'] is int)
        'output tokens: ${usage['output_tokens']}',
      if (usage is Map && usage['thinking_tokens'] is int)
        'thinking tokens: ${usage['thinking_tokens']}',
    ];
    return parts.join('; ');
  }

  String _safeShapeName(Object? value) {
    final text = value is String ? value : 'unknown';
    return RegExp(r'^[A-Za-z0-9_.:-]{1,40}$').hasMatch(text) ? text : 'other';
  }

  List<String> _deniedActionNames(List<Object?> entries) {
    final safe = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');
    final names = <String>[];
    for (final entry in entries) {
      final candidate = entry is Map
          ? (entry['display_name'] ?? entry['action'])
          : entry;
      if (candidate is String && safe.hasMatch(candidate)) {
        if (!names.contains(candidate)) names.add(candidate);
      }
      if (names.length >= 8) break;
    }
    return names;
  }

  /// True when a failed run's text carries one of the Profile's overflow
  /// markers. Only stderr, the provider error and the terminal status are
  /// checked: the answer text may quote such a phrase legitimately.
  bool _contextOverflow(List<String?> texts) {
    final overflow = _profile.context['overflow'];
    if (overflow is! Map) return false;
    final haystack = texts.whereType<String>().join('\n').toLowerCase();
    return _stringList(
      overflow['markers'],
    ).any((marker) => haystack.contains(marker.toLowerCase()));
  }

  bool _stderrPattern(String patternId, String text) {
    final patterns = <String, RegExp>{
      'session_unavailable': RegExp(
        r'(?:session|thread|conversation).{0,60}(?:not found|does not exist|no longer exists|unavailable)|(?:no such|unknown) (?:session|thread|conversation)',
        caseSensitive: false,
      ),
      'cancelled': RegExp(
        r'cancelled|canceled|interrupted|user interrupted',
        caseSensitive: false,
      ),
      'deadline_exceeded': RegExp(
        r'(?<![-_\w])(?:timeout|timed out|deadline exceeded)\b',
        caseSensitive: false,
      ),
      'provider_tool_unavailable': RegExp(
        r'enoent|executable not found|command not found',
        caseSensitive: false,
      ),
      'provider_authentication_required': RegExp(
        r'unauthori[sz]ed|authentication required|not authenticated|no authentication information|sign in|login required|credentials? (missing|expired|invalid)',
        caseSensitive: false,
      ),
      'model_not_supported': RegExp(
        r'invalid model selection|(?:unknown|unsupported) model|model.{0,100}(?:not recognized|not found|not available|access denied)',
        caseSensitive: false,
      ),
      'permission_denied': RegExp(
        r'permission denied|approval denied|sandbox.*(denied|blocked)',
        caseSensitive: false,
      ),
      'quota_exhausted': RegExp(
        r"quota.{0,40}(?:exceeded|exhausted)|(?:exceeded|exhausted).{0,40}quota|insufficient[_ -]quota|usage[_ -]limit[_ -](?:reached|exceeded)|(?:reached|exceeded|exhausted|hit).{0,40}(?:usage|session|weekly|daily|monthly|spending|rate) limit|(?:usage|session|weekly|daily|monthly|spending|rate|free) limit.{0,40}(?:reached|exceeded|exhausted)|rate[_ -]limit(?:ed|[_ -]error|[_ -]exceeded)|you(?:['’]ve| have) (?:hit|reached) (?:all |any |your )?.{0,40}limit|credits? balance is too low|resource_exhausted|resource has been exhausted|free[_ -]usage[_ -]exhausted|you(?:['’]ve| have) used (?:all|up) .{0,40}usage|too many requests",
        caseSensitive: false,
      ),
      'provider_unavailable': RegExp(
        r'provider unavailable|service unavailable|temporarily unavailable',
        caseSensitive: false,
      ),
      'context_limit_exceeded': RegExp(
        r"prompt is too long|context[_ -]length[_ -]exceeded|context[_ -]window[_ -]exceeded|exceeds the context window|ran out of room in the model's context window|maximum context length",
        caseSensitive: false,
      ),
      'provider_failure': RegExp(r'.+', dotAll: true),
    };
    return patterns[patternId]?.hasMatch(text) ?? false;
  }

  bool _matches(Object? event, Object? conditions) {
    if (conditions is! List) return false;
    for (final raw in conditions) {
      final condition = _map(raw);
      final value = _select(event, _string(condition['selector']));
      switch (condition['kind']) {
        case 'equals':
          if (value != condition['value']) return false;
        case 'not_equals':
          if (value == null || value == condition['value']) return false;
        case 'one_of':
          if (!_list(condition['values']).contains(value)) return false;
        case 'exists':
          if ((value != null) != (condition['exists'] == true)) return false;
        case 'type_is':
          final actual = value == null
              ? 'null'
              : value is List
              ? 'array'
              : value is Map
              ? 'object'
              : value is num
              ? 'number'
              : value is bool
              ? 'boolean'
              : 'string';
          if (actual != condition['value']) return false;
        default:
          return false;
      }
    }
    return true;
  }

  Object? _select(Object? root, String selector) {
    if (!RegExp(r'^\$(?:\.[A-Za-z_][A-Za-z0-9_]*)+$').hasMatch(selector) ||
        selector.length > 256 ||
        selector.split('.').length - 1 > 16)
      return null;
    Object? current = root;
    for (final part in selector.substring(2).split('.')) {
      if (current is! Map || !current.containsKey(part)) return null;
      current = current[part];
    }
    return current;
  }

  bool _validSessionId(String value) =>
      value.length <= 256 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

  WorkerErrorFrame _notInitialized(String requestId, {String? assignmentId}) =>
      WorkerErrorFrame(
        requestId: requestId,
        assignmentId: assignmentId,
        code: WorkerIssueCode.workerInternalFailure,
        message: 'Engine must complete initialize before this request',
      );

  String _mapExit(int exitCode) {
    final mappings = _map(_profile.json['errors'])['mappings'];
    if (mappings is List)
      for (final raw in mappings) {
        final mapping = _map(raw);
        final evidence = _map(mapping['evidence']);
        if (evidence['kind'] == 'exit_code' && evidence['value'] == exitCode)
          return _string(mapping['issueCode']);
      }
    return WorkerIssueCode.providerFailure;
  }

  Map<String, Object?> _diagnosticContext({
    String? requestId,
    String? assignmentId,
    String? providerToolVersion,
    int? durationMs,
    String? errorCode,
    int? processExitCode,
    String? probeStage,
    String? failureLayer,
  }) => {
    if (requestId != null) 'requestId': requestId,
    if (assignmentId != null) 'assignmentId': assignmentId,
    'workerTypeId': _admittedProfile.workerTypeId,
    'engineVersion': options.engineVersion,
    'profileDefinitionId': _admittedProfile.definitionId,
    'profileReleaseVersion': _profileRevision,
    'profileSchemaVersion': _admittedProfile.schemaVersion,
    'providerToolName': _string(_admittedProfile.providerTool['name']),
    if (providerToolVersion != null) 'providerToolVersion': providerToolVersion,
    if (durationMs != null) 'durationMs': durationMs,
    if (errorCode != null) 'errorCode': errorCode,
    if (processExitCode != null) 'processExitCode': processExitCode,
    if (probeStage != null) 'probeStage': probeStage,
    if (failureLayer != null) 'failureLayer': failureLayer,
  };

  String _failureLayer(String code) => switch (code) {
    WorkerIssueCode.workerInternalFailure ||
    WorkerIssueCode.malformedFrame ||
    WorkerIssueCode.engineVersionMismatch ||
    WorkerIssueCode.profileIdentityMismatch ||
    WorkerIssueCode.workerTypeMismatch => 'engine',
    WorkerIssueCode.unsupportedProviderToolVersion ||
    WorkerIssueCode.modelNotSupported ||
    WorkerIssueCode.sessionResumeFailed => 'profile',
    _ => 'provider_tool',
  };

  Future<void> _write(IOSink sink, WorkerFrame frame) async {
    if (frame is WorkerResult || frame is WorkerErrorFrame) {
      final String? assignmentId = frame is WorkerResult
          ? frame.assignmentId
          : (frame as WorkerErrorFrame).assignmentId;
      if (assignmentId != null) {
        final error = frame is WorkerErrorFrame ? frame : null;
        final cancelled = error?.code == WorkerIssueCode.cancelled;
        await _emitActivity(
          sink,
          requestId: frame.requestId,
          assignmentId: assignmentId,
          eventType: cancelled
              ? 'execution.cancelled'
              : error == null
              ? 'execution.completed'
              : 'execution.failed',
          status: cancelled
              ? 'cancelled'
              : error == null
              ? 'completed'
              : 'failed',
          title: cancelled
              ? 'Execution cancelled'
              : error == null
              ? 'Execution completed'
              : 'Execution failed',
          durationMs: _operationStarts[frame.requestId]?.elapsedMilliseconds,
          details: error == null ? null : {'errorCode': error.code},
        );
        _activitySequences.remove(frame.requestId);
      }
    }
    if (frame is ProbeResult) {
      final timer = _operationStarts.remove(frame.requestId);
      _logger.log(
        frame.ready ? 'info' : 'warning',
        'engine.probe.completed',
        context: _diagnosticContext(
          requestId: frame.requestId,
          providerToolVersion: frame.providerToolVersion,
          durationMs: timer?.elapsedMilliseconds,
          errorCode: frame.issueCode,
          probeStage: frame.mode.name,
          failureLayer: frame.issueCode == null
              ? null
              : _failureLayer(frame.issueCode!),
        ),
      );
    } else if (frame is WorkerResult || frame is WorkerErrorFrame) {
      final requestId = frame.requestId;
      final timer = _operationStarts.remove(requestId);
      final error = frame is WorkerErrorFrame ? frame : null;
      final assignmentId = frame is WorkerResult
          ? frame.assignmentId
          : error?.assignmentId;
      _logger.log(
        error == null ? 'info' : 'warning',
        error == null
            ? 'engine.assignment.completed'
            : 'engine.assignment.failed',
        context: _diagnosticContext(
          requestId: requestId,
          assignmentId: assignmentId,
          durationMs: timer?.elapsedMilliseconds,
          errorCode: error?.code,
          failureLayer: error == null ? null : _failureLayer(error.code),
        ),
      );
    }
    sink.writeln(frame.encode());
    await sink.flush();
  }
}

class EngineProviderException implements Exception {
  const EngineProviderException(this.issueCode, this.safeMessage);
  final String issueCode;
  final String safeMessage;
}

class _ProbeOutcome {
  const _ProbeOutcome(this.check, this.issueCode);
  final ProbeCheck check;
  final String? issueCode;
}

class _InterpretedOutput {
  const _InterpretedOutput(
    this.finalText,
    this.sessionId,
    this.issueCode, {
    this.nativeSessionUnavailable = false,
    this.terminalObserved = false,
    this.reason,
    this.emptyResponse = false,
    this.providerFailed = false,
  });

  /// The provider reported success with no answer text and no error.
  final bool emptyResponse;

  /// The provider itself marked the run failed or reported an error.
  final bool providerFailed;

  /// Why the output was not accepted; goes into the failure diagnostic.
  final String? reason;
  final bool nativeSessionUnavailable;
  final bool terminalObserved;
  final String? finalText;
  final String? sessionId;
  final String? issueCode;
}

bool _isSemver(String value) => RegExp(
  r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
).hasMatch(value);

/// Removes terminal control sequences so a CLI report renders as plain text.
String _stripAnsi(String value) => value.replaceAll(
  RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\))'),
  '',
);

Map<String, Object?> _map(Object? value) => value is Map
    ? Map<String, Object?>.from(value)
    : throw const FormatException('expected Profile object');
List<Object?> _list(Object? value) => value is List
    ? value.cast<Object?>()
    : throw const FormatException('expected Profile array');
List<String> _stringList(Object? value) =>
    _list(value).map((item) => _string(item)).toList();
List<int> _intList(Object? value) => _list(value).map(_int).toList();
String _string(Object? value) => value is String
    ? value
    : throw const FormatException('expected Profile string');
int _int(Object? value) => value is int
    ? value
    : throw const FormatException('expected Profile integer');
String _requestIdFromLine(String line) {
  try {
    final value = jsonDecode(line);
    if (value is Map &&
        value['requestId'] is String &&
        (value['requestId'] as String).isNotEmpty)
      return (value['requestId'] as String).substring(
        0,
        (value['requestId'] as String).length.clamp(0, 128),
      );
  } on Object {}
  return 'invalid-frame';
}

String? get _hostHome => Platform.isWindows
    ? Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']
    : Platform.environment['HOME'];
