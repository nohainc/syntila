import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';

import 'cli_engine.dart';
import 'config.dart';
import 'connection.dart';
import 'engine.dart';
import 'artifact_launcher.dart';
import 'artifacts.dart';
import 'folders.dart';
import 'work_root.dart';
import 'identity.dart';
import 'journal.dart';
import 'legacy_import.dart';
import 'lock.dart';
import 'pairing.dart';
import 'paths.dart';
import 'profile_cache.dart';
import 'runtime.dart';
import 'server_api.dart';
import 'services.dart';
import 'update.dart';

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
    'dry-run',
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

/// `syntila-worker`. A pure client of the Agent's own files and the OS service
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

  KeyStore _keys(AgentPaths paths) =>
      keyStoreFor?.call(paths) ?? FileKeyStore(paths.keyFile);

  static const usage = '''
syntila-worker <command> [options]

  install --pairing-code CODE [--auto-start] [--no-service] [--separate-user NAME]
  run                      run the Agent in the foreground (the service does this)
  status [--json]          registration, connection, journal and service state
  logs [--lines N]         the Agent's own log (ids and codes only)
  config show              show settings
  config set KEY VALUE     maxConcurrent, autoStart, separateOsUser, logLevel
  permissions list         folders this Worker may use
  permissions add-folder PATH [--write]   grant a folder (read only unless --write)
  permissions work-root [PATH]            show or set the Work Root
  permissions adopt-space SPACE_ID PATH   map an existing folder to a Space
  permissions remove-folder ID
  import-workspace --from DIR [--write] [--dry-run]   take the folders and Work Root of an old Workspace
  rotate-credential        replace this Worker's key pair
  update stage --manifest FILE --artifact FILE
  uninstall [--yes] [--keep-data]

Select a Worker with --worker ID or --data-dir DIR (or SYNTILA_WORKER_DATA_DIR).
''';

  Future<int> run(List<String> arguments) async {
    if (arguments.isEmpty ||
        arguments.first == 'help' ||
        arguments.first == '--help') {
      out.writeln(usage);
      return arguments.isEmpty ? 2 : 0;
    }
    try {
      final command = arguments.first;
      final args = _Args.parse(arguments.skip(1).toList());
      switch (command) {
        case 'install':
          return await _install(args);
        case 'run':
          return await _runAgent(args);
        case 'status':
          return await _status(args);
        case 'logs':
          return await _logs(args);
        case 'config':
          return await _config(args);
        case 'permissions':
          return await _permissions(args);
        case 'import-workspace':
          return await _importWorkspace(args);
        case 'rotate-credential':
          return await _rotate(args);
        case 'update':
          return await _update(args);
        case 'uninstall':
          return await _uninstall(args);
        default:
          err.writeln('unknown command "$command"\n$usage');
          return 2;
      }
    } on FormatException catch (error) {
      err.writeln(error.message);
      return 2;
    } on AgentLockedException {
      err.writeln('another Worker Agent is already using this data directory');
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
    } on UpdateRejectedException catch (error) {
      err.writeln(error);
      return 1;
    }
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
    final root = Directory(
      '${AgentPaths.applicationDataRoot(environment: environment, operatingSystem: operatingSystem)}/Workers',
    );
    final found = root.existsSync()
        ? root.listSync().whereType<Directory>().toList()
        : <Directory>[];
    if (found.length == 1) return AgentPaths(found.single);
    if (found.isEmpty) {
      throw const FormatException('no Worker is installed on this host');
    }
    final names = found.map(
      (d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last,
    );
    throw FormatException(
      'several Workers are installed (${names.join(', ')}); choose one with --worker ID',
    );
  }

  Future<AgentIdentity> _identity(AgentPaths paths) async {
    final identity = await AgentIdentity.load(paths.identityFile);
    if (identity == null) throw StateError('this data directory is not paired');
    return identity;
  }

  ServiceSpec _spec(
    AgentIdentity identity,
    AgentPaths paths,
    AgentConfig config, {
    String? runAsUser,
  }) => ServiceSpec(
    workerId: identity.workerId,
    executable: executable ?? Platform.resolvedExecutable,
    dataDir: paths.root.path,
    autoStart: config.autoStart,
    runAsUser: runAsUser,
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

  Future<int> _install(_Args args) async {
    final text = args.options['pairing-code'];
    if (text == null) {
      throw const FormatException('install needs --pairing-code');
    }
    final code = PairingCode.parse(text);
    final paths = _paths(args, workerId: code.workerId);
    final identity = await installAgent(
      code: code,
      paths: paths,
      keyStore: _keys(paths),
      api: apiFor?.call(code.serverUrl),
    );
    var config = await AgentConfig.load(paths.configFile);
    if (args.flags.contains('auto-start')) {
      config = config.set('autoStart', 'true');
    }
    final separateUser = args.options['separate-user'];
    if (separateUser != null) config = config.set('separateOsUser', 'true');
    await config.save(paths.configFile);
    out.writeln('Paired Worker ${identity.workerId}.');
    if (!args.flags.contains('no-service')) {
      await _services.install(
        _spec(identity, paths, config, runAsUser: separateUser),
      );
      out.writeln(
        config.autoStart
            ? 'The service is installed and starts automatically.'
            : 'The service is installed. It does not start by itself; run `syntila-worker config set autoStart true` to opt in.',
      );
    }
    if (separateUser != null) {
      out.writeln('Create the OS user first (as an administrator):');
      for (final line in separateUserCommands(operatingSystem, separateUser)) {
        out.writeln('  $line');
      }
      out.writeln(isolationNotes);
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
    final profiles = ProfileCache(paths.profilesDir, const _NoNewProfiles());
    final runtime = await AgentRuntime.open(
      paths: paths,
      identity: identity,
      keyStore: keyStore,
      engine:
          engineFactory?.call(paths) ??
          _withArtifacts(
            paths,
            identity,
            _defaultEngine(paths, identity, settings, profiles),
          ),
      api: api,
      profiles: profiles,
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

  /// The generic CLI Worker Engine when `engineExecutable` is configured,
  /// otherwise a launcher that refuses work (`engine_unavailable`).
  EngineLauncher _defaultEngine(
    AgentPaths paths,
    AgentIdentity identity,
    AgentConfig config,
    ProfileCache cache,
  ) {
    final executable = config.engineExecutable;
    if (executable == null) return UnconfiguredEngineLauncher();
    final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '.';
    return CliEngineLauncher(
      supervisor: CliWorkerEngineSupervisor(
        engineExecutable: executable,
        processRegistryDirectory: Directory(
          '${paths.engineDir.path}/processes',
        ),
      ),
      engineExecutable: executable,
      workerId: identity.workerId,
      stateDirectory: paths.sessionsDir,
      workRoot: Directory(
        config.workRoot ?? '$home/Syntila Work/${identity.workerId}',
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

  Future<int> _status(_Args args) async {
    final paths = _paths(args);
    final identity = await AgentIdentity.load(paths.identityFile);
    if (identity == null) {
      out.writeln('Not paired.');
      return 1;
    }
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
    final report = {
      'workerId': identity.workerId,
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
    if (args.flags.contains('json')) {
      out.writeln(const JsonEncoder.withIndent('  ').convert(report));
    } else {
      report.forEach((key, value) => out.writeln('$key: $value'));
    }
    return journalProblem == null ? 0 : 1;
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
      config = config.set(args.positionals[1], args.positionals[2]);
      await config.save(paths.configFile);
      out.writeln('Saved. Settings apply the next time the Agent starts.');
      if (args.positionals[1] == 'autoStart') {
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
    dataRoot: AgentPaths.applicationDataRoot(
      environment: environment,
      operatingSystem: operatingSystem,
    ),
  );

  Future<int> _permissions(_Args args) async {
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
      case 'add-folder':
        if (args.positionals.length != 2) {
          throw const FormatException(
            'usage: permissions add-folder PATH [--write]',
          );
        }
        final write = args.flags.contains('write');
        final id = await folders.add(args.positionals[1], write: write);
        out.writeln('Granted (${write ? 'read and write' : 'read only'}) $id');
        return 0;
      case 'remove-folder':
        if (args.positionals.length != 2) {
          throw const FormatException('usage: permissions remove-folder ID');
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
      case 'adopt-space':
        if (args.positionals.length != 3) {
          throw const FormatException(
            'usage: permissions adopt-space SPACE_ID PATH',
          );
        }
        await WorkRoot(
          paths.workRootFile,
          folders,
        ).adopt({args.positionals[1]: args.positionals[2]});
        out.writeln('Space ${args.positionals[1]} now uses that folder.');
        return 0;
      default:
        throw const FormatException(
          'usage: permissions list | add-folder | remove-folder | work-root | adopt-space',
        );
    }
  }

  Future<int> _importWorkspace(_Args args) async {
    final from = args.options['from'];
    if (from == null) {
      throw const FormatException(
        'usage: import-workspace --from DIR [--write] [--dry-run]',
      );
    }
    final paths = _paths(args);
    final folders = _folders(paths);
    final report = await importLegacyWorkspace(
      legacyData: Directory(from),
      folders: folders,
      workRoot: WorkRoot(paths.workRootFile, folders),
      write: args.flags.contains('write'),
      dryRun: args.flags.contains('dry-run'),
    );
    final verb = args.flags.contains('dry-run') ? 'Would import' : 'Imported';
    if (report.workRoot != null) {
      out.writeln('$verb Work Root ${report.workRoot}');
    }
    for (final path in report.imported) {
      out.writeln('$verb folder $path');
    }
    for (final line in report.skipped) {
      out.writeln('Skipped $line');
    }
    out.writeln('Not copied:');
    for (final line in report.notCopied) {
      out.writeln('  $line');
    }
    return 0;
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

  Future<int> _update(_Args args) async {
    if (args.positionals.isEmpty || args.positionals.first != 'stage') {
      throw const FormatException(
        'usage: update stage --manifest FILE --artifact FILE',
      );
    }
    final manifestFile = args.options['manifest'];
    final artifactFile = args.options['artifact'];
    if (manifestFile == null || artifactFile == null) {
      throw const FormatException(
        'update stage needs --manifest and --artifact',
      );
    }
    final paths = _paths(args);
    final decoded = jsonDecode(await File(manifestFile).readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('the manifest is not an object');
    }
    final staged = await UpdateVerifier(compiledUpdateKeys()).stage(
      UpdateManifest.fromJson(decoded),
      await File(artifactFile).readAsBytes(),
      Directory('${paths.engineDir.path}/updates'),
      currentVersion: agentVersion,
    );
    out.writeln('Verified and staged ${staged.uri.pathSegments.last}.');
    return 0;
  }

  Future<int> _uninstall(_Args args) async {
    final paths = _paths(args);
    final identity = await AgentIdentity.load(paths.identityFile);
    if (!args.flags.contains('yes')) {
      throw const FormatException(
        'uninstall removes this Worker\'s key and journal; repeat with --yes',
      );
    }
    if (identity != null) {
      final config = await AgentConfig.load(paths.configFile);
      await _services.uninstall(_spec(identity, paths, config));
    }
    await uninstallAgent(paths: paths, keyStore: _keys(paths));
    out.writeln(
      'Removed the Agent\'s private state. Your working folders were not touched.',
    );
    if (identity != null) {
      out.writeln(
        'Revoke or remove the Worker in the app to close it on the server.',
      );
    }
    return 0;
  }
}

/// Until signed downloads and trust roots exist, fail closed for new and
/// previously cached Profiles.
class _NoNewProfiles implements ProfileVerifier {
  const _NoNewProfiles();

  @override
  Future<bool> verify(List<int> profileBytes, String? signature) async => false;
}
