import 'dart:io';

import 'profile_lab_cloud_config.dart';

/// Standard, isolated filesystem paths for Syntila Profile Lab on macOS.
///
/// Profile Lab uses its own subtree of the Syntila application-family root,
/// separate from Syntila Connect.
class ProfileLabPaths {
  ProfileLabPaths({String? homeDirectory, Directory? repositoryRoot})
      : _repositoryRoot = repositoryRoot,
        _home = homeDirectory ??
            Platform.environment['HOME'] ??
            Directory.current.path;

  final String _home;
  final Directory? _repositoryRoot;

  /// Application-managed Profile Lab data:
  /// `~/Library/Application Support/Syntila/Profile Lab/`
  ///
  /// Local development builds use `Syntila Local` instead of `Syntila` so
  /// drafts and settings never mix with the production app.
  Directory get applicationSupportDirectory => Directory(
        '$_home/Library/Application Support/'
        '${ProfileLabCloudConfig.isLocalBuild ? 'Syntila Local' : 'Syntila'}'
        '/Profile Lab',
      );

  /// Isolated drafts storage root:
  /// `~/Library/Application Support/Syntila/Profile Lab/drafts/`
  Directory get draftsDirectory =>
      Directory('${applicationSupportDirectory.path}/drafts');

  /// Repository that holds the Profile files. Profile Lab is an internal tool
  /// that reads Profile files from a checkout. Candidates, in order: the
  /// `SYNTILA_REPOSITORY` environment variable, the nearest ancestor of the
  /// current directory or of the running executable, and the checkout
  /// remembered from an earlier run (a release app started from Finder or
  /// `/Applications` has neither). A candidate counts only if it really holds
  /// `apps/profile_lab/assets/profiles`. Tests inject it.
  late final Directory? repositoryRoot =
      _repositoryRoot ?? _findRepository(rememberedRepositoryFile);

  static const _profilesRelativePath = 'apps/profile_lab/assets/profiles';

  /// Checkout path remembered for launches that do not start inside it:
  /// `~/Library/Application Support/Syntila/Profile Lab/repository_root.txt`
  File get rememberedRepositoryFile =>
      File('${applicationSupportDirectory.path}/repository_root.txt');

  /// Worker Profile source files, one per Worker:
  /// `<repository>/apps/profile_lab/assets/profiles/<workerTypeId>.json`
  Directory? get profilesDirectory {
    final root = repositoryRoot;
    return root == null
        ? null
        : Directory('${root.path}/$_profilesRelativePath');
  }

  static bool _holdsProfiles(Directory dir) =>
      FileSystemEntity.typeSync('${dir.path}/$_profilesRelativePath') ==
      FileSystemEntityType.directory;

  Directory? _findRepository(File remembered) {
    final fromEnvironment = Platform.environment['SYNTILA_REPOSITORY'];
    if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
      final dir = Directory(fromEnvironment);
      if (_holdsProfiles(dir)) return dir;
    }
    for (final start in [
      Directory.current.absolute.path,
      File(Platform.resolvedExecutable).parent.absolute.path,
    ]) {
      var dir = Directory(start);
      while (true) {
        if (FileSystemEntity.typeSync('${dir.path}/.git') !=
                FileSystemEntityType.notFound &&
            _holdsProfiles(dir)) {
          try {
            remembered.parent.createSync(recursive: true);
            remembered.writeAsStringSync(dir.path);
          } on Object {
            // Remembering the checkout is best effort.
          }
          return dir;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    try {
      if (remembered.existsSync()) {
        final dir = Directory(remembered.readAsStringSync().trim());
        if (_holdsProfiles(dir)) return dir;
      }
    } on Object {
      // Fall through: no usable remembered checkout.
    }
    return null;
  }

  /// Bundled/cached CLI Worker Engine binaries root:
  /// `~/Library/Application Support/Syntila/Profile Lab/engines/`
  Directory get enginesDirectory =>
      Directory('${applicationSupportDirectory.path}/engines');

  /// Dedicated isolated scratch and execution sandbox root:
  /// `~/Library/Application Support/Syntila/Profile Lab/sandbox/`
  Directory get sandboxDirectory =>
      Directory('${applicationSupportDirectory.path}/sandbox');

  /// Dedicated macOS logging directory:
  /// `~/Library/Logs/syntila.profile_lab/`
  Directory get logsDirectory =>
      Directory('$_home/Library/Logs/syntila.profile_lab');

  /// Legacy credentials root used only to remove or migrate old session files.
  Directory get credentialsDirectory =>
      Directory('${applicationSupportDirectory.path}/credentials');

  /// Legacy session file path. New sessions are stored in macOS Keychain.
  File get sessionFile =>
      File('${credentialsDirectory.path}/profile_lab_session.json');

  /// Non-secret Cloud origin override selected in Profile Lab settings.
  File get cloudSettingsFile =>
      File('${applicationSupportDirectory.path}/cloud_settings.json');

  Directory get legacyApplicationSupportDirectory => Directory(
        '$_home/Library/Application Support/syntila.profile_lab',
      );

  /// Bundle identifier and secure Keychain service namespace.
  static const String bundleIdentifier = 'com.syntila.profile-lab';
  static const String keychainService = 'com.syntila.profile-lab';

  /// Ensures all required application support directories exist with restrictive
  /// POSIX permissions (0700).
  Future<void> ensureDirectoriesExist() async {
    if (await legacyApplicationSupportDirectory.exists() &&
        !await applicationSupportDirectory.exists()) {
      await applicationSupportDirectory.parent.create(recursive: true);
      await legacyApplicationSupportDirectory
          .rename(applicationSupportDirectory.path);
    }
    for (final dir in [
      applicationSupportDirectory,
      draftsDirectory,
      enginesDirectory,
      sandboxDirectory,
      logsDirectory,
    ]) {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      if (Platform.isMacOS || Platform.isLinux) {
        try {
          await Process.run('chmod', ['700', dir.path]);
        } catch (_) {
          // Best effort if permissions are constrained in tests
        }
      }
    }
  }
}
