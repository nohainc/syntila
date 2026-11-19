import 'dart:io';

import 'package:path/path.dart' as p;

/// Runs an OS tool. Injected so lifecycle tests never touch the real service
/// manager.
abstract class CommandRunner {
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String> environment = const {},
  });
}

class CommandResult {
  const CommandResult(this.exitCode, [this.stdout = '', this.stderr = '']);
  final int exitCode;
  final String stdout;
  final String stderr;
}

class ProcessCommandRunner implements CommandRunner {
  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String> environment = const {},
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      environment: environment.isEmpty ? null : environment,
    );
    return CommandResult(
      result.exitCode,
      '${result.stdout}',
      '${result.stderr}',
    );
  }
}

/// What an OS service needs to run one Agent. Every Agent gets its own service
/// with its own data directory; none is shared.
class ServiceSpec {
  const ServiceSpec({
    required this.workerId,
    required this.executable,
    required this.dataDir,
    this.autoStart = false,
    this.runAsUser,
  });

  final String workerId;
  final String executable;
  final String dataDir;

  /// Opt-in. Without it the service is installed but only starts when asked.
  final bool autoStart;

  /// A dedicated OS user (the "separate OS user" install). The service is then
  /// installed system-wide and needs administrator rights.
  final String? runAsUser;

  List<String> get arguments => ['run', '--data-dir', dataDir];

  /// Ids are restricted before they reach a file name or a service name.
  String get safeId {
    final id = workerId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    if (id.isEmpty || id.length > 128) {
      throw ArgumentError('the Worker id cannot name a service');
    }
    return id;
  }

  String get launchdLabel => 'io.syntila.worker.$safeId';
  String get systemdName => 'syntila-worker-$safeId.service';
  String get windowsTaskName => 'Syntila Worker $safeId';
}

enum ServiceState { notInstalled, stopped, running }

class ServiceStatus {
  const ServiceStatus(this.state, {this.autoStart = false});
  final ServiceState state;
  final bool autoStart;
}

abstract class ServiceManager {
  Future<void> install(ServiceSpec spec);
  Future<void> start(ServiceSpec spec);
  Future<void> stop(ServiceSpec spec);
  Future<void> uninstall(ServiceSpec spec);
  Future<ServiceStatus> status(ServiceSpec spec);
}

