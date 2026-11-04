import 'dart:io';

import 'platform_runtime.dart';
import 'workspace_registration_models.dart';

/// Owns the on-disk layout for the Workspace desktop runtime.
///
/// The application data root is private Syntila state. User-owned files are
/// resolved separately by [WorkRootResolver] and never live below this tree.
class WorkspacePaths {
  WorkspacePaths(this.stateDirectory, {PlatformRuntime? platform})
      : platform = platform ?? currentPlatformRuntime;

  final Directory stateDirectory;
  final PlatformRuntime platform;

  static String _join(List<String> parts) => parts.join(Platform.pathSeparator);

  static Directory defaultApplicationDataRoot({PlatformRuntime? platform}) {
    final runtime = platform ?? currentPlatformRuntime;
    if (runtime.operatingSystem == 'macos') {
      return Directory(_join([
        runtime.homeDirectory,
        'Library',
        'Application Support',
        // Local development builds keep their state apart from the
        // production app so registrations and sessions never mix.
        syntilaWorkspaceIsLocalBuild ? 'Syntila Local' : 'Syntila',
      ]));
    }
    if (runtime.operatingSystem == 'windows') {
      final local =
          Platform.isWindows ? Platform.environment['LOCALAPPDATA'] : null;
      if (local == null && Platform.isWindows) {
        throw StateError(
            'LOCALAPPDATA is missing; cannot resolve Workspace state safely');
      }
      return Directory(_join([
        local ?? '${runtime.homeDirectory}/AppData/Local',
        syntilaWorkspaceIsLocalBuild ? 'Syntila Local' : 'Syntila'
      ]));
    }
    final folder = syntilaWorkspaceIsLocalBuild ? '.syntila-local' : '.syntila';
    final legacy =
        Directory('${runtime.homeDirectory}${Platform.pathSeparator}$folder');
    if (runtime.operatingSystem == 'linux') {
      return resolveLinuxStateDirectory(
        legacy: legacy,
        target: linuxXdgStateDirectory(
          homeDirectory: runtime.homeDirectory,
          xdgStateHome:
              Platform.isLinux ? Platform.environment['XDG_STATE_HOME'] : null,
        ),
      );
    }
    return legacy;
  }

  /// `$XDG_STATE_HOME/syntila/workspace` (ADR-021 §2.5). A relative
  /// XDG value is invalid per the XDG spec and falls back to the default.
  static Directory linuxXdgStateDirectory({
    required String homeDirectory,
    String? xdgStateHome,
  }) {
    final base = xdgStateHome != null && xdgStateHome.startsWith('/')
        ? xdgStateHome
        : '$homeDirectory/.local/state';
    return Directory(
        '$base/syntila/${syntilaWorkspaceIsLocalBuild ? 'workspace-local' : 'workspace'}');
  }

  /// Earlier Linux service runs used `~/.syntila`. That root keeps
  /// its authority in place so installation and runtime identities, the
  /// credential, registry, Profiles, and sessions are never moved or forked.
  static Directory resolveLinuxStateDirectory(
          {required Directory legacy, required Directory target}) =>
      legacy.existsSync() ? legacy : target;

  static Directory defaultWorkspaceDirectory({PlatformRuntime? platform}) =>
      Directory(_join([
        defaultApplicationDataRoot(platform: platform).path,
        'Workspace',
      ]));

  static Directory defaultStateDirectory({PlatformRuntime? platform}) {
    final runtime = platform ?? currentPlatformRuntime;
    if (runtime.operatingSystem == 'macos') {
      return Directory(_join([
        defaultWorkspaceDirectory(platform: runtime).path,
        'State',
      ]));
    }
    if (runtime.operatingSystem == 'windows') {
      final target = defaultWorkspaceDirectory(platform: runtime);
      final legacy = Directory(
          '${runtime.homeDirectory}/${syntilaWorkspaceIsLocalBuild ? '.syntila-local' : '.syntila'}');
      return resolveWindowsStateDirectory(legacy: legacy, target: target);
    }
    return defaultApplicationDataRoot(platform: runtime);
  }

  /// Legacy registries can contain absolute paths. Preserve the entire root
  /// until its authority is explicitly selected; never rewrite identities or
  /// move partially understood runtime/session state as a bootstrap shortcut.
  static Directory resolveWindowsStateDirectory(
      {required Directory legacy, required Directory target}) {
    if (legacy.existsSync()) {
      throw StateError(
          'Legacy Windows Workspace state exists at ${legacy.path}. Files were preserved. Set SYNTILA_WORKSPACE_DATA_DIR (or --data-dir for the service) to that root before activation; do not create a replacement Cloud Workspace.');
    }
    return target;
  }

  bool get _usesManagedWindowsLayout =>
      platform.isWindows &&
      _canonicalAbsolute(stateDirectory.path) ==
          _canonicalAbsolute(
              defaultWorkspaceDirectory(platform: platform).path);

  bool get _usesManagedMacLayout {
    if (platform.operatingSystem != 'macos') return false;
    return _canonical(stateDirectory.path) ==
        _canonical(defaultStateDirectory(platform: platform).path);
  }

  Directory get applicationSupportDirectory => _usesManagedMacLayout
      ? defaultWorkspaceDirectory(platform: platform)
      : stateDirectory;

  /// The Workspace application's private subtree within the family root.
  Directory get workspaceDirectory => applicationSupportDirectory;

  /// Immutable plugin store, registry, plugin data and entitlement lease.
  Directory get pluginsDirectory =>
      Directory('${applicationSupportDirectory.path}/Plugins');

