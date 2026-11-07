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
import 'package:gui_manifest/gui_manifest.dart'
    show
        CliCommand,
        CliGroup,
        CliHandler,
        CliInvocation,
        CliNode,
        CliSpec,
        GuiCommandKind,
        GuiFormat,
        GuiIcons,
        GuiOutput,
        GuiParamKind,
        GuiParamType,
        GuiParameter,
        GuiView,
        flatUsage,
        manifestFromSpec,
        runCli;

part 'workspace_cli_spec.dart';
part 'workspace_cli_mcp.dart';

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
    this.connectTimeout = const Duration(seconds: 20),
    this.connectPollInterval = const Duration(milliseconds: 250),
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
  final Duration connectTimeout;
  final Duration connectPollInterval;

  late final CliSpec _spec = _buildWorkspaceSpec(this);

  /// Set by [run] for the help text: which Workspace state directory to look
  /// at, and whether `--help --all` was given.
  String? _helpDataDir;
  bool _listAll = false;
  bool? _configExistsOverride;

  /// The GUI manifest as a Nano Markup tree (what `--gui-manifest` prints).
  Map<String, Object> guiManifestTree() => manifestFromSpec(_spec).toTree();

  /// Help text. Which commands are listed depends only on whether
  /// workspace.nano exists (it is not validated here), never on whether the
  /// service is running. [all] lists everything regardless.
  static String usageText({required bool configExists, bool all = false}) {
    final cli = WorkspaceCli(out: StringBuffer(), err: StringBuffer())
      .._configExistsOverride = configExists
      .._listAll = all;
    return cli._usageText();
  }

  String _usageText() {
    final text = flatUsage(
      _spec,
      header: 'Usage: syntila [--data-dir DIR] [--json] <command>',
    );
    if (_showAllCommands()) return text;
    return '$text\n'
        'More commands are available once workspace.nano exists '
        '(run: syntila config init).\n'
        'Use --help --all to list every command.\n';
  }

  /// First-run help lists only the commands needed to get started.
  bool _showAllCommands() =>
      _listAll || (_configExistsOverride ?? _configExists(_helpDataDir));

  static String? _dataDirArg(List<String> args) {
    final index = args.indexOf('--data-dir');
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  Future<int> run(List<String> args) {
    final helpRequested = args.contains('-h') || args.contains('--help');
    _listAll = helpRequested && args.contains('--all');
    _helpDataDir = _dataDirArg(args);
    return runCli(
      _spec,
      _listAll
          ? [
              for (final a in args)
                if (a != '--all') a
            ]
          : args,
      out: out,
      err: err,
    );
  }

  /// Sends [command] to the running service and prints the result. With
  /// [workerType] the Worker of that type (or a raw Worker ID) is looked up
  /// first and sent as `workerId`.
  Future<int> _runService(
    String? dataDir,
    bool json,
    String command,
    Map<String, Object?> payload, {
    String? workerType,
  }) async {
    var call = (command, payload);
    try {
      if (workerType != null) {
        final workerId = await _workerIdForType(dataDir, workerType);
        if (workerId == null) {
          err.writeln('No configured Worker of type "$workerType". '
              'See: syntila workers');
          return 66;
        }
        call = (call.$1, {...call.$2, 'workerId': workerId});
      }
      var result = await _send(
        dataDir,
        call.$1,
        call.$2,
        timeout: const Duration(seconds: 60),
      );
      if (call.$1 == 'connection.connect') {
        result = await _waitForConnection(dataDir, result);
      }
      if (call.$1 == 'connection.connect') {
        await _updateConnectionSetting(dataDir, true);
      } else if (call.$1 == 'connection.disconnect') {
        await _updateConnectionSetting(dataDir, false);
      }
      if (call.$1 == 'connection.connect' &&
          (result is! Map ||
              result['cloud'] is! Map ||
              (result['cloud'] as Map)['connected'] != true ||
              ((result['cloud'] as Map)['connectionStage'] != null &&
                  (result['cloud'] as Map)['connectionStage'] != 'ready'))) {
        if (json) {
          _print(result, true);
        } else {
          final cloud = result is Map && result['cloud'] is Map
              ? result['cloud'] as Map
              : const {};
          err.writeln(
              'Cloud: not connected${cloud['lastError'] == null ? '' : ' (${cloud['lastError']})'}.');
        }
        return 1;
      }
      // A plugin consent document is a valid answer that still needs the
      // person's explicit acceptance, so it exits 3 instead of 0.
      final consentPending = call.$1.startsWith('mcp.') &&
          result is Map &&
          result['consentRequired'] == true;
      if (json && consentPending) {
        _print(result, true);
        return 3;
      }
      if (!json && _printServiceResult(call.$1, result, call.$2)) {
        return consentPending ? 3 : 0;
      }
      if (!json && result is Map<String, Object?>) {
        if (call.$1 == 'service.getVersion' && result['version'] is String) {
          out.writeln(result['version']);
          return 0;
        }
        if (call.$1 == 'service.getStatus') {
          _printStatusSummary(result);
          _writeConfigLine(_configState(dataDir));
          if (_cloudConfigurationChanged(dataDir, result) == true) {
            out.writeln('Cloud config:  Changed; run syntila service restart');
          }
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
        final workerAction = switch (call.$1) {
          'workers.configureWorker' => 'added',
          'workers.removeWorker' => 'removed',
          'workers.enableWorker' => 'enabled',
          'workers.disableWorker' => 'disabled',
          _ => null,
        };
        if (workerAction != null) {
          final type = result['productWorkerTypeId'] ??
              result['workerTypeId'] ??
              workerType ??
              call.$2['workerTypeId'] ??
              'worker';
          final deferred = call.$1 == 'workers.removeWorker' &&
              result['state'] == 'removing';
          out.writeln(deferred
              ? '$type removing after current work finishes'
              : '$type $workerAction');
          if ((call.$1 == 'workers.configureWorker' ||
                  call.$1 == 'workers.enableWorker') &&
              result['readinessState'] != null &&
              result['readinessState'] != 'ready') {
            out.writeln('Readiness: ${result['readinessState']}');
            if (result['readinessIssueCode'] != null) {
              out.writeln('Issue: ${result['readinessIssueCode']}');
            }
          }
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
            'cloudRestartRequired': _cloudConfigurationChanged(dataDir, result),
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

  Future<Object?> _waitForConnection(String? dataDir, Object? initial) async {
    var result = initial;
    final watch = Stopwatch()..start();
    while (result is Map && result['cloud'] is Map) {
      final cloud = result['cloud'] as Map;
      if (cloud['connected'] == true &&
          (cloud['connectionStage'] == null ||
              cloud['connectionStage'] == 'ready')) {
        return result;
      }
      if (watch.elapsed >= connectTimeout) return result;
      await Future<void>.delayed(connectPollInterval);
      result = await _send(dataDir, 'service.getStatus', {});
    }
    return result;
  }

  bool _printServiceResult(
      String command, Object? result, Map<String, Object?> payload) {
    if (command.startsWith('mcp.') && _printMcpResult(command, result)) {
      return true;
    }
    if (command == 'diagnostics.getLogs' &&
        result is Map &&
        result['text'] is String) {
      final value = result['text'] as String;
      out.write(value);
      if (value.isNotEmpty && !value.endsWith('\n')) out.writeln();
      return true;
    }
    if (command == 'workers.list' && result is List) {
      _printWorkers(result);
      return true;
    }
    if (command == 'workers.checkReadiness' && result is Map) {
      final workers = (result['workers'] as List?) ?? const [];
      final requested = payload['workerTypeId'];
      _printWorkers(workers
          .where((worker) =>
              requested == null ||
              (worker is Map && worker['productWorkerTypeId'] == requested))
          .toList());
      return true;
    }
    if (command == 'workers.testWorker' && result is Map) {
      final type = result['productWorkerTypeId'] ?? 'Worker';
      final passed = result['lastLiveTestPassed'];
      out.writeln(
          '$type: ${passed == true ? 'Passed' : passed == false ? 'Failed' : 'Test result unavailable'}');
      if (result['providerToolVersion'] != null) {
        out.writeln('Version: ${result['providerToolVersion']}');
      }
      if (passed == false && result['lastLiveTestIssueCode'] != null) {
        out.writeln('Issue: ${result['lastLiveTestIssueCode']}');
      }
      if (passed == false && result['lastLiveTestDetails'] is String) {
        out.writeln(result['lastLiveTestDetails']);
      }
      return true;
    }
    if (command == 'folders.list' &&
        result is Map &&
        result['folders'] is List) {
      final folders = result['folders'] as List;
      if (folders.isEmpty) out.writeln('No folders configured.');
      for (final folder in folders.whereType<Map>()) {
        _printFolder(folder);
        out.writeln();
      }
      return true;
    }
    if (command == 'execution.listActiveAssignments' && result is Map) {
      final ids = (result['activeAssignmentIds'] as List?) ?? const [];
      if (ids.isEmpty) out.writeln('No active assignments.');
      for (final id in ids) {
        out.writeln(id);
      }
      return true;
    }
    if (command == 'execution.cancelAssignment' && result is Map) {
      final id = payload['assignmentId'];
      out.writeln(result['cancelled'] == true
          ? 'Cancellation requested for $id.'
          : 'Cancellation was not requested for $id; it may no longer be active.');
      return true;
    }
    if (command == 'execution.getSlots' && result is Map) {
      _printFields({
        'active': result['active'] ?? 0,
        'queued': result['queued'] ?? 0,
        'limit': result['limit'] ?? 'unknown'
      });
      for (final worker
          in ((result['workers'] as List?) ?? const []).whereType<Map>()) {
        out.writeln();
        _printFields({
          'worker': worker['workerTypeId'] ?? 'unknown',
          'active': worker['active'] ?? 0,
          'queued': worker['queued'] ?? 0,
          if (worker['limit'] != null) 'limit': worker['limit']
        });
      }
      return true;
    }
    if (command == 'diagnostics.getMetrics' && result is Map) {
      final bytes = result['residentMemoryBytes'];
      _printFields({
        'Process ID': result['processId'] ?? 'unknown',
        'Resident memory': bytes is num
            ? '${(bytes / 1048576).toStringAsFixed(1)} MiB'
            : 'unknown',
        'CPU percent': result['cpuPercent'] ?? 'unknown',
        'Sampled at': result['sampledAt'] ?? 'unknown',
        'Active assignments': result['activeAssignments'] ?? 0,
        'Workers': result['workerCount'] ?? 0,
        'Cloud connected': result['cloudConnected'] ?? false,
        'Reconnects': result['reconnectCount'] ?? 0
      });
      return true;
    }
    return false;
  }

  void _printWorkers(List workers) {
    if (workers.isEmpty) {
      out.writeln('No workers configured.');
      return;
    }
    for (final worker in workers.whereType<Map>()) {
      final type = worker['productWorkerTypeId'] ?? 'Unknown worker';
      final state = worker['activationState'] ?? 'unknown';
      final readiness = worker['readinessState'] ?? 'unknown';
      out.writeln('$type\t$state\t$readiness');
      if (worker['readinessIssueCode'] != null) {
        out.writeln('  Issue: ${worker['readinessIssueCode']}');
      }
    }
  }

  void _printFolder(Map folder) {
    _printFields({
      'Name': folder['displayName'] ?? '',
      'Path': folder['path'] ?? '',
      'Status': folder['status'] ?? 'unknown',
      'ID': folder['id'] ?? ''
    });
  }

  void _printFields(Object? value) {
    final fields = <(String, String)>[];
    void collect(Object? value, String name) {
      if (value is Map && value.isNotEmpty) {
        for (final entry in value.entries) {
          collect(entry.value,
              name.isEmpty ? '${entry.key}' : '$name.${entry.key}');
        }
      } else if (value is List && value.isNotEmpty) {
        for (var i = 0; i < value.length; i++) {
          collect(value[i], '$name[$i]');
        }
      } else {
        fields.add((
          name,
          value == null
              ? ''
              : value is Map
                  ? '{}'
                  : value is List
                      ? '[]'
                      : '$value'
        ));
      }
    }

    collect(value, '');
    const tabWidth = 8;
    final maxLength = fields.fold<int>(
        0, (max, field) => field.$1.length > max ? field.$1.length : max);
    final target = (maxLength ~/ tabWidth + 1) * tabWidth;
    for (final (name, text) in fields) {
      final tabs = target ~/ tabWidth - name.length ~/ tabWidth;
      out.writeln('$name${'\t' * tabs}$text');
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

  bool? _cloudConfigurationChanged(String? dataDir, Map snapshot) {
    final cloud = snapshot['cloud'];
    final active = cloud is Map ? cloud['effectiveUrl'] : null;
    if (active is! String) return null;
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    final desired = WorkspaceSettingsStore(root).readSync();
    if (desired == null) return null;
    return WorkspaceConfigurationResolver.cloudHttpOrigin(Uri.parse(active)) !=
        WorkspaceConfigurationResolver.cloudHttpOrigin(
            Uri.parse(desired.cloudUrl));
  }

  Future<void> _checkCloudConfiguration(String? dataDir) async {
    final snapshot = await _send(dataDir, 'service.getStatus', {});
    final changed =
        snapshot is Map ? _cloudConfigurationChanged(dataDir, snapshot) : null;
    if (changed == null) {
      throw const WorkspaceManagerProtocolException(
        'configuration_unverified',
        'Cannot verify the running service Cloud configuration. '
            'Update and restart the service, then retry.',
      );
    }
    if (changed) {
      throw const WorkspaceManagerProtocolException(
        'configuration_restart_required',
        'Cloud configuration changed since the service started. '
            'Run: syntila service restart',
      );
    }
  }

  String? _ask(String question) {
    final reader = _readLine;
    if (reader != null) return reader(question);
    err.write(question);
    return stdin.readLineSync();
  }

  ({String email, String password}) _promptCredentials({String? email}) {
    final provided = _readCredentials;
    if (provided != null) return provided();
    final terminal = stdin.hasTerminal;
    if (email == null && terminal) err.write('Cloud email: ');
    final enteredEmail = email ?? stdin.readLineSync() ?? '';
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
    return (email: enteredEmail, password: password);
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
  Future<int> _login(String? dataDir, bool json,
      {String? email, bool passwordStdin = false}) async {
    try {
      if (await _serviceReachable(dataDir)) {
        await _checkCloudConfiguration(dataDir);
      }
      final credentials = passwordStdin
          ? (
              email: email ?? '',
              password: _readLine?.call('') ?? stdin.readLineSync() ?? ''
            )
          : _promptCredentials(email: email);
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
      final serviceRunning = await _serviceReachable(dataDir);
      if (serviceRunning) await _checkCloudConfiguration(dataDir);
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
  Future<int> _setup(String? dataDir, bool json,
      {String? workspaceName,
      String? email,
      bool passwordStdin = false}) async {
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
      final answer = (passwordStdin
              ? workspaceName
              : _ask('Workspace name [${settings.workspaceName}]: '))
          ?.trim();
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
      var code = await _login(dataDir, json,
          email: email, passwordStdin: passwordStdin);
      if (code != 0) return code;
      code = await _register(dataDir, json);
      if (code != 0) return code;
    } else {
      out.writeln('Workspace is already registered: ${registration.name}');
    }
    // 5. Offer to start the service.
    final reply = passwordStdin
        ? null
        : _ask('Start the Workspace service now? [Y/n]: ')
            ?.trim()
            .toLowerCase();
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
      if (action == 'stop' && info.process != ServiceRuntimeState.stopped) {
        err.writeln(
          'syntila: the service could not be confirmed stopped. '
          'Check again with: syntila service status',
        );
        return 1;
      }
      if (action == 'uninstall' &&
          info.registration != ServiceInstallationState.notRegistered &&
          info.registration != ServiceInstallationState.serviceMissing) {
        err.writeln(
            'syntila: service removal could not be confirmed (${info.registration.name}).');
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
        final unregistered =
            info.registration == ServiceInstallationState.notRegistered ||
                info.registration == ServiceInstallationState.serviceMissing;
        final running = info.process == ServiceRuntimeState.running;
        if (action == 'status') {
          out.writeln('Service: ${info.registration.name}');
          out.writeln(
              'Status: ${info.process.name}${info.pid == null ? '' : ' (pid: ${info.pid})'}');
          return 0;
        }
        final message = switch (action) {
          'install' => registered
              ? 'Service installed.'
              : 'Service installation state: ${info.registration.name}.',
          'uninstall' => unregistered
              ? 'Service uninstalled.'
              : 'Service installation state: ${info.registration.name}.',
          'start' || 'restart' => running
              ? 'Service running.'
              : 'Service is not running (${info.process.name}).',
          'stop' => !running ? 'Service stopped.' : 'Service is still running.',
          _ =>
            'Service: ${info.registration.name}; process: ${info.process.name}.',
        };
        out.writeln(message);
      }
      return 0;
    } on Object catch (error) {
      err.writeln('syntila: $error');
      return 1;
    }
  }

  Future<int> _config(String? dataDir, String action, bool json) async {
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
        final result = {
          'valid': true,
          'path': store.file.absolute.path,
          'version': WorkspaceSettings.schemaVersion,
          'restartRequiredToApply': true,
        };
        if (json) {
          _print(result, true);
        } else {
          out.writeln('Config is valid.');
          out.writeln('Path: ${result['path']}');
          out.writeln('Restart the service to apply changes.');
        }
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

  Future<int> _foldersRemove(String? dataDir, bool json, String id) async {
    try {
      final result = await _send(dataDir, 'folders.remove', {'folderId': id});
      if (json) {
        _print(result, true);
      } else {
        out.writeln(result is Map && result['removed'] == true
            ? 'Folder allowance $id removed. Files remain on disk.'
            : 'Folder $id was not found.');
      }
      return 0;
    } on WorkspaceManagerProtocolException catch (error) {
      err.writeln('syntila: ${error.message} (${error.code})');
      return 1;
    }
  }

  Future<int> _foldersAdd(
    String? dataDir,
    bool json,
    String path,
    String? name,
  ) async {
    try {
      final result = await _send(dataDir, 'folders.add', {
        'path': path,
        if (name != null) 'displayName': name,
      });
      if (json) {
        _print(result, true);
      } else {
        if (result is Map) {
          out.writeln('Folder added:');
          _printFolder(result);
        } else {
          out.writeln('Folder added.');
        }
      }
      return 0;
    } on WorkspaceManagerProtocolException catch (error) {
      err.writeln('syntila: ${error.message} (${error.code})');
      return 1;
    }
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
    // The command takes at most one path; the parser rejects more.
    throw StateError('work-dir takes at most one argument');
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
        err.writeln('syntila: ${error.message} (${error.code})');
        return 1;
      } on Object catch (error) {
        if (quiet) {
          err.writeln('Could not disconnect before unregistering: $error');
          return 1;
        }
        rethrow;
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
    } else {
      failure = 'No Cloud sign-in is available.';
    }
    if (failure != null) {
      err.writeln('Cloud did not release this Workspace: $failure');
      err.writeln(
          'Local registration was retained. Fix the problem and run: syntila unregister');
      return 1;
    }

    // 4. Only the registration is forgotten. Workers and folders are this
    //    computer's setup; the next register publishes them to Cloud again.
    await store.delete(registration.workspaceRuntimeId);
    await registrationStore.clear();

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
    }
    return 0;
  }

  Future<int> _reset(String? dataDir, bool json) async {
    final root = WorkspaceConfigurationResolver.resolveDataDirectory([
      if (dataDir != null) ...['--data-dir', dataDir],
    ]);
    // Preserve the local registration if Cloud cannot release it.
    try {
      if (await _unregister(dataDir, true, quiet: true) != 0) {
        err.writeln('Reset incomplete: Workspace could not be unregistered.');
        return 1;
      }
    } on Object catch (error) {
      err.writeln(
          'Reset incomplete: Workspace could not be unregistered: $error');
      return 1;
    }
    final failures = <String>[];
    for (final action in ['stop', 'uninstall']) {
      try {
        if (await _service(dataDir, action, true, quiet: true) != 0) {
          failures.add('service $action');
        }
      } on Object catch (error) {
        failures.add('service $action: $error');
      }
      if (failures.isNotEmpty) break;
    }
    // Do not remove runtime state while the service may still own it.
    if (failures.isNotEmpty) {
      err.writeln('Reset incomplete: ${failures.join('; ')}.');
      return 1;
    }
    try {
      await (await _authHelper(dataDir)).signOut();
    } on Object catch (error) {
      failures.add('sign out: $error');
    }

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
        } on Object catch (error) {
          failures.add('$filename: $error');
        }
      }
    }
    final dirsToDelete = ['runtime', 'logs', 'Credentials'];
    for (final dirname in dirsToDelete) {
      final d = Directory('${root.path}${Platform.pathSeparator}$dirname');
      if (d.existsSync()) {
        try {
          d.deleteSync(recursive: true);
        } on Object catch (error) {
          failures.add('$dirname: $error');
        }
      }
    }

    if (failures.isNotEmpty) {
      err.writeln('Reset incomplete: ${failures.join('; ')}.');
      return 1;
    }
    if (json) {
      _print({'reset': true}, true);
    } else {
      out.writeln('Workspace reset.');
    }
    return 0;
  }

  void _printStatusSummary(Map<String, Object?> snapshot) {
    final workspace =
        snapshot['workspace'] as Map<String, Object?>? ?? const {};
    final cloud = snapshot['cloud'] as Map<String, Object?>? ?? const {};
    final service = snapshot['service'] as Map<String, Object?>? ?? const {};
    final assignments =
        snapshot['assignments'] as Map<String, Object?>? ?? const {};
    final workers = (snapshot['workers'] as List?) ?? const [];
    final workerTypes = workers
        .whereType<Map>()
        .map((w) => w['productWorkerTypeId'])
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet();

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
    out.writeln(
        'Workers:       ${workerTypes.isEmpty ? (workers.isEmpty ? 'None configured' : 'Types unavailable') : workerTypes.join(', ')}');
    out.writeln('Active Work:   $activeCount running');
  }

  void _printConnectionSummary(String command, Map<String, Object?> snapshot) {
    final cloud = snapshot['cloud'] as Map<String, Object?>? ?? const {};
    final connected = cloud['connected'] == true;
    final state = cloud['lifecycleState'] ?? cloud['state'] ?? 'offline';
    final accepting = cloud['acceptingNewWork'] == true;

    switch (command) {
      case 'connection.connect' || 'connection.reconnect':
        out.writeln(
            connected ? 'Connected' : 'Cloud:         Connecting ($state)...');
      case 'connection.disconnect':
        out.writeln('Disconnected');
      case 'connection.pause':
        out.writeln('Paused (not accepting new work)');
      case 'connection.resume':
        out.writeln(accepting
            ? 'Resumed (accepting work)'
            : 'Not accepting work. Connect to Cloud first.');
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
