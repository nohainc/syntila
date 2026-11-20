import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_mcp_worker_store/syntila_mcp_worker_store.dart';
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';

import 'artifact_launcher.dart';
import 'artifacts.dart';
import 'cli_engine.dart';
import 'config.dart';
import 'connection.dart';
import 'engine.dart';
import 'folders.dart';
import 'gui_manifest.dart';
import 'identity.dart';
import 'journal.dart';
import 'lock.dart';
import 'mcp_worker_allow_list.dart';
import 'mcp_worker_runner.dart';
import 'pairing.dart';
import 'paths.dart';
import 'profile_cache.dart';
import 'profile_signature.dart';
import 'runtime.dart';
import 'server_api.dart';
import 'services.dart';
import 'work_root.dart';

const agentVersion = '0.1.0';

class _Args {
  _Args(this.positionals, this.options, this.flags);
  final List<String> positionals;
  final Map<String, String> options;
  final Set<String> flags;

  static const _booleans = {
    'json',
    'yes',
    'auto-start',
    'no-service',
    'keep-data',
    'write',
    'pairing-code-stdin',
  };

  factory _Args.parse(List<String> args) {
    final positionals = <String>[];
    final options = <String, String>{};
    final flags = <String>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (!arg.startsWith('--')) {
        positionals.add(arg);
        continue;
      }
      final body = arg.substring(2);
      final eq = body.indexOf('=');
      if (eq >= 0) {
        options[body.substring(0, eq)] = body.substring(eq + 1);
      } else if (_booleans.contains(body)) {
        flags.add(body);
      } else if (i + 1 < args.length) {
        options[body] = args[++i];
      } else {
        throw FormatException('--$body needs a value');
      }
    }
    return _Args(positionals, options, flags);
  }
}

/// `syntila-connect`. A pure client of the Agent's own files and the OS service
/// manager: apart from `run` it never opens a Cloud connection or starts an
/// Engine. Everything it prints is free of secrets.
class WorkerCli {
  WorkerCli({
    StringSink? out,
    StringSink? err,
    Map<String, String>? environment,
    String? operatingSystem,
    CommandRunner? runner,
    this.engineFactory,
    this.executable,
    this.keyStoreFor,
    this.apiFor,
    this.readSecretLine,
  }) : out = out ?? stdout,
       err = err ?? stderr,
       environment = environment ?? Platform.environment,
       operatingSystem = operatingSystem ?? Platform.operatingSystem,
       runner = runner ?? ProcessCommandRunner();

  final StringSink out;
  final StringSink err;
  final Map<String, String> environment;
  final String operatingSystem;
  final CommandRunner runner;

  /// Supplies the Engine adapter for `run`. Without one the Agent reports
  /// `engine_unavailable` and refuses work.
  final EngineLauncher Function(AgentPaths paths)? engineFactory;
  final String? executable;
  final KeyStore Function(AgentPaths paths)? keyStoreFor;
  final ServerApi Function(String serverUrl)? apiFor;

  /// Supplies one line of secret input for `--pairing-code-stdin`. Defaults to
  /// standard input.
  final Future<String?> Function()? readSecretLine;

  KeyStore _keys(AgentPaths paths) {
    final custom = keyStoreFor?.call(paths);
    if (custom != null) return custom;
    if (operatingSystem == 'macos') return MacKeychainKeyStore(paths.keyFile);
    if (operatingSystem == 'windows') {
      return WindowsDpapiKeyStore(paths.keyFile);
    }
    if (operatingSystem == 'linux') {
      final marker = File('${paths.identityDir.path}/credential-store');
      final configured = environment['SYNTILA_WORKER_SECRET_STORE'];
      if (configured != null &&
          configured != 'secret-service' &&
          configured != 'file') {
        throw const FormatException(
          'SYNTILA_WORKER_SECRET_STORE must be secret-service or file',
        );
      }
      if (marker.existsSync() || configured == 'secret-service') {
        return LinuxSecretKeyStore(paths.keyFile, marker);
      }
    }
    return FileKeyStore(paths.keyFile);
  }