  /// The application-family root shared by Workspace and future desktop apps.
  Directory get applicationDataRoot =>
      (_usesManagedMacLayout || _usesManagedWindowsLayout)
          ? defaultApplicationDataRoot(platform: platform)
          : stateDirectory;

  /// Ensures private application state and user-owned files cannot share a
  /// directory tree. A nested path would make a runtime reset capable of
  /// reaching user data through an application-data cleanup operation.
  void validateWorkRootSeparation(Directory workRoot) {
    final app = _canonicalAbsolute(applicationDataRoot.path);
    final work = _canonicalAbsolute(workRoot.path);
    final separator = platform.isWindows ? r'\' : Platform.pathSeparator;
    void requireSeparate(String appPath, String workPath) {
      if (appPath == workPath ||
          appPath.startsWith('$workPath$separator') ||
          workPath.startsWith('$appPath$separator')) {
        throw StateError(
            'Application Data Root and Work Root must be separate directories');
      }
    }

    requireSeparate(app, work);
    // Windows junctions and 8.3 names can identify the same directory through
    // different text paths. Admission compares physical roots once they exist.
    if (applicationDataRoot.existsSync() && workRoot.existsSync()) {
      requireSeparate(
          _canonicalAbsolute(applicationDataRoot.resolveSymbolicLinksSync()),
          _canonicalAbsolute(workRoot.resolveSymbolicLinksSync()));
    }
  }

  File installationLockFile(String? installationIdentity) {
    final identity =
        installationIdentity?.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_') ??
            'unidentified';
    return File('${stateDirectory.path}/installation-$identity.lock');
  }

  /// Private state owned by each configured logical Worker.
  Directory get workersDirectory =>
      Directory('${applicationSupportDirectory.path}/Workers');

  /// Immutable Worker Profile material managed independently of Engines.
  Directory get profilesDirectory =>
      Directory('${applicationSupportDirectory.path}/Profiles');

  /// Materialized app-bundled generic Engine executables.
  Directory get enginesDirectory =>
      Directory('${applicationSupportDirectory.path}/Engines');

  /// Service process state, local IPC endpoint, and other private runtime
  /// coordination metadata. No user work files belong below this directory.
  Directory get runtimeDirectory =>
      Directory('${stateDirectory.path}${Platform.pathSeparator}runtime');

  /// Private metadata that binds user-visible Space directories to Space IDs.
  Directory get spaceDirectoryRegistryDirectory =>
      Directory('${applicationSupportDirectory.path}/Registry');

  Directory workerStateDirectory(String workerId) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(workerId) ||
        workerId == '.' ||
        workerId == '..') {
      throw ArgumentError.value(workerId, 'workerId', 'invalid Worker ID');
    }
    return Directory(
      '${workersDirectory.path}${Platform.pathSeparator}$workerId'
      '${Platform.pathSeparator}state',
    );
  }

  Directory get updatesDirectory => _usesManagedMacLayout
      ? Directory('${applicationSupportDirectory.path}/Updates')
      : Directory('${stateDirectory.path}/updates');

  Directory get logsDirectory {
    if (!_usesManagedMacLayout) {
      return Directory('${stateDirectory.path}/logs');
    }
    return Directory(_join([
      platform.homeDirectory,
      'Library',
      'Logs',
      'Syntila Workspace',
    ]));
  }

  File get logsFile => File('${logsDirectory.path}/workspace.log');

  Future<void> prepareRuntimeDirectories() async {
    if (_usesManagedMacLayout) {
      await applicationSupportDirectory.create(recursive: true);
      await platform.restrictPermissions(
        applicationSupportDirectory.path,
        directory: true,
      );
    }
    for (final directory in [
      stateDirectory,
      workersDirectory,
      profilesDirectory,
      enginesDirectory,
      spaceDirectoryRegistryDirectory,
      updatesDirectory,
      logsDirectory,
    ]) {
      await directory.create(recursive: true);
      await platform.restrictPermissions(directory.path, directory: true);
      final probe = File(
        '${directory.path}${Platform.pathSeparator}.write-check-$pid-${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
      } on FileSystemException catch (error) {
        throw StateError(
          'Workspace cannot write to ${directory.path}: ${error.message}',
        );
      }
    }
  }

  static String _canonical(String path) => path.replaceAll(RegExp(r'/+$'), '');

  String _canonicalAbsolute(String path) {
    final value =
        Directory(path).absolute.path.replaceAll(RegExp(r'[/\\]+$'), '');
    return platform.isWindows
        ? value.replaceAll('/', r'\').toLowerCase()
        : value;
  }

  /// Moves the legacy application-managed Work Root into the user Work Root.
  static Future<void> preserveMacWorkRoot({
    PlatformRuntime? platform,
    String? configuredWorkRoot,
  }) async {
    final runtime = platform ?? currentPlatformRuntime;
    if (runtime.operatingSystem != 'macos') return;
    if (configuredWorkRoot != null && configuredWorkRoot.trim().isNotEmpty) {
      return;
    }
    final applicationRoot = defaultApplicationDataRoot(platform: runtime);
    final newWork = Directory(_join([
      runtime.homeDirectory,
      'Documents',
      'Syntila',
    ]));
    final oldWorkRoots = [
      Directory(_join([applicationRoot.path, 'Workspace', 'Work'])),
    ];
    Directory? oldWork;
    for (final candidate in oldWorkRoots) {
      if (await FileSystemEntity.type(candidate.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        oldWork = candidate;
        break;
      }
    }
    if (oldWork != null &&
        await FileSystemEntity.type(newWork.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
      try {
        await newWork.parent.create(recursive: true);
        await oldWork.rename(newWork.path);
      } on FileSystemException {
        // A failed move leaves both locations intact for explicit recovery.
      }
    }
  }
}
