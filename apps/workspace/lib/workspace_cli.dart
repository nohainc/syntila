import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'desktop_auth.dart';
import 'secure_credentials.dart';
import 'workspace_configuration.dart';
import 'linux_service_manager.dart';
import 'macos_service_manager.dart';
import 'windows_service_manager.dart';
import 'workspace_background_service.dart';
import 'workspace_headless_auth.dart';
import 'workspace_lifecycle_store.dart';
import 'workspace_manager_ipc.dart';
import 'workspace_registration_models.dart';
import 'workspace_settings.dart';

typedef WorkspaceCliRequest = Future<Object?> Function(
    String command, Map<String, Object?> payload);

/// Management CLI for a running Workspace service. It only speaks the local
/// authenticated IPC protocol: it never starts Engines, provider CLIs, or
/// talks to Cloud (ADR-021 §2.6).
class WorkspaceCli {
  WorkspaceCli({
    required this.out,
    required this.err,
    WorkspaceCliRequest? request,
    WorkspaceServiceManager Function(Directory)? hostManager,
    ({String email, String password}) Function()? readCredentials,
    String? Function(String question)? readLine,
    DesktopAuthClient Function(String cloudUrl)? authClientFactory,
    SecureCredentialStore? credentialStore,
  })  : _request = request,
        _hostManager = hostManager,
        _readCredentials = readCredentials,
        _readLine = readLine,
        _authClientFactory = authClientFactory,
        _credentialStore = credentialStore;

  final StringSink out;
  final StringSink err;
  final WorkspaceCliRequest? _request;
  final WorkspaceServiceManager Function(Directory)? _hostManager;
  final ({String email, String password}) Function()? _readCredentials;
  final String? Function(String question)? _readLine;
  final DesktopAuthClient Function(String cloudUrl)? _authClientFactory;
  final SecureCredentialStore? _credentialStore;

  /// Help entries by command, sorted alphabetically when rendered.
  /// `always` commands are listed even before `workspace.nano` exists.
  static const _helpEntries = <_HelpEntry>[
    _HelpEntry('assignments', [
      ('assignments', 'Active assignment ids'),
      ('assignments cancel ID', 'Cancel an active assignment'),
    ]),
    _HelpEntry(
        'config',
        [
          (
            'config init|show|validate|path',
            'Manage the restart-applied workspace.nano file',
          ),
        ],
        always: true),
    _HelpEntry('connect', [('connect', 'Connect to Cloud')]),
    _HelpEntry('disconnect', [('disconnect', 'Disconnect from Cloud')]),
    _HelpEntry('folders', [
      ('folders [list]', 'List allowed Space folders'),
      ('folders add PATH [--name NAME]', 'Add an allowed Space folder'),
      ('folders remove ID', 'Remove an allowed Space folder'),
    ]),
    _HelpEntry('login', [
      ('login', 'Sign in with Cloud email and password (does not register)'),
    ]),
    _HelpEntry('logout', [
      ('logout', 'Delete the stored sign-in session on this computer'),
    ]),
    _HelpEntry('logs', [('logs', 'Recent service logs')]),
    _HelpEntry('metrics', [('metrics', 'Service metrics')]),
    _HelpEntry('pause', [('pause', 'Stop accepting new work')]),
    _HelpEntry('register', [
      ('register', 'Register this Workspace with Cloud (after login)'),
    ]),
    _HelpEntry(
        'reset',
        [
          ('reset', 'Stop service, unregister and erase local runtime state'),
        ],
        always: true),
    _HelpEntry('resume', [('resume', 'Resume accepting new work')]),
    _HelpEntry('service', [
      (
        'service install|uninstall|start|stop|restart|status',
        'Manage the host background service (macOS/Linux/Windows)',
      ),
    ]),
    _HelpEntry(
        'setup',
        [
          ('setup', 'Start service, sign in and connect (headless)'),
        ],
        always: true),
    _HelpEntry('slots', [('slots', 'Parallel execution slots')]),
    _HelpEntry('status', [('status', 'Service summary')], always: true),
    _HelpEntry('unregister', [
      (
        'unregister',
        'Unregister workspace from Cloud and clear local identity'
      ),
    ]),
    _HelpEntry('version', [('version', 'Show the version')], always: true),
    _HelpEntry('work-dir', [
      ('work-dir [PATH]', 'View or update the Work Root directory'),
    ]),
    _HelpEntry('workers', [
      ('workers', 'List configured Workers'),
      ('workers catalog', 'List available catalog Workers'),
      ('workers add TYPE', 'Add a Worker from the catalog (e.g. gemini)'),
      ('workers remove TYPE', 'Remove a configured Worker'),
      ('workers check [TYPE]', 'Check provider CLI readiness'),
      ('workers test TYPE', 'Run a Worker test'),
      ('workers enable|disable TYPE', 'Enable or disable a Worker'),
    ]),
  ];

  /// Help text. Which commands are listed depends only on whether
  /// workspace.nano exists (it is not validated here), never on whether the
  /// service is running. [all] lists everything regardless.
  static String usageText({required bool configExists, bool all = false}) {
    final showAll = all || configExists;
    final buffer = StringBuffer(
      'Usage: syntila [--data-dir DIR] [--json] <command>\n\n',
    );
    for (final entry in _helpEntries) {
      if (!showAll && !entry.always) continue;
      for (final (syntax, description) in entry.lines) {
        if (syntax.length > 28) {
          buffer.writeln('  $syntax');
          buffer.writeln('${' ' * 32}$description');
        } else {
          buffer.writeln('  ${syntax.padRight(30)}$description');
        }
      }
    }
    if (!showAll) {
      buffer
        ..writeln()
        ..writeln('More commands are available once workspace.nano exists '
            '(run: syntila config init).')
        ..writeln('Use --help --all to list every command.');
    }
    return buffer.toString();
  }