  static const usage = '''
syntila-connect <command> [options]

  status [--json]          registration, connection, journal and service state
  pair --pairing-code CODE | --pairing-code-stdin [--name NAME] [--auto-start] [--no-service]
  unpair --yes [--keep-data]
  run                      run the Agent in the foreground (the service does this)
  service status | start | stop | restart | install [--auto-start] | uninstall
  folders list             folders this Worker may use
  folders add PATH [--write]                grant a folder (read only unless --write)
  folders remove ID                         stop this Worker from using a folder
  folders work-root [PATH]                  show or set the Work Root
  mcp-worker list | import PATH | test ID | approve ID VERSION MANIFEST_DIGEST | remove ID MANIFEST_DIGEST
  config show              show settings
  config set KEY VALUE     maxConcurrent, autoStart, logLevel
  logs [--lines N]         the Agent's own log (ids and codes only)
  rotate-credential        replace this Worker's key pair
  version [--json]         show the Syntila Connect version

Select a Worker with --worker ID or --data-dir DIR (or SYNTILA_WORKER_DATA_DIR).
''';

  Future<int> run(List<String> arguments) async {
    final manifest = answerGuiManifest(arguments, version: agentVersion);
    if (manifest != null) {
      final document = manifest.document;
      if (document != null) {
        out.write(document);
        return 0;
      }
      err.writeln(manifest.refusal);
      return 2;
    }
    if (arguments.isEmpty ||
        arguments.first == 'help' ||
        arguments.first == '--help') {
      out.writeln(usage);
      return arguments.isEmpty ? 2 : 0;
    }
    if (arguments.first == '--version') {
      out.writeln(agentVersion);
      return 0;
    }
    try {
      final command = arguments.first;
      final args = _Args.parse(arguments.skip(1).toList());
      switch (command) {
        case 'status':
          return await _status(args);
        case 'pair':
          return await _pair(args);
        case 'unpair':
          return await _unpair(args);
        case 'run':
          return await _runAgent(args);
        case 'service':
          return await _service(args);
        case 'folders':
          return await _foldersCommand(args);
        case 'mcp-worker':
          return await _mcpWorker(args);
        case 'config':
          return await _config(args);
        case 'logs':
          return await _logs(args);
        case 'rotate-credential':
          return await _rotate(args);
        case 'version':
          return _version(args);
        default:
          err.writeln('unknown command "$command"\n$usage');
          return 2;
      }
    } on ExternalWorkerException catch (error) {
      err.writeln('${error.code}: ${error.message}');
      return 1;
    } on FormatException catch (error) {
      err.writeln(error.message);
      return 2;
    } on AgentLockedException {
      err.writeln('another Syntila Connect is already using this data directory');
      return 3;
    } on ServerRefusal catch (error) {
      err.writeln('the server refused the request: ${error.message}');
      return 4;
    } on StateError catch (error) {
      err.writeln(error.message);
      return 1;
    } on FolderRejectedException catch (error) {
      err.writeln(error.reason);
      return 1;
    }
  }

  String get _appDataRoot => AgentPaths.applicationDataRoot(
    environment: environment,
    operatingSystem: operatingSystem,
  );

  /// All installed Worker directories under the application data root, sorted
  /// by directory name.
  List<AgentPaths> _installedWorkerPaths() {
    final root = Directory('$_appDataRoot/Workers');
    if (!root.existsSync()) return const [];
    final found = root.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return [for (final d in found) AgentPaths(d)];
  }

  /// `--data-dir`, `--worker` or the environment; with none of them, the only
  /// Worker on this host. Never guesses between several.
  AgentPaths _paths(_Args args, {String? workerId}) {
    final dir =
        args.options['data-dir'] ?? environment['SYNTILA_WORKER_DATA_DIR'];
    if (dir != null) return AgentPaths(Directory(dir));
    final id = workerId ?? args.options['worker'];
    if (id != null) {
      return AgentPaths.forWorker(
        id,
        environment: environment,
        operatingSystem: operatingSystem,
      );
    }
    final found = _installedWorkerPaths();
    if (found.length == 1) return found.single;
    if (found.isEmpty) {
      throw const FormatException('no Worker is installed on this host');
    }
    final names = found.map(
      (d) => d.root.uri.pathSegments.where((s) => s.isNotEmpty).last,
    );
    throw FormatException(
      'several Workers are installed (${names.join(', ')}); choose one with --worker ID',
    );
  }

