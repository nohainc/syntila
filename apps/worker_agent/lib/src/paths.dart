import 'dart:io';

import 'package:path/path.dart' as p;

/// The private state of one Worker Instance. Every Agent has its own root, so
/// two Agents on one host never share a credential, journal or lock.
class AgentPaths {
  AgentPaths(this.root);

  final Directory root;

  /// Default root: `<application-data>/Syntila/Workers/<worker-id>`.
  factory AgentPaths.forWorker(
    String workerId, {
    Map<String, String>? environment,
    String? operatingSystem,
  }) => AgentPaths(
    Directory(
      p.join(
        applicationDataRoot(
          environment: environment,
          operatingSystem: operatingSystem,
        ),
        'Workers',
        workerId,
      ),
    ),
  );

  static String applicationDataRoot({
    Map<String, String>? environment,
    String? operatingSystem,
  }) {
    final env = environment ?? Platform.environment;
    final os = operatingSystem ?? Platform.operatingSystem;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
    switch (os) {
      case 'macos':
        return p.join(home, 'Library', 'Application Support', 'Syntila');
      case 'windows':
        final base = env['LOCALAPPDATA'] ?? p.join(home, 'AppData', 'Local');
        return p.join(base, 'Syntila');
      default:
        final base = env['XDG_DATA_HOME'] ?? p.join(home, '.local', 'share');
        return p.join(base, 'Syntila');
    }
  }

  Directory get identityDir => Directory(p.join(root.path, 'identity'));
  File get identityFile => File(p.join(identityDir.path, 'identity.json'));
  File get keyFile => File(p.join(identityDir.path, 'key.json'));
  File get nextKeyFile => File(p.join(identityDir.path, 'key.next.json'));
  File get pairingMarker => File(p.join(identityDir.path, 'pairing.pending'));
  File get stateFile => File(p.join(tracesDir.path, 'state.json'));
  File get lockFile => File(p.join(root.path, 'agent.lock'));
  Directory get configDir => Directory(p.join(root.path, 'config'));
  File get configFile => File(p.join(configDir.path, 'config.json'));
  Directory get profilesDir => Directory(p.join(root.path, 'profiles'));
  Directory get registryDir => Directory(p.join(root.path, 'registry'));
  File get foldersFile =>
      File(p.join(registryDir.path, 'allowed-folders.json'));
  File get workRootFile => File(p.join(registryDir.path, 'work-root.json'));
  Directory get commandsDir => Directory(p.join(root.path, 'commands'));
  File get journalFile => File(p.join(commandsDir.path, 'journal.jsonl'));
  Directory get sessionsDir => Directory(p.join(root.path, 'sessions'));
  Directory get tracesDir => Directory(p.join(root.path, 'traces'));
  File get logFile => File(p.join(tracesDir.path, 'agent.log'));
  Directory get engineDir => Directory(p.join(root.path, 'engine'));

  Future<void> ensure() async {
    for (final dir in [
      identityDir,
      configDir,
      profilesDir,
      registryDir,
      commandsDir,
      sessionsDir,
      tracesDir,
      engineDir,
    ]) {
      await dir.create(recursive: true);
    }
    await restrict(identityDir);
  }

  /// Owner-only access on POSIX hosts. Windows relies on the per-user
  /// application-data ACL; see docs/specifications/WORKER_AGENT_CLI_AND_SERVICES.md.
  static Future<void> restrict(FileSystemEntity entity) async {
    if (Platform.isWindows) return;
    final mode = entity is Directory ? '700' : '600';
    await Process.run('chmod', [mode, entity.path]);
  }
}