  static String? _dataDirArg(List<String> args) {
    final index = args.indexOf('--data-dir');
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  /// Existence check only: an invalid file still counts as present.
  String _usage(String? dataDir, {bool all = false}) {
    var exists = true;
    try {
      final root = WorkspaceConfigurationResolver.resolveDataDirectory([
        if (dataDir != null) ...['--data-dir', dataDir],
      ]);
      exists = WorkspaceSettingsStore(root).file.existsSync();
    } on Object {
      // An unresolvable data directory should not hide commands.
    }
    return usageText(configExists: exists, all: all);
  }

  Future<int> run(List<String> args) async {
    final rest = <String>[];
    var json = false;
    String? dataDir;
    final helpRequested = args.contains('-h') || args.contains('--help');
    final listAll = helpRequested && args.contains('--all');
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--all' && listAll) {
        continue;
      } else if (arg == '--json') {
        json = true;
      } else if (arg == '--data-dir' && i + 1 < args.length) {
        dataDir = args[++i];
      } else if (arg == '-h' || arg == '--help') {
        out.write(_usage(dataDir ?? _dataDirArg(args), all: listAll));
        return 0;
      } else {
        rest.add(arg);
      }
    }
    if (rest.length == 2 && rest.first == 'service') {
      return _service(dataDir, rest[1], json);
    }
    if (rest.length == 2 && rest.first == 'config') {
      return _config(dataDir, rest[1], json);
    }
    if (rest.length == 1 && rest.first == 'setup') {
      return _setup(dataDir, json);
    }
    if ((rest.length == 1 && rest.first == 'login') ||
        (rest.length == 2 &&
            rest.first == 'login' &&
            rest[1] == '--password')) {
      return _login(dataDir, json);
    }
    if (rest.length >= 2 && rest.first == 'folders' && rest[1] != 'list') {
      return _folders(dataDir, rest.sublist(1), json);
    }
    if (rest.isNotEmpty && rest.first == 'work-dir') {
      return _workDir(dataDir, rest.sublist(1), json);
    }
    if (rest.length == 1 && rest.first == 'register') {
      return _register(dataDir, json);
    }
    if (rest.length == 1 && rest.first == 'logout') {
      return _logout(dataDir, json);
    }
    if (rest.length == 1 && rest.first == 'unregister') {
      return _unregister(dataDir, json);
    }
    if (rest.length == 1 && rest.first == 'reset') {
      return _reset(dataDir, json);
    }
    final resolved = _resolve(rest);
    if (resolved == null) {
      err.write(_usage(dataDir));
      return 64;
    }
    var call = resolved;
    try {
      if (rest.first == 'workers' &&
          call.$2['workerId'] is String &&
          rest.length == 3) {
        final workerId = await _workerIdForType(dataDir, rest[2]);
        if (workerId == null) {
          err.writeln('No configured Worker of type "${rest[2]}". '
              'See: syntila workers');
          return 66;
        }
        call = (call.$1, {...call.$2, 'workerId': workerId});
      }
      final result = await _send(dataDir, call.$1, call.$2);
      if (call.$1 == 'connection.connect') {
        await _updateConnectionSetting(dataDir, true);
      } else if (call.$1 == 'connection.disconnect') {
        await _updateConnectionSetting(dataDir, false);
      }
      if (!json && result is Map<String, Object?>) {
        if (call.$1 == 'service.getVersion' && result['version'] is String) {
          out.writeln(result['version']);
          return 0;
        }
        if (call.$1 == 'service.getStatus') {
          _printStatusSummary(result);
          _writeConfigLine(_configState(dataDir));
          return 0;
        }
        if (call.$1 == 'connection.connect' ||
            call.$1 == 'connection.reconnect' ||
            call.$1 == 'connection.disconnect' ||
            call.$1 == 'connection.pause' ||
            call.$1 == 'connection.resume') {
          _printConnectionSummary(call.$1, result);
          return 0;
        }
        if (call.$1 == 'workers.getCatalogSnapshot') {
          _printCatalogSummary(result);
          return 0;
        }
        if (call.$1 == 'workers.configureWorker') {
          final type = result['productWorkerTypeId'] ??
              result['workerTypeId'] ??
              call.$2['workerTypeId'] ??
              'worker';
          final id = result['workerId'] ?? result['id'];
          out.writeln(
              id == null ? 'Worker added: $type' : 'Worker added: $type ($id)');
          return 0;
        }
        if (call.$1 == 'workers.removeWorker') {
          final id = result['workerId'] ?? 'worker';
          final state = result['state'] ?? 'removed';
          out.writeln('Worker $state: $id');
          return 0;
        }
      }
      if (json && call.$1 == 'service.getStatus' && result is Map) {
        final config = _configState(dataDir);
        _print({
          ...result,
          'config': {
            'state': config.state,
            if (config.error != null) 'error': config.error,
          },
        }, true);
        return 0;
      }
      _print(result, json);
      return 0;
    } on WorkspaceManagerProtocolException catch (error) {
      err.writeln('syntila: ${error.message} (${error.code})');
      return 1;
    } on TimeoutException {
      err.writeln('syntila: service request timed out.');
      return 69;
    } on SocketException {
      return await _withoutService(dataDir, call.$1, json) ??
          _serviceUnreachable(dataDir);
    } on FileSystemException {
      return await _withoutService(dataDir, call.$1, json) ??
          _serviceUnreachable(dataDir);
    }
  }

  bool _configExists(String? dataDir) {
    try {
      final root = WorkspaceConfigurationResolver.resolveDataDirectory([
        if (dataDir != null) ...['--data-dir', dataDir],
      ]);
      return WorkspaceSettingsStore(root).file.existsSync();
    } on Object {
      return true;
    }
  }

  int _serviceUnreachable(String? dataDir) {
    err.writeln(
      'syntila: the Workspace service is not running '
      'or its socket is unreachable.',
    );
    err.writeln(
      _configExists(dataDir)
          ? 'Start it with: syntila service start'
          : 'There is no workspace.nano yet. '
              'Run: syntila setup',
    );
    return 69;
  }

  WorkspaceServiceManager _manager(Directory root) =>
      _hostManager?.call(root) ??
      (Platform.isMacOS
          ? MacOsWorkspaceServiceManager(dataDirectory: root)
          : Platform.isWindows
              ? WindowsWorkspaceServiceManager(dataDirectory: root)
              : LinuxWorkspaceServiceManager(dataDirectory: root));

  /// Commands whose answer does not need a running service. They are tried
  /// against the service first (it is authoritative while it runs) and fall
  /// back to local facts when it is down. Returns null when [command] needs
  /// the service.
  Future<int?> _withoutService(
    String? dataDir,
    String command,
    bool json,
  ) async {
    switch (command) {
      case 'service.getVersion':
        if (json) {
          _print({'version': syntilaWorkspaceAppVersion}, true);
        } else {
          out.writeln(syntilaWorkspaceAppVersion);
        }
        return 0;
      case 'service.getStatus':
        final root = WorkspaceConfigurationResolver.resolveDataDirectory([
          if (dataDir != null) ...['--data-dir', dataDir],
        ]);
        final info = await _localServiceInfo(dataDir);
        final config = _configState(dataDir);
        final registration = WorkspaceRegistrationStore(root).readSync();
        if (json) {
          _print({
            'service': {
              'installed': info.registered,
              'running': info.running,
              'pid': info.pid,
            },
            'config': {
              'state': config.state,
              if (config.error != null) 'error': config.error,
            },
            'registered': registration != null,
          }, true);
        } else {
          _writeServiceLines(info.registered, info.running, info.pid,
              hint: false);
          _writeConfigLine(config);
          out.writeln('Workspace:     '
              '${registration == null ? 'Not registered' : registration.name}');
        }
        return 0;
    }
    return null;
  }

  /// Presence and validity of workspace.nano, for `status`. Validation is the
  /// same strict parse `config validate` uses; nothing is modified.
  ({String path, String state, String? error}) _configState(String? dataDir) {
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final store = WorkspaceSettingsStore(root);
    final path = store.file.absolute.path;
    if (!store.file.existsSync()) {
      return (path: path, state: 'missing', error: null);
    }
    try {
      store.readSync();
      return (path: path, state: 'valid', error: null);
    } on Object catch (error) {
      return (path: path, state: 'invalid', error: '$error');
    }
  }

  void _writeConfigLine(({String path, String state, String? error}) config) {
    final label = switch (config.state) {
      'valid' => 'Valid',
      'invalid' => 'Invalid: ${config.error}',
      _ => 'Missing',
    };
    out.writeln('Config:        $label');
  }

  Future<({bool registered, bool running, int? pid})> _localServiceInfo(
    String? dataDir,
  ) async {
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    try {
      final info = await _manager(root).getInfo();
      return (
        registered: info.registration == ServiceInstallationState.registered,
        running: info.process == ServiceRuntimeState.running,
        pid: info.pid,
      );
    } on Object {
      return (registered: false, running: false, pid: null);
    }
  }

  void _writeServiceLines(bool registered, bool running, int? pid,
      {bool hint = true}) {
    out.writeln('Service:       ${registered ? 'Installed' : 'Not installed'}');
    out.writeln(
        'Status:        ${running ? 'Running (pid: $pid)' : 'Stopped'}');
    if (!hint) return;
    if (!registered) {
      out.writeln('Hint:          Run syntila service install');
    } else if (!running) {
      out.writeln('Hint:          Run syntila service start');
    }
  }

  /// Quick probe: is a Workspace service answering on its local socket?
  Future<bool> _serviceReachable(String? dataDir) async {
    try {
      await _send(
        dataDir,
        'service.getHealth',
        {},
        timeout: const Duration(seconds: 3),
      );
      return true;
    } on SocketException {
      return false;
    } on FileSystemException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  String? _ask(String question) {
    final reader = _readLine;
    if (reader != null) return reader(question);
    err.write(question);
    return stdin.readLineSync();
  }

  ({String email, String password}) _promptCredentials() {
    final provided = _readCredentials;
    if (provided != null) return provided();
    final terminal = stdin.hasTerminal;
    if (terminal) err.write('Cloud email: ');
    final email = stdin.readLineSync() ?? '';
    final oldEcho = terminal ? stdin.echoMode : true;
    String password;
    try {
      if (terminal) {
        err.write('Cloud password: ');
        stdin.echoMode = false;
      }
      password = stdin.readLineSync() ?? '';
    } finally {
      if (terminal) {
        stdin.echoMode = oldEcho;
        err.writeln();
      }
    }
    return (email: email, password: password);
  }

  SecureCredentialStore _credentials(Directory root) =>
      _credentialStore ??
      PlatformSecureCredentialStore(
        credentialDirectory: Directory('${root.path}/Credentials'),
      );

  Future<WorkspaceHeadlessAuth> _authHelper(String? dataDir) async {
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final settings = await WorkspaceSettingsStore(root).ensureDefaults();
    return WorkspaceHeadlessAuth(
      dataDirectory: root,
      cloudUrl: WorkspaceConfigurationResolver.cloudHttpOrigin(
        Uri.parse(settings.cloudUrl),
      ),
      credentialStore: _credentials(root),
      // The CLI runs without a runtime; a running service reloads itself.
      reloadRuntime: () async {},
      clientFactory: _authClientFactory,
    );
  }

  /// Email/password sign-in. It only stores the management session on this
  /// computer; it does not register a Workspace (see [_register]).
  Future<int> _login(String? dataDir, bool json) async {
    try {
      final credentials = _promptCredentials();
      if (credentials.email.trim().isEmpty || credentials.password.isEmpty) {
        err.writeln('Cloud email and password are required.');
        return 64;
      }
      final auth = await _authHelper(dataDir);
      final status = await auth.signIn(
        email: credentials.email,
        password: credentials.password,
      );
      if (status['phase'] == 'complete') {
        if (json) {
          _print({'signedIn': true}, true);
        } else {
          out.writeln('Signed in.');
        }
        return 0;
      }
      _print(status, json);
      err.writeln(
        'Sign-in failed: ${status['message'] ?? 'unknown error'}'
        '${status['code'] == null ? '' : ' (${status['code']})'}',
      );
      return 1;
    } on WorkspaceManagerProtocolException catch (error) {
      err.writeln('syntila: ${error.message} (${error.code})');
      return 1;
    } on Object catch (error) {
      // Never render the exception text: it may contain the login payload.
      err.writeln('Sign-in failed (${error.runtimeType}).');
      return 1;
    }
  }

  /// Registers this Workspace with Cloud using the stored sign-in. A running
  /// service performs it itself (and reloads); otherwise the CLI does.
  Future<int> _register(String? dataDir, bool json) async {
    try {
      // workspace.nano names the Workspace; registration reads the name from
      // the lifecycle preferences.
      final root = WorkspaceConfigurationResolver.resolveDataDirectory([
        if (dataDir != null) ...['--data-dir', dataDir],
      ]);
      final name = WorkspaceSettingsStore(root).readSync()?.workspaceName;
      if (name != null && name.trim().isNotEmpty) {
        final preferences = WorkspaceLifecyclePreferencesStore(root);
        await preferences.write(
          preferences.readSync().copyWith(customWorkspaceName: name.trim()),
        );
      }
      final Map<String, Object?> status;
      final serviceRunning = await _serviceReachable(dataDir);
      if (serviceRunning) {
        // Registration needs Cloud disconnected (unregister leaves it so).
        await _send(dataDir, 'connection.disconnect', {});
        final result = await _send(dataDir, 'auth.register', {});
        status = result is Map
            ? Map<String, Object?>.from(result)
            : const {'phase': 'failed', 'message': 'Unexpected reply.'};
      } else {
        status = await (await _authHelper(dataDir)).register();
      }
      if (status['phase'] == 'complete') {
        await _synchronizeRegistrationSettings(dataDir);
        // A registered Workspace goes online: now if the service runs,
        // otherwise on the next service start.
        await _updateConnectionSetting(dataDir, true);
        if (serviceRunning) {
          try {
            await _send(dataDir, 'connection.connect', {});
          } on Object {
            err.writeln('Registered, but could not connect yet. '
                'Run: syntila connect');
          }
        }
        if (json) {
          _print({'registered': true}, true);
        } else {
          out.writeln('Workspace registered.');
        }
        return 0;
      }
      err.writeln(
        'Registration failed: ${status['message'] ?? 'unknown error'}'
        '${status['code'] == null ? '' : ' (${status['code']})'}',
      );
      return 1;
    } on WorkspaceManagerProtocolException catch (error) {
      err.writeln('syntila: ${error.message} (${error.code})');
      return 1;
    } on TimeoutException {
      err.writeln('syntila: service request timed out.');
      return 69;
    } on Object catch (error) {
      err.writeln('Registration failed (${error.runtimeType}).');
      return 1;
    }
  }

  /// First-run setup, in order: stop if a service is already running, make sure
  /// workspace.nano exists, ask for the Workspace name, sign in, register the
  /// Workspace, then offer to start the service.
  Future<int> _setup(String? dataDir, bool json) async {
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    // 1. A running service means this installation is already set up.
    if (await _serviceReachable(dataDir) ||
        (await _localServiceInfo(dataDir)).running) {
      err.writeln(
        'The Workspace service is already running, so setup was not started. '
        'Check it with: syntila status',
      );
      return 1;
    }
    // 2. Config.
    final store = WorkspaceSettingsStore(root);
    if (!store.file.existsSync()) {
      await store.ensureDefaults();
      out.writeln('Config created: ${store.file.absolute.path}');
    }
    final WorkspaceSettings settings;
    try {
      settings = store.readSync()!;
    } on Object catch (error) {
      err.writeln('syntila: invalid workspace.nano: $error');
      return 65;
    }
    // 3. Workspace name (an already registered Workspace keeps its name).
    final registration = WorkspaceRegistrationStore(root).readSync();
    if (registration == null) {
      final answer =
          _ask('Workspace name [${settings.workspaceName}]: ')?.trim();
      final name =
          (answer == null || answer.isEmpty) ? settings.workspaceName : answer;
      if (name.length > 120) {
        err.writeln('Workspace name must be at most 120 characters.');
        return 64;
      }
      if (name != settings.workspaceName) {
        await store.write(settings.copyWith(workspaceName: name));
      }
      // Registration takes its name from the lifecycle preferences.
      final preferences = WorkspaceLifecyclePreferencesStore(root);
      await preferences.write(
        preferences.readSync().copyWith(customWorkspaceName: name),
      );
    }
    // 4. Sign in (skipped when this installation is already registered).
    if (registration == null) {
      var code = await _login(dataDir, json);
      if (code != 0) return code;
      code = await _register(dataDir, json);
      if (code != 0) return code;
    } else {
      out.writeln('Workspace is already registered: ${registration.name}');
    }
    // 5. Offer to start the service.
    final reply =
        _ask('Start the Workspace service now? [Y/n]: ')?.trim().toLowerCase();
    if (reply != null && reply.isNotEmpty && reply != 'y' && reply != 'yes') {
      out.writeln(
        'Setup complete. Start the service when you are ready: '
        'syntila service install && '
        'syntila service start',
      );
      return 0;
    }
    if (await _service(dataDir, 'install', json, quiet: true) != 0 ||
        await _service(dataDir, 'start', json, quiet: true) != 0) {
      return 1;
    }
    var ready = false;
    for (var attempt = 0; attempt < 40; attempt++) {
      try {
        final health = await _send(dataDir, 'service.getHealth', {});
        if (health is Map && health['healthy'] == true) {
          ready = true;
          break;
        }
      } on Object {
        /* Wait for authenticated IPC during startup. */
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!ready) {
      err.writeln(
        'Service did not become healthy. Run syntila status.',
      );
      return 69;
    }
    return _finishConnection(dataDir, json);
  }

  Future<int> _finishConnection(String? dataDir, bool json) async {
    await _send(dataDir, 'connection.connect', {});
    for (var attempt = 0; attempt < 60; attempt++) {
      final snapshot = await _send(dataDir, 'service.getStatus', {});
      if (snapshot is Map &&
          snapshot['cloud'] is Map &&
          (snapshot['cloud'] as Map)['synchronized'] == true) {
        await _updateConnectionSetting(dataDir, true);
        if (json) {
          _print({
            'phase': 'complete',
            'message': 'Workspace is online. Add a Worker to start using it.',
          }, true);
        } else {
          out.writeln('Workspace is online.');
          out.writeln(
            'Next: add a Worker to start using it. '
            'See what is available with: syntila workers catalog, '
            'then run: syntila workers add <type>',
          );
        }
        err.writeln(
          'For startup without login: sudo loginctl enable-linger ${Platform.environment['USER'] ?? '<user>'}',
        );
        return 0;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    err.writeln(
      'Registered, but Cloud is not ready. Run syntila status.',
    );
    return 69;
  }

  /// A Workspace has at most one Worker per type, so commands address Workers
  /// by type. A raw Worker ID is still accepted.
  Future<String?> _workerIdForType(String? dataDir, String type) async {
    final list = await _send(dataDir, 'workers.list', {});
    if (list is! List) return type;
    for (final item in list.whereType<Map>()) {
      if (item['productWorkerTypeId'] == type && item['workerId'] is String) {
        return item['workerId'] as String;
      }
    }
    for (final item in list.whereType<Map>()) {
      if (item['workerId'] == type) return type;
    }
    return null;
  }

  (String, Map<String, Object?>)? _resolve(List<String> a) {
    if (a.isEmpty) return null;
    if (a.length > 3) {
      return null;
    }
    final id = a.length > 2 ? a[2] : null;
    if (id != null &&
        !(a.first == 'workers' ||
            (a.first == 'assignments' && a[1] == 'cancel'))) {
      return null;
    }
    switch ((a[0], a.length > 1 ? a[1] : null)) {
      case ('status', null):
        return ('service.getStatus', {});
      case ('version', null):
        return ('service.getVersion', {});
      case ('connect', null):
        return ('connection.connect', {});
      case ('disconnect', null):
        return ('connection.disconnect', {});
      case ('pause', null):
        return ('connection.pause', {});
      case ('resume', null):
        return ('connection.resume', {});
      case ('workers', null):
        return ('workers.list', {});
      case ('workers', 'catalog') when a.length == 2:
        return ('workers.getCatalogSnapshot', {});
      case ('workers', 'add') when id != null:
        return ('workers.configureWorker', {'workerTypeId': id});
      case ('workers', 'remove') when id != null:
        return ('workers.removeWorker', {'workerId': id});
      case ('workers', 'check'):
        return ('workers.checkReadiness', {if (id != null) 'workerTypeId': id});
      case ('workers', 'test') when id != null:
        return ('workers.testWorker', {'workerId': id});
      case ('workers', 'enable') when id != null:
        return ('workers.enableWorker', {'workerId': id});
      case ('workers', 'disable') when id != null:
        return ('workers.disableWorker', {'workerId': id});
      case ('slots', null):
        return ('execution.getSlots', {});
      case ('assignments', null):
        return ('execution.listActiveAssignments', {});
      case ('assignments', 'cancel') when id != null:
        return ('execution.cancelAssignment', {'assignmentId': id});
      case ('folders', null):
      case ('folders', 'list'):
        return ('folders.list', {});
      case ('metrics', null):
        return ('diagnostics.getMetrics', {});
      case ('logs', null):
        return ('diagnostics.getLogs', {});
    }
    return null;
  }

  Future<Object?> _send(
    String? dataDir,
    String command,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final request = _request;
    if (request != null) return request(command, payload);
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final runtime = Directory('${root.path}/runtime');
    final key = (await File(
      '${runtime.path}/manager-ipc.key',
    ).readAsString())
        .trim();
    final client = await WorkspaceManagerIpcClient.connect(
      socketPath: workspaceManagerEndpoint(runtime),
      key: key,
    );
    try {
      return await client.request(
        command,
        payload: payload,
        timeout: timeout,
      );
    } finally {
      await client.close();
    }
  }

  Future<int> _service(String? dataDir, String action, bool json,
      {bool quiet = false}) async {
    if (!const {
      'install',
      'uninstall',
      'start',
      'stop',
      'restart',
      'status',
    }.contains(action)) {
      err.write(_usage(dataDir));
      return 64;
    }
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final manager = _manager(root);
    try {
      if (action == 'stop' || action == 'restart' || action == 'uninstall') {
        try {
          final info = await manager.getInfo();
          if (info.processRunning) {
            await _send(dataDir, 'service.prepareStop', {});
          }
        } catch (_) {
          // If IPC is already down or unreachable, continue to OS service manager
        }
      }
      final info = await switch (action) {
        'install' => manager.register(),
        'uninstall' => manager.unregister(),
        'start' => manager.start(),
        'stop' => manager.stop(),
        'restart' => manager.restart(),
        _ => manager.getInfo(),
      };
      if (action == 'stop' && info.process == ServiceRuntimeState.running) {
        err.writeln(
          'syntila: the service did not stop in time. '
          'Check again with: syntila service status',
        );
        return 1;
      }
      if (quiet) {
        // Used by reset: no output for intermediate steps.
      } else if (json) {
        _print({
          'registration': info.registration.name,
          'process': info.process.name,
          'pid': info.pid,
        }, true);
      } else {
        final registered =
            info.registration == ServiceInstallationState.registered;
        final running = info.process == ServiceRuntimeState.running;
        final registrationText = registered ? 'Installed' : 'Not installed';
        final processText = running ? 'Running (pid: ${info.pid})' : 'Stopped';
        out.writeln('Service:       $registrationText');
        out.writeln('Status:        $processText');
        if (action != 'status') {
          if (!registered) {
            out.writeln('Hint:          Run syntila service install');
          } else if (!running) {
            out.writeln('Hint:          Run syntila service start');
          }
        }
      }
      return 0;
    } on Object catch (error) {
      err.writeln('syntila: $error');
      return 1;
    }
  }

  Future<int> _config(String? dataDir, String action, bool json) async {
    if (!const {'init', 'show', 'validate', 'path'}.contains(action)) {
      err.write(_usage(dataDir));
      return 64;
    }
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final store = WorkspaceSettingsStore(root);
    try {
      if (action == 'path') {
        out.writeln(store.file.absolute.path);
        return 0;
      }
      if (action == 'init') {
        final path = store.file.absolute.path;
        // Existing file: leave it exactly as it is (not even validated).
        final existed = store.file.existsSync();
        if (!existed) await store.ensureDefaults();
        if (json) {
          _print({'created': !existed, 'path': path}, true);
        } else {
          out.writeln(existed ? 'Config already exists: $path' : path);
        }
        return 0;
      }
      final settings = store.readSync();
      if (settings == null) {
        err.writeln(
          'workspace.nano does not exist. Run syntila config init.',
        );
        return 66;
      }
      if (action == 'show') {
        if (json) {
          _print(settings.toNanoValue(), true);
        } else {
          out.write(store.file.readAsStringSync());
        }
      } else {
        _print({
          'valid': true,
          'path': store.file.absolute.path,
          'version': WorkspaceSettings.schemaVersion,
          'restartRequiredToApply': true,
        }, json);
      }
      return 0;
    } on Object catch (error) {
      err.writeln('syntila: invalid workspace.nano: $error');
      return 65;
    }
  }

  Future<void> _synchronizeRegistrationSettings(String? dataDir) async {
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final registration = WorkspaceRegistrationStore(root).readSync();
    if (registration == null) return;
    final store = WorkspaceSettingsStore(root);
    final settings = await store.ensureDefaults();
    await store.write(
      settings.copyWith(
        cloudUrl: registration.cloudUrl,
        workspaceName: registration.name,
      ),
    );
  }

  Future<void> _updateConnectionSetting(String? dataDir, bool connected) async {
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final store = WorkspaceSettingsStore(root);
    final settings = await store.ensureDefaults();
    if (settings.connectOnStart != connected) {
      await store.write(settings.copyWith(connectOnStart: connected));
    }
  }

  Future<int> _folders(String? dataDir, List<String> args, bool json) async {
    if (args.isEmpty) {
      err.write(_usage(dataDir));
      return 64;
    }
    final action = args[0];
    if (action == 'remove' && args.length == 2) {
      try {
        final result =
            await _send(dataDir, 'folders.remove', {'folderId': args[1]});
        _print(result, json);
        return 0;
      } on WorkspaceManagerProtocolException catch (error) {
        err.writeln('syntila: ${error.message} (${error.code})');
        return 1;
      }
    }
    if (action == 'add' && args.length >= 2) {
      final path = args[1];
      String? name;
      for (var i = 2; i < args.length; i++) {
        if (args[i] == '--name' && i + 1 < args.length) {
          name = args[++i];
        }
      }
      try {
        final result = await _send(dataDir, 'folders.add', {
          'path': path,
          if (name != null) 'displayName': name,
        });
        _print(result, json);
        return 0;
      } on WorkspaceManagerProtocolException catch (error) {
        err.writeln('syntila: ${error.message} (${error.code})');
        return 1;
      }
    }
    err.write(_usage(dataDir));
    return 64;
  }

  void _printCatalogSummary(Map<String, Object?> snapshot) {
    final descriptors = snapshot['descriptors'] as List? ?? const [];
    if (descriptors.isEmpty) {
      out.writeln('No catalog workers available.');
      return;
    }
    for (final item in descriptors) {
      if (item is! Map) continue;
      final typeId = item['workerTypeId'] ?? item['id'] ?? '';
      if (typeId.toString().isNotEmpty) out.writeln(typeId);
    }
  }

  Future<int> _workDir(String? dataDir, List<String> args, bool json) async {
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final store = WorkspaceSettingsStore(root);
    final settings = await store.ensureDefaults();
    if (args.isEmpty) {
      if (json) {
        _print({'workRoot': settings.workRoot}, true);
      } else {
        out.writeln(settings.workRoot);
      }
      return 0;
    }
    if (args.length == 1) {
      final rawPath = args[0].trim();
      if (rawPath.isEmpty) {
        err.writeln('Path cannot be empty.');
        return 64;
      }
      final resolvedDir = Directory(rawPath).absolute;
      await store.write(settings.copyWith(workRoot: resolvedDir.path));
      if (json) {
        _print({
          'workRoot': resolvedDir.path,
          'restartRequiredToApply': true,
        }, true);
      } else {
        out.writeln('Work Root updated to: ${resolvedDir.path}');
        out.writeln(
            'Note: Restart service to apply changes (syntila service restart).');
      }
      return 0;
    }
    err.write(_usage(dataDir));
    return 64;
  }

  /// Deletes the stored human sign-in session. The Workspace registration, its
  /// runtime credential and a running connection are not touched: use
  /// `unregister` or `reset` for those.
  Future<int> _logout(String? dataDir, bool json) async {
    try {
      final hadSession = await (await _authHelper(dataDir)).signOut();
      if (json) {
        _print({'signedOut': hadSession}, true);
      } else {
        out.writeln(hadSession ? 'Signed out.' : 'Not signed in.');
      }
      return 0;
    } on Object {
      err.writeln('syntila: could not remove the stored session.');
      return 1;
    }
  }

  Future<DesktopHumanSession?> _storedSession(
      SecureCredentialStore store) async {
    try {
      final raw = await store.read(desktopHumanCredentialKey);
      if (raw == null || raw.isEmpty) return null;
      final session = DesktopHumanSession.fromSecureJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return session.expiresAt.isAfter(DateTime.now()) ? session : null;
    } on Object {
      return null;
    }
  }

  /// Cloud accepts a release only for a sign-in from the last 5 minutes.
  bool _isFreshSession(DesktopHumanSession session) {
    final issued = session.issuedAt;
    return issued != null &&
        DateTime.now().difference(issued) < const Duration(minutes: 4);
  }

  /// Returns null on success, otherwise a short reason.
  Future<String?> _releaseFromCloud(
    WorkspaceRegistration registration,
    DesktopHumanSession session,
  ) async {
    final factory =
        _authClientFactory ?? ((url) => DesktopAuthClient(cloudUrl: url));
    final client = factory(registration.cloudUrl);
    try {
      for (var attempt = 0;; attempt++) {
        try {
          await client.releaseWorkspace(
            session: session,
            installationId: registration.installationId,
            workspaceId: registration.workspaceId,
            runtimeId: registration.workspaceRuntimeId,
          );
          return null;
        } on StateError catch (error) {
          // Cloud needs a moment to see the runtime go offline.
          if (error.message.contains('Disconnect the Workspace runtime') &&
              attempt < 4) {
            await Future<void>.delayed(const Duration(seconds: 2));
            continue;
          }
          return error.message;
        }
      }
    } on Object catch (error) {
      return 'Could not reach Cloud (${error.runtimeType}).';
    } finally {
      client.close();
    }
  }

  Future<int> _unregister(String? dataDir, bool json,
      {bool quiet = false}) async {
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final registrationStore = WorkspaceRegistrationStore(root);
    final registration = registrationStore.readSync();
    if (registration == null) {
      if (quiet) {
        return 0;
      }
      if (json) {
        _print({
          'unregistered': false,
          'message': 'No workspace registration found.'
        }, true);
      } else {
        out.writeln('No workspace registration found.');
      }
      return 0;
    }

    final store = _credentials(root);

    // 1. Cloud only releases a Workspace whose runtime is offline, so
    //    disconnect first (a running service is told to; no service is fine).
    if (await _serviceReachable(dataDir)) {
      try {
        await _send(dataDir, 'connection.disconnect', {});
      } on WorkspaceManagerProtocolException catch (error) {
        if (!quiet) {
          err.writeln('syntila: ${error.message} (${error.code})');
          return 1;
        }
      } on Object {
        // reset continues even when the service cannot be told.
      }
    }

    // 2. Cloud requires a sign-in from the last few minutes to release.
    var session = await _storedSession(store);
    if ((session == null || !_isFreshSession(session)) && !quiet) {
      err.writeln('A fresh Cloud sign-in is needed to release this Workspace.');
      final credentials = _promptCredentials();
      if (credentials.email.trim().isEmpty || credentials.password.isEmpty) {
        err.writeln('Cloud email and password are required.');
        return 64;
      }
      final status = await (await _authHelper(dataDir)).signIn(
        email: credentials.email,
        password: credentials.password,
      );
      if (status['phase'] != 'complete') {
        err.writeln(
          'Sign-in failed: ${status['message'] ?? 'unknown error'}'
          '${status['code'] == null ? '' : ' (${status['code']})'}',
        );
        return 1;
      }
      session = await _storedSession(store);
    }

    // 3. Release in Cloud. An explicit unregister stops here if Cloud refuses,
    //    so the local and Cloud state never disagree; reset continues anyway.
    String? failure;
    if (session != null) {
      failure = await _releaseFromCloud(registration, session);
    } else if (!quiet) {
      failure = 'No Cloud sign-in is available.';
    }
    if (failure != null && !quiet) {
      err.writeln('Cloud did not release this Workspace: $failure');
      err.writeln('Nothing was changed on this computer. '
          'Fix the problem and run: syntila unregister');
      return 1;
    }

    // 4. Only the registration is forgotten. Workers and folders are this
    //    computer's setup; the next register publishes them to Cloud again.
    await registrationStore.clear();
    await store.delete(registration.workspaceRuntimeId);

    if (quiet) {
      return 0;
    }
    if (json) {
      _print({
        'unregistered': true,
        'workspaceId': registration.workspaceId,
        'name': registration.name,
      }, true);
    } else {
      out.writeln('Workspace ${registration.name} unregistered.');
      out.writeln('Hint: Run syntila register to register again.');
    }
    return 0;
  }

  Future<int> _reset(String? dataDir, bool json) async {
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    // 1. Unregister from Cloud first if registered
    await _unregister(dataDir, true, quiet: true);

    // 2. Stop and uninstall host service
    try {
      await _service(dataDir, 'stop', true, quiet: true);
    } catch (_) {}
    try {
      await _service(dataDir, 'uninstall', true, quiet: true);
    } catch (_) {}

    // 3. Clear credentials
    try {
      await (await _authHelper(dataDir)).signOut();
    } catch (_) {}

    // 4. Delete runtime files and local registration
    final filesToDelete = [
      'workspace-registration.json',
      'local-workspace-id',
      'configured-workers.json',
      'workspace-lifecycle.json',
      'workspace.lock',
      'workspace.nano',
    ];
    for (final filename in filesToDelete) {
      final f = File('${root.path}${Platform.pathSeparator}$filename');
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    final dirsToDelete = ['runtime', 'logs', 'Credentials'];
    for (final dirname in dirsToDelete) {
      final d = Directory('${root.path}${Platform.pathSeparator}$dirname');
      if (d.existsSync()) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    }

    // Success is silent; errors are reported on stderr.
    return 0;
  }

  void _printStatusSummary(Map<String, Object?> snapshot) {
    final workspace =
        snapshot['workspace'] as Map<String, Object?>? ?? const {};
    final cloud = snapshot['cloud'] as Map<String, Object?>? ?? const {};
    final service = snapshot['service'] as Map<String, Object?>? ?? const {};
    final assignments =
        snapshot['assignments'] as Map<String, Object?>? ?? const {};
    final workers = (snapshot['workers'] as List?)?.length ?? 0;

    final name = workspace['name'] ?? 'Workspace';
    final cloudState = cloud['state'] ?? 'offline';
    final connected = cloud['connected'] == true;
    // Connected: show how (the transport). Otherwise show why not (the
    // lifecycle state). Never repeat the Connected/Disconnected word.
    final stateWord = connected ? 'connected' : 'disconnected';
    final rawDetail = connected
        ? cloud['transport']
        : (cloud['lifecycleState'] ?? cloudState);
    final detail = rawDetail?.toString() ?? '';
    final cloudUrl =
        detail.isEmpty || detail.toLowerCase() == stateWord ? '' : detail;
    final workRoot = workspace['workRoot'] ?? 'Not configured';
    final activeCount = assignments['activeCount'] ?? 0;
    final healthy = service['serviceHealthy'] == true;

    out.writeln('Workspace:     $name (${healthy ? 'healthy' : 'unhealthy'})');
    out.writeln('Cloud:         ${connected ? 'Connected' : 'Disconnected'}'
        '${cloudUrl.isEmpty ? '' : ' ($cloudUrl)'}');
    out.writeln('Work Root:     $workRoot');
    out.writeln('Workers:       $workers configured');
    out.writeln('Active Work:   $activeCount running');
  }

  void _printConnectionSummary(String command, Map<String, Object?> snapshot) {
    final cloud = snapshot['cloud'] as Map<String, Object?>? ?? const {};
    final connected = cloud['connected'] == true;
    final state = cloud['lifecycleState'] ?? cloud['state'] ?? 'offline';
    final accepting = cloud['acceptingNewWork'] == true;

    switch (command) {
      case 'connection.connect' || 'connection.reconnect':
        out.writeln(connected
            ? 'Cloud:         Connected ($state)'
            : 'Cloud:         Connecting ($state)...');
      case 'connection.disconnect':
        out.writeln('Cloud:         Disconnected');
      case 'connection.pause':
        out.writeln('Cloud:         Paused (not accepting new work)');
      case 'connection.resume':
        out.writeln(accepting
            ? 'Cloud:         Resumed (accepting work)'
            : 'Cloud:         Resumed');
      default:
        out.writeln('Cloud:         $state');
    }
  }

  void _print(Object? result, bool json) {
    if (result is Map && result['text'] is String && !json) {
      out.writeln(result['text']);
    } else {
      out.writeln(
        const JsonEncoder.withIndent('  ').convert(result ?? {'ok': true}),
      );
    }
  }
}

class _HelpEntry {
  const _HelpEntry(this.name, this.lines, {this.always = false});
  final String name;
  final List<(String, String)> lines;
  final bool always;
}