  /// Root directory for machine-wide MCP Workers (`--data-dir` when explicitly
  /// set for sandboxed tests, otherwise the host application data root).
  Directory _mcpMachineRoot(_Args args) {
    final dir =
        args.options['data-dir'] ?? environment['SYNTILA_WORKER_DATA_DIR'];
    return Directory(dir ?? _appDataRoot);
  }

  Future<AgentIdentity> _identity(AgentPaths paths) async {
    final identity = await AgentIdentity.load(paths.identityFile);
    if (identity == null) throw StateError('this data directory is not paired');
    return identity;
  }

  ServiceSpec _spec(
    AgentIdentity identity,
    AgentPaths paths,
    AgentConfig config,
  ) => ServiceSpec(
    workerId: identity.workerId,
    executable: executable ?? Platform.resolvedExecutable,
    dataDir: paths.root.path,
    autoStart: config.autoStart,
  );

  ServiceManager get _services => serviceManagerFor(
    runner: runner,
    operatingSystem: operatingSystem,
    environment: environment,
    uid: _uid(),
  );

  /// The numeric user id launchd's `gui/<uid>` domain needs.
  int _uid() {
    if (operatingSystem == 'windows') return 0;
    try {
      return int.parse((Process.runSync('id', ['-u']).stdout as String).trim());
    } on Object {
      return 501;
    }
  }