String _xml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// The launchd property list for [spec]. `RunAtLoad` is the auto-start switch.
String launchdPlist(ServiceSpec spec, {String? logPath}) {
  final arguments = [
    spec.executable,
    ...spec.arguments,
  ].map((a) => '    <string>${_xml(a)}</string>').join('\n');
  return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${_xml(spec.launchdLabel)}</string>
  <key>ProgramArguments</key>
  <array>
$arguments
  </array>
  <key>RunAtLoad</key>
  <${spec.autoStart ? 'true' : 'false'}/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
${spec.runAsUser == null ? '' : '  <key>UserName</key>\n  <string>${_xml(spec.runAsUser!)}</string>\n'}${logPath == null ? '' : '  <key>StandardErrorPath</key>\n  <string>${_xml(logPath)}</string>\n'}</dict>
</plist>
''';
}

String _systemdQuote(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// The systemd unit for [spec]. Auto-start is `systemctl enable`, not
/// something the unit file decides, so a unit alone never starts at boot.
String systemdUnit(ServiceSpec spec) {
  final command = [
    spec.executable,
    ...spec.arguments,
  ].map(_systemdQuote).join(' ');
  final system = spec.runAsUser != null;
  return '''[Unit]
Description=Syntila Worker Agent ${spec.safeId}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$command
Restart=on-failure
RestartSec=5
${system ? 'User=${spec.runAsUser}\n' : ''}NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=${system ? 'multi-user.target' : 'default.target'}
''';
}

/// PowerShell for the per-user logon task (ADR-021). Every value arrives in an
/// environment variable, so no Worker id or path is ever spliced into script text.
const windowsTaskScript = r'''
$ErrorActionPreference = 'Stop'
$name = $env:SYNTILA_WORKER_TASK
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
switch ($env:SYNTILA_WORKER_OPERATION) {
  'register' {
    $arguments = 'run --data-dir "' + $env:SYNTILA_WORKER_DATA + '"'
    $action = New-ScheduledTaskAction -Execute $env:SYNTILA_WORKER_EXECUTABLE -Argument $arguments
    $triggers = @()
    if ($env:SYNTILA_WORKER_AUTOSTART -eq 'true') { $triggers += New-ScheduledTaskTrigger -AtLogOn -User $user }
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
  }
  'start' { if (-not $task) { throw 'The Worker service is not registered.' }; Start-ScheduledTask -TaskName $name }
  'stop' { if ($task) { Stop-ScheduledTask -TaskName $name } }
  'unregister' { if ($task) { Unregister-ScheduledTask -TaskName $name -Confirm:$false } }
}
$task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
@{ registered = [bool]$task; running = [bool]($task -and $task.State -eq 'Running'); autoStart = [bool]($task -and $task.Triggers.Count -gt 0) } | ConvertTo-Json -Compress
''';

class LaunchdServiceManager implements ServiceManager {
  LaunchdServiceManager(this.runner, {required this.home, required this.uid});

  final CommandRunner runner;
  final String home;
  final int uid;

  File _plist(ServiceSpec spec) => File(
    spec.runAsUser == null
        ? p.join(home, 'Library', 'LaunchAgents', '${spec.launchdLabel}.plist')
        : '/Library/LaunchDaemons/${spec.launchdLabel}.plist',
  );

  String _domain(ServiceSpec spec) =>
      spec.runAsUser == null ? 'gui/$uid' : 'system';

  @override
  Future<void> install(ServiceSpec spec) async {
    final file = _plist(spec);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      launchdPlist(
        spec,
        logPath: p.join(spec.dataDir, 'traces', 'service.log'),
      ),
      flush: true,
    );
    if (spec.autoStart) await start(spec);
  }

  @override
  Future<void> start(ServiceSpec spec) async {
    final result = await runner.run('launchctl', [
      'bootstrap',
      _domain(spec),
      _plist(spec).path,
    ]);
    // 5 means "already loaded", which is fine.
    if (result.exitCode != 0 && result.exitCode != 5) {
      throw StateError('launchctl bootstrap failed (${result.exitCode})');
    }
  }

  @override
  Future<void> stop(ServiceSpec spec) async {
    await runner.run('launchctl', [
      'bootout',
      '${_domain(spec)}/${spec.launchdLabel}',
    ]);
  }

  @override
  Future<void> uninstall(ServiceSpec spec) async {
    await stop(spec);
    final file = _plist(spec);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<ServiceStatus> status(ServiceSpec spec) async {
    final file = _plist(spec);
    if (!await file.exists()) {
      return const ServiceStatus(ServiceState.notInstalled);
    }
    final auto = (await file.readAsString()).contains(
      '<key>RunAtLoad</key>\n  <true/>',
    );
    final result = await runner.run('launchctl', [
      'print',
      '${_domain(spec)}/${spec.launchdLabel}',
    ]);
    return ServiceStatus(
      result.exitCode == 0 ? ServiceState.running : ServiceState.stopped,
      autoStart: auto,
    );
  }
}

class SystemdServiceManager implements ServiceManager {
  SystemdServiceManager(this.runner, {required this.home});

  final CommandRunner runner;
  final String home;

  File _unit(ServiceSpec spec) => File(
    spec.runAsUser == null
        ? p.join(home, '.config', 'systemd', 'user', spec.systemdName)
        : '/etc/systemd/system/${spec.systemdName}',
  );

  List<String> _args(ServiceSpec spec, List<String> rest) => [
    if (spec.runAsUser == null) '--user',
    ...rest,
  ];

  @override
  Future<void> install(ServiceSpec spec) async {
    final file = _unit(spec);
    await file.parent.create(recursive: true);
    await file.writeAsString(systemdUnit(spec), flush: true);
    await runner.run('systemctl', _args(spec, ['daemon-reload']));
    if (spec.autoStart) {
      await runner.run('systemctl', _args(spec, ['enable', spec.systemdName]));
    } else {
      await runner.run('systemctl', _args(spec, ['disable', spec.systemdName]));
    }
  }

  @override
  Future<void> start(ServiceSpec spec) async {
    final result = await runner.run(
      'systemctl',
      _args(spec, ['start', spec.systemdName]),
    );
    if (result.exitCode != 0) {
      throw StateError('systemctl start failed (${result.exitCode})');
    }
  }

  @override
  Future<void> stop(ServiceSpec spec) async {
    await runner.run('systemctl', _args(spec, ['stop', spec.systemdName]));
  }

  @override
  Future<void> uninstall(ServiceSpec spec) async {
    await stop(spec);
    await runner.run('systemctl', _args(spec, ['disable', spec.systemdName]));
    final file = _unit(spec);
    if (await file.exists()) await file.delete();
    await runner.run('systemctl', _args(spec, ['daemon-reload']));
  }

  @override
  Future<ServiceStatus> status(ServiceSpec spec) async {
    if (!await _unit(spec).exists()) {
      return const ServiceStatus(ServiceState.notInstalled);
    }
    final active = await runner.run(
      'systemctl',
      _args(spec, ['is-active', spec.systemdName]),
    );
    final enabled = await runner.run(
      'systemctl',
      _args(spec, ['is-enabled', spec.systemdName]),
    );
    return ServiceStatus(
      active.exitCode == 0 ? ServiceState.running : ServiceState.stopped,
      autoStart: enabled.exitCode == 0,
    );
  }
}

class WindowsServiceManager implements ServiceManager {
  WindowsServiceManager(this.runner);

  final CommandRunner runner;

  Future<CommandResult> _task(ServiceSpec spec, String operation) => runner.run(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-Command', windowsTaskScript],
    environment: {
      'SYNTILA_WORKER_TASK': spec.windowsTaskName,
      'SYNTILA_WORKER_OPERATION': operation,
      'SYNTILA_WORKER_EXECUTABLE': spec.executable,
      'SYNTILA_WORKER_DATA': spec.dataDir,
      'SYNTILA_WORKER_AUTOSTART': '${spec.autoStart}',
    },
  );

  @override
  Future<void> install(ServiceSpec spec) async {
    if (spec.runAsUser != null) {
      throw UnsupportedError(
        'a separate Windows user needs an administrator-created task; see the isolation notes',
      );
    }
    final result = await _task(spec, 'register');
    if (result.exitCode != 0) throw StateError('registering the task failed');
  }

  @override
  Future<void> start(ServiceSpec spec) async {
    final result = await _task(spec, 'start');
    if (result.exitCode != 0) throw StateError('starting the task failed');
  }

  @override
  Future<void> stop(ServiceSpec spec) async {
    await _task(spec, 'stop');
  }

  @override
  Future<void> uninstall(ServiceSpec spec) async {
    await _task(spec, 'unregister');
  }

  @override
  Future<ServiceStatus> status(ServiceSpec spec) async {
    final result = await _task(spec, 'status');
    final out = result.stdout;
    if (!out.contains('"registered":true')) {
      return const ServiceStatus(ServiceState.notInstalled);
    }
    return ServiceStatus(
      out.contains('"running":true')
          ? ServiceState.running
          : ServiceState.stopped,
      autoStart: out.contains('"autoStart":true'),
    );
  }
}

ServiceManager serviceManagerFor({
  required CommandRunner runner,
  required String operatingSystem,
  required Map<String, String> environment,
  required int uid,
}) {
  final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '.';
  switch (operatingSystem) {
    case 'macos':
      return LaunchdServiceManager(runner, home: home, uid: uid);
    case 'windows':
      return WindowsServiceManager(runner);
    default:
      return SystemdServiceManager(runner, home: home);
  }
}

/// Commands an administrator runs to create the dedicated OS user. The Agent
/// never elevates itself, so `install --separate-user` prints these.
List<String> separateUserCommands(String operatingSystem, String userName) {
  final user = userName.replaceAll(RegExp(r'[^a-z0-9_-]'), '');
  switch (operatingSystem) {
    case 'macos':
      return [
        'sudo sysadminctl -addUser $user -home /Users/$user -shell /usr/bin/false',
      ];
    case 'windows':
      return [
        'net user $user /add /passwordreq:yes',
        'icacls "<data-dir>" /inheritance:r /grant "$user:(OI)(CI)F"',
      ];
    default:
      return [
        'sudo useradd --system --create-home --shell /usr/sbin/nologin $user',
      ];
  }
}

/// What a separate OS user does and does not protect. Printed by the CLI and
/// repeated in docs/specifications/WORKER_AGENT_CLI_AND_SERVICES.md.
const isolationNotes = '''
Agents that run as the same OS user are not isolated from each other: they can
read each other's data directories and share the provider CLIs' stored logins.
A separate OS user closes that gap for files and credentials, but it does not
isolate CPU, memory, the network or the user's own folders that the Agent is
allowed to use. Use containers or virtual machines for stronger isolation.''';
