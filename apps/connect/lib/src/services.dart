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
  });

  final String workerId;
  final String executable;
  final String dataDir;

  /// Opt-in. Without it the service is installed but only starts when asked.
  final bool autoStart;

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
  Future<void> restart(ServiceSpec spec);
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
${logPath == null ? '' : '  <key>StandardErrorPath</key>\n  <string>${_xml(logPath)}</string>\n'}</dict>
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
  return '''[Unit]
Description=Syntila Connect ${spec.safeId}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$command
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
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
    p.join(home, 'Library', 'LaunchAgents', '${spec.launchdLabel}.plist'),
  );

  String get _domain => 'gui/$uid';

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
      _domain,
      _plist(spec).path,
    ]);
    // 5 means "already loaded", which is fine.
    if (result.exitCode != 0 && result.exitCode != 5) {
      throw StateError('launchctl bootstrap failed (${result.exitCode})');
    }
    final kick = await runner.run('launchctl', [
      'kickstart',
      '$_domain/${spec.launchdLabel}',
    ]);
    if (kick.exitCode != 0) {
      throw StateError('launchctl kickstart failed (${kick.exitCode})');
    }
  }

  @override
  Future<void> stop(ServiceSpec spec) async {
    await runner.run('launchctl', ['bootout', '$_domain/${spec.launchdLabel}']);
  }

  @override
  Future<void> restart(ServiceSpec spec) async {
    final loaded = await runner.run('launchctl', [
      'print',
      '$_domain/${spec.launchdLabel}',
    ]);
    if (loaded.exitCode == 0) {
      final kick = await runner.run('launchctl', [
        'kickstart',
        '-k',
        '$_domain/${spec.launchdLabel}',
      ]);
      if (kick.exitCode != 0) {
        throw StateError('launchctl kickstart failed (${kick.exitCode})');
      }
      return;
    }
    await start(spec);
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
      '$_domain/${spec.launchdLabel}',
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

  File _unit(ServiceSpec spec) =>
      File(p.join(home, '.config', 'systemd', 'user', spec.systemdName));

  List<String> _args(List<String> rest) => ['--user', ...rest];

  @override
  Future<void> install(ServiceSpec spec) async {
    final file = _unit(spec);
    await file.parent.create(recursive: true);
    await file.writeAsString(systemdUnit(spec), flush: true);
    await runner.run('systemctl', _args(['daemon-reload']));
    if (spec.autoStart) {
      await runner.run('systemctl', _args(['enable', spec.systemdName]));
    } else {
      await runner.run('systemctl', _args(['disable', spec.systemdName]));
    }
  }

  @override
  Future<void> start(ServiceSpec spec) async {
    final result = await runner.run(
      'systemctl',
      _args(['start', spec.systemdName]),
    );
    if (result.exitCode != 0) {
      throw StateError('systemctl start failed (${result.exitCode})');
    }
  }

  @override
  Future<void> stop(ServiceSpec spec) async {
    await runner.run('systemctl', _args(['stop', spec.systemdName]));
  }

  @override
  Future<void> restart(ServiceSpec spec) async {
    final result = await runner.run(
      'systemctl',
      _args(['restart', spec.systemdName]),
    );
    if (result.exitCode != 0) {
      throw StateError('systemctl restart failed (${result.exitCode})');
    }
  }

  @override
  Future<void> uninstall(ServiceSpec spec) async {
    await stop(spec);
    await runner.run('systemctl', _args(['disable', spec.systemdName]));
    final file = _unit(spec);
    if (await file.exists()) await file.delete();
    await runner.run('systemctl', _args(['daemon-reload']));
  }

  @override
  Future<ServiceStatus> status(ServiceSpec spec) async {
    if (!await _unit(spec).exists()) {
      return const ServiceStatus(ServiceState.notInstalled);
    }
    final active = await runner.run(
      'systemctl',
      _args(['is-active', spec.systemdName]),
    );
    final enabled = await runner.run(
      'systemctl',
      _args(['is-enabled', spec.systemdName]),
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
  Future<void> restart(ServiceSpec spec) async {
    await stop(spec);
    await start(spec);
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