  /// Resolves the CLI Worker Engine binary bundled next to `syntila-connect`
  /// (`engine/syntila-worker` or `syntila-worker` in the same folder).
  String? _resolveEngineExecutable() {
    final binName = operatingSystem == 'windows'
        ? 'syntila-worker.exe'
        : 'syntila-worker';
    final agentDir = File(
      executable ?? Platform.resolvedExecutable,
    ).parent.path;
    for (final candidate in [
      p.join(agentDir, 'engine', binName),
      p.join(agentDir, binName),
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  Future<int> _pair(_Args args) async {
    final fromStdin = args.flags.contains('pairing-code-stdin');
    if (fromStdin && args.options.containsKey('pairing-code')) {
      throw const FormatException(
        'use either --pairing-code or --pairing-code-stdin, not both',
      );
    }
    final text = fromStdin
        ? ((await (readSecretLine ?? () async => stdin.readLineSync())())
              ?.trim())
        : args.options['pairing-code'];
    if (text == null || text.isEmpty) {
      throw FormatException(
        fromStdin
            ? 'no pairing code was provided on standard input'
            : 'pair needs --pairing-code',
      );
    }
    final code = PairingCode.parse(text);
    final paths = _paths(args, workerId: code.workerId);
    final identity = await installAgent(
      code: code,
      paths: paths,
      keyStore: _keys(paths),
      api: apiFor?.call(code.serverUrl),
      workerName: args.options['name'],
    );
    var config = await AgentConfig.load(paths.configFile);
    if (args.flags.contains('auto-start')) {
      config = config.set('autoStart', 'true');
    }
    await config.save(paths.configFile);
    out.writeln('Paired Worker ${identity.workerId}.');
    if (!args.flags.contains('no-service')) {
      await _services.install(_spec(identity, paths, config));
      out.writeln(
        config.autoStart
            ? 'The service is installed and starts automatically.'
            : 'The service is installed. It does not start by itself; run `syntila-connect config set autoStart true` to opt in.',
      );
    }
    return 0;
  }

  Future<int> _runAgent(_Args args) async {
    final paths = _paths(args);
    final identity = await _identity(paths);
    final keyStore = _keys(paths);
    final api =
        apiFor?.call(identity.serverUrl) ?? ServerApi(identity.serverUrl);
    final settings = await AgentConfig.load(paths.configFile);
    final resolvedWorkRoot = await WorkRoot(
      paths.workRootFile,
      _folders(paths),
    ).root();
    const roots = String.fromEnvironment(
      'SYNTILA_PROFILE_TRUST_ROOTS',
      defaultValue: '{}',
    );
    final profiles = ProfileCache(
      paths.profilesDir,
      SignedProfileVerifier(parseProfileTrustRoots(roots)),
    );
    final mcpRoot = _mcpMachineRoot(args);
    final runtime = await AgentRuntime.open(
      paths: paths,
      identity: identity,
      keyStore: keyStore,
      engine:
          engineFactory?.call(paths) ??
          _withArtifacts(
            paths,
            identity,
            _defaultEngine(
              paths,
              identity,
              settings,
              profiles,
              mcpRoot: mcpRoot,
              workRootPath: resolvedWorkRoot,
            ),
          ),
      api: api,
      profiles: profiles,
      plugins: _mcpAllowList(mcpRoot),
      mcpWorkerRunner: _mcpRunner(mcpRoot),
      clientVersion: agentVersion,
    );
    await recoverPendingRotation(
      paths: paths,
      identity: identity,
      keyStore: keyStore,
      api: api,
    ).catchError((Object _) => false);
    final stopped = Completer<void>();
    final subscriptions = <StreamSubscription<ProcessSignal>>[];
    void stopOnce(ProcessSignal _) {
      if (!stopped.isCompleted) stopped.complete();
    }

    subscriptions.add(ProcessSignal.sigint.watch().listen(stopOnce));
    if (!Platform.isWindows) {
      subscriptions.add(ProcessSignal.sigterm.watch().listen(stopOnce));
    }
    await runtime.start();
    out.writeln(
      'Worker ${identity.workerId} is running. Press Ctrl+C to stop.',
    );
    final revoked = runtime.connection.phases
        .firstWhere((phase) => phase == ConnectionPhase.revoked)
        .then<void>((_) {
          err.writeln('The server no longer accepts this Worker. Stopping.');
          if (!stopped.isCompleted) stopped.complete();
        }, onError: (Object _) {});
    unawaited(revoked);
    await stopped.future;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await runtime.stop();
    return 0;
  }

  /// The generic CLI Worker Engine bundled with `syntila-connect`, or a launcher
  /// that refuses work (`engine_unavailable`) if the binary is not present.
  EngineLauncher _defaultEngine(
    AgentPaths paths,
    AgentIdentity identity,
    AgentConfig config,
    ProfileCache cache, {
    required Directory mcpRoot,
    String? workRootPath,
  }) {
    final engineExe = _resolveEngineExecutable();
    if (engineExe == null) return UnconfiguredEngineLauncher();
    final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '.';
    return CliEngineLauncher(
      supervisor: CliWorkerEngineSupervisor(
        engineExecutable: engineExe,
        processRegistryDirectory: Directory(
          '${paths.engineDir.path}/processes',
        ),
      ),
      engineExecutable: engineExe,
      mcpWorkerRunner: _mcpRunner(mcpRoot),
      workerId: identity.workerId,
      stateDirectory: paths.sessionsDir,
      workRoot: Directory(
        workRootPath ?? '$home/Syntila Work/${identity.workerId}',
      ),
      maxConcurrent: config.maxConcurrent,
      resolveProfile: (payload) async {
        final digest = payload['profileDigest'];
        final type = payload['workerTypeId'];
        if (digest is! String || type is! String) return null;
        final bytes = await cache.read(digest);
        if (bytes == null) return null;
        final profileFile = await cache.verifiedFile(digest);
        if (profileFile == null) return null;
        try {
          final decoded = jsonDecode(utf8.decode(bytes));
          if (decoded is! Map<String, Object?>) return null;
          final revision = payload['profileRevision'];
          return (
            candidate: WorkerProfileSnapshotAdmission(
              profile: decoded,
              workerTypeId: type,
              revision: revision is int ? revision : 0,
              payloadDigest: digest,
            ),
            profileFile: profileFile,
          );
        } on FormatException {
          return null;
        }
      },
    );
  }

  /// Adds the file side of a step: artifact inputs and outputs, with the
  /// Allowed Folders re-checked. A launcher that refuses work stays as it is.
  EngineLauncher _withArtifacts(
    AgentPaths paths,
    AgentIdentity identity,
    EngineLauncher inner,
  ) {
    if (inner is UnconfiguredEngineLauncher) return inner;
    final folders = _folders(paths);
    return ArtifactLauncher(
      inner: inner,
      folders: folders,
      workRoot: WorkRoot(paths.workRootFile, folders),
      client: ArtifactClient(identity.serverUrl),
      holder: AgentSessionHolder(),
      workerId: identity.workerId,
    );
  }

  Future<int> _service(_Args args) async {
    final action = args.positionals.isEmpty ? 'status' : args.positionals.first;
    switch (action) {
      case 'status':
        final paths = _paths(args);
        final identity = await _identity(paths);
        final config = await AgentConfig.load(paths.configFile);
        final service = await _services.status(_spec(identity, paths, config));
        final report = {
          'workerId': identity.workerId,
          'service': service.state.name,
          'autoStart': service.autoStart,
        };
        if (args.flags.contains('json')) {
          out.writeln(const JsonEncoder.withIndent('  ').convert(report));
        } else {
          report.forEach((key, value) => out.writeln('$key: $value'));
        }
        return 0;
      case 'start':
      case 'stop':
      case 'restart':
        return await _control(action, args);
      case 'install':
        final paths = _paths(args);
        final identity = await _identity(paths);
        var config = await AgentConfig.load(paths.configFile);
        if (args.flags.contains('auto-start')) {
          config = config.set('autoStart', 'true');
        }
        await config.save(paths.configFile);
        await _services.install(_spec(identity, paths, config));
        out.writeln(
          config.autoStart
              ? 'The service is installed and starts automatically.'
              : 'The service is installed. It does not start by itself; run `syntila-connect config set autoStart true` to opt in.',
        );
        return 0;
      case 'uninstall':
        final paths = _paths(args);
        final identity = await _identity(paths);
        final config = await AgentConfig.load(paths.configFile);
        await _services.uninstall(_spec(identity, paths, config));
        out.writeln('The background service was removed.');
        return 0;
      default:
        throw const FormatException(
          'usage: service status | start | stop | restart | install | uninstall',
        );
    }
  }

  /// `service start`, `service stop` and `service restart` drive the installed
  /// service. They never start an Engine themselves, and they refuse when no
  /// service is installed (use `run` for a foreground Agent).
  Future<int> _control(String action, _Args args) async {
    final paths = _paths(args);
    final identity = await _identity(paths);
    final config = await AgentConfig.load(paths.configFile);
    final spec = _spec(identity, paths, config);
    final services = _services;
    final current = await services.status(spec);
    if (current.state == ServiceState.notInstalled) {
      throw StateError(
        'no background service is installed for this Worker; run `syntila-connect service install` or use `run`',
      );
    }
    if (action != 'start') await services.stop(spec);
    if (action != 'stop') await services.start(spec);
    out.writeln(switch (action) {
      'start' => 'The service was started.',
      'stop' => 'The service was stopped.',
      _ => 'The service was restarted.',
    });
    return 0;
  }

  Future<({Map<String, Object?> report, bool hasJournalProblem})?>
  _workerStatusReport(AgentPaths paths) async {
    final identity = await AgentIdentity.load(paths.identityFile);
    if (identity == null) return null;
    final running = await AgentLock.isHeld(paths.lockFile);
    Map<String, Object?>? state;
    if (await paths.stateFile.exists()) {
      try {
        final decoded = jsonDecode(await paths.stateFile.readAsString());
        if (decoded is Map<String, Object?>) state = decoded;
      } on FormatException {
        state = null;
      }
    }
    final counts = <String, int>{};
    String? journalProblem;
    if (!running && await paths.journalFile.exists()) {
      final journal = AgentJournal(paths.journalFile);
      try {
        await journal.open();
        for (final entry in journal.entries) {
          counts[entry.status.name] = (counts[entry.status.name] ?? 0) + 1;
        }
        await journal.close();
      } on JournalCorruptedException catch (error) {
        journalProblem = '$error';
      }
    }
    final config = await AgentConfig.load(paths.configFile);
    final service = await _services.status(_spec(identity, paths, config));
    final report = <String, Object?>{
      'workerId': identity.workerId,
      'workerName': identity.displayName,
      if (identity.workerType != null) 'workerType': identity.workerType,
      'server': identity.serverUrl,
      'registration': 'paired',
      'running': running,
      'connection': running ? (state?['phase'] ?? 'unknown') : 'stopped',
      if (running && state?['epoch'] != null) 'epoch': state!['epoch'],
      'service': service.state.name,
      'autoStart': service.autoStart,
      if (counts.isNotEmpty) 'journal': counts,
      if (journalProblem != null) 'journalProblem': journalProblem,
    };
    return (report: report, hasJournalProblem: journalProblem != null);
  }

  Future<int> _status(_Args args) async {
    final explicitDir =
        args.options['data-dir'] ?? environment['SYNTILA_WORKER_DATA_DIR'];
    final explicitWorker = args.options['worker'];
    final asJson = args.flags.contains('json');

    if (explicitDir != null || explicitWorker != null) {
      final paths = _paths(args);
      final status = await _workerStatusReport(paths);
      if (status == null) {
        if (asJson) {
          out.writeln(
            const JsonEncoder.withIndent(
              '  ',
            ).convert({'workers': const <Object>[]}),
          );
        } else {
          out.writeln('Not paired.');
        }
        return 1;
      }
      final report = {
        ...status.report,
        'workers': [status.report],
      };
      if (asJson) {
        out.writeln(const JsonEncoder.withIndent('  ').convert(report));
      } else {
        status.report.forEach((key, value) => out.writeln('$key: $value'));
      }
      return status.hasJournalProblem ? 1 : 0;
    }

    final installed = _installedWorkerPaths();
    final reports = <Map<String, Object?>>[];
    var anyProblem = false;
    for (final paths in installed) {
      final status = await _workerStatusReport(paths);
      if (status != null) {
        reports.add(status.report);
        if (status.hasJournalProblem) anyProblem = true;
      }
    }

    if (reports.isEmpty) {
      if (asJson) {
        out.writeln(
          const JsonEncoder.withIndent(
            '  ',
          ).convert({'workers': const <Object>[]}),
        );
        return 0;
      }
      throw const FormatException('no Worker is installed on this host');
    }

    if (asJson) {
      final payload = reports.length == 1
          ? {...reports.single, 'workers': reports}
          : {'workers': reports};
      out.writeln(const JsonEncoder.withIndent('  ').convert(payload));
      return anyProblem ? 1 : 0;
    }

    for (var i = 0; i < reports.length; i++) {
      if (i > 0) out.writeln();
      reports[i].forEach((key, value) => out.writeln('$key: $value'));
    }
    return anyProblem ? 1 : 0;
  }

  Future<int> _logs(_Args args) async {
    final paths = _paths(args);
    if (!await paths.logFile.exists()) {
      out.writeln('No log yet.');
      return 0;
    }
    final lines = int.tryParse(args.options['lines'] ?? '') ?? 50;
    final all = await paths.logFile.readAsLines();
    for (final line in all.skip(all.length > lines ? all.length - lines : 0)) {
      out.writeln(line);
    }
    return 0;
  }

  Future<int> _config(_Args args) async {
    final paths = _paths(args);
    final action = args.positionals.isEmpty ? 'show' : args.positionals.first;
    var config = await AgentConfig.load(paths.configFile);
    if (action == 'show') {
      out.writeln(const JsonEncoder.withIndent('  ').convert(config.toJson()));
      return 0;
    }
    if (action == 'set' && args.positionals.length == 3) {
      final key = args.positionals[1];
      final value = args.positionals[2];
      config = config.set(key, value);
      await config.save(paths.configFile);
      out.writeln('Saved. Settings apply the next time the Agent starts.');
      if (key == 'autoStart') {
        final identity = await _identity(paths);
        await _services.install(_spec(identity, paths, config));
      }
      return 0;
    }
    throw const FormatException('usage: config show | config set KEY VALUE');
  }

  AllowedFolders _folders(AgentPaths paths) => AllowedFolders(
    paths.foldersFile,
    home: environment['HOME'] ?? environment['USERPROFILE'] ?? '/',
    dataRoot: _appDataRoot,
  );

  McpWorkerAllowList _mcpAllowList(Directory mcpRoot) => McpWorkerAllowList(
    File('${mcpRoot.path}/registry/approved-mcp-workers.json'),
  );

  McpWorkerRunner _mcpRunner(Directory mcpRoot) => McpWorkerRunner(
    store: ExternalWorkerStore(
      root: Directory('${mcpRoot.path}/mcp-workers'),
      forbiddenRoots: [mcpRoot.path],
    ),
    allowList: _mcpAllowList(mcpRoot),
    pinsFile: File('${mcpRoot.path}/registry/mcp-worker-tool-pins.json'),
  );

  Future<int> _mcpWorker(_Args args) async {
    final mcpRoot = _mcpMachineRoot(args);
    final list = _mcpAllowList(mcpRoot);
    final action = args.positionals.isEmpty ? 'list' : args.positionals.first;
    switch (action) {
      case 'list':
        final items = await list.list();
        if (items.isEmpty) {
          out.writeln('No MCP Workers are approved on this machine.');
        }
        for (final p in items) {
          out.writeln('${p.id} ${p.version} ${p.digest}');
        }
        return 0;
      case 'import':
        if (args.positionals.length != 2) {
          throw const FormatException('usage: mcp-worker import PATH');
        }
        final store = ExternalWorkerStore(
          root: Directory('${mcpRoot.path}/mcp-workers'),
          forbiddenRoots: [mcpRoot.path],
        );
        final InstalledExternalWorker installed;
        try {
          installed = await store.import(args.positionals[1]);
        } on ExternalWorkerException catch (error) {
          err.writeln('${error.code}: ${error.message}');
          return 1;
        }
        // The owner ran this command on this machine, so this exact package is approved.
        await list.approve(
          installed.pluginId,
          installed.version,
          installed.manifestDigest,
        );
        out.writeln(
          'Imported and approved ${installed.pluginId} ${installed.version} ${installed.manifestDigest}',
        );
        return 0;
      case 'test':
        if (args.positionals.length != 2) {
          throw const FormatException('usage: mcp-worker test ID');
        }
        final matches = (await list.list())
            .where((p) => p.id == args.positionals[1])
            .toList();
        if (matches.length != 1) {
          throw StateError(
            'Choose one approved version of this MCP Worker before testing.',
          );
        }
        final engineExe = _resolveEngineExecutable();
        if (engineExe == null) {
          throw StateError(
            'The CLI Worker Engine executable was not found beside syntila-connect.',
          );
        }
        final probeDir = Directory('${mcpRoot.path}/engine');
        await probeDir.create(recursive: true);
        final pin = matches.single;
        final runner = _mcpRunner(mcpRoot);
        final installed = await runner.store.load(
          pin.id,
          pin.version,
          pin.digest,
        );
        if (installed.pluginId != pin.id || installed.version != pin.version) {
          throw StateError(
            'The MCP Worker does not match its approved identity.',
          );
        }
        final inspection = McpEngineInspection(
          locateEngine: () =>
              (executable: engineExe, argumentsPrefix: <String>[]),
          workingDirectory: probeDir,
        );
        final tools = await inspection.inspectWorker(
          installed,
          environment: environment,
        );
        await runner.record(installed, tools);
        out.writeln('Inspected and pinned ${pin.id} ${pin.version}.');
        return 0;
      case 'approve':
        if (args.positionals.length != 4) {
          throw const FormatException(
            'usage: mcp-worker approve ID VERSION MANIFEST_DIGEST',
          );
        }
        await list.approve(
          args.positionals[1],
          args.positionals[2],
          args.positionals[3],
        );
        out.writeln(
          'Approved ${args.positionals[1]} ${args.positionals[2]} for this machine.',
        );
        return 0;
      case 'remove':
        if (args.positionals.length != 3) {
          throw const FormatException(
            'usage: mcp-worker remove ID MANIFEST_DIGEST',
          );
        }
        final removed = await list.remove(
          args.positionals[1],
          args.positionals[2],
        );
        out.writeln(removed ? 'Removed.' : 'No such approval.');
        return removed ? 0 : 1;
      default:
        throw const FormatException(
          'usage: mcp-worker list | import | test | approve | remove',
        );
    }
  }

  Future<int> _foldersCommand(_Args args) async {
    final paths = _paths(args);
    final folders = _folders(paths);
    final action = args.positionals.isEmpty ? 'list' : args.positionals.first;
    switch (action) {
      case 'list':
        final list = await folders.list();
        if (list.isEmpty) out.writeln('No folders are granted.');
        for (final f in list) {
          out.writeln('${f['id']}  ${f['mode']}  ${f['path']}');
        }
        return 0;
      case 'add':
        if (args.positionals.length != 2) {
          throw const FormatException('usage: folders add PATH [--write]');
        }
        final write = args.flags.contains('write');
        final id = await folders.add(args.positionals[1], write: write);
        out.writeln('Granted (${write ? 'read and write' : 'read only'}) $id');
        return 0;
      case 'remove':
        if (args.positionals.length != 2) {
          throw const FormatException('usage: folders remove ID');
        }
        final removed = await folders.remove(args.positionals[1]);
        out.writeln(removed ? 'Removed.' : 'No such folder id.');
        return removed ? 0 : 1;
      case 'work-root':
        final workRoot = WorkRoot(paths.workRootFile, folders);
        if (args.positionals.length == 1) {
          out.writeln(await workRoot.root() ?? 'No Work Root is set.');
          return 0;
        }
        await workRoot.setRoot(args.positionals[1]);
        out.writeln('Work Root set (read and write granted).');
        return 0;
      default:
        throw const FormatException(
          'usage: folders list | add | remove | work-root',
        );
    }
  }

  Future<int> _rotate(_Args args) async {
    final paths = _paths(args);
    final identity = await _identity(paths);
    await rotateCredential(
      paths: paths,
      identity: identity,
      keyStore: _keys(paths),
      api: apiFor?.call(identity.serverUrl),
    );
    out.writeln(
      'The credential was replaced. Restart the Agent to connect with it.',
    );
    return 0;
  }

  Future<int> _unpair(_Args args) async {
    final paths = _paths(args);
    final identity = await AgentIdentity.load(paths.identityFile);
    if (!args.flags.contains('yes')) {
      throw const FormatException(
        'unpair removes this Worker\'s key and journal; repeat with --yes',
      );
    }
    final keepData = args.flags.contains('keep-data');
    if (identity != null) {
      final config = await AgentConfig.load(paths.configFile);
      await _services.uninstall(_spec(identity, paths, config));
    }
    await uninstallAgent(
      paths: paths,
      keyStore: _keys(paths),
      keepData: keepData,
    );
    out.writeln(
      keepData
          ? 'Removed the Agent\'s key and identity. Configuration, folders and working folders were kept.'
          : 'Removed the Agent\'s private state. Your working folders were not touched.',
    );
    if (identity != null) {
      out.writeln(
        'Revoke or remove the Worker in the app to close it on the server.',
      );
    }
    return 0;
  }

  int _version(_Args args) {
    if (args.flags.contains('json')) {
      out.writeln(
        const JsonEncoder.withIndent('  ').convert({'version': agentVersion}),
      );
    } else {
      out.writeln(agentVersion);
    }
    return 0;
  }
}
