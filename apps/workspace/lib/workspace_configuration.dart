import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'secure_credentials.dart';
import 'workspace_paths.dart';
import 'platform_runtime.dart';
import 'workspace_settings.dart';
import 'workspace_registration_models.dart' show workspaceAuthOrigin, workspaceBackendOrigin;

/// The inputs consumed by the headless Workspace Service. These values are
/// resolved once at process startup instead of being reread independently by
/// runtime components.
class ResolvedWorkspaceConfiguration {
  const ResolvedWorkspaceConfiguration({
    required this.dataDirectory,
    required this.registration,
    required this.credentials,
    required this.cloudUri,
    required this.workspaceRuntimeId,
    required this.installationId,
    required this.workspaceId,
    required this.workRootPath,
    required this.settings,
    required this.settingsFile,
  });

  final Directory dataDirectory;
  final WorkspaceRegistration? registration;
  final WorkspaceCredentials credentials;
  final Uri? cloudUri;
  final String? workspaceRuntimeId;
  final String? installationId;
  final String? workspaceId;
  final String? workRootPath;
  final WorkspaceSettings settings;
  final File settingsFile;
}

class WorkspaceCredentials {
  const WorkspaceCredentials({this.runtimeToken});

  final String? runtimeToken;
}

class WorkspaceConfigurationResolver {
  const WorkspaceConfigurationResolver();

  ResolvedWorkspaceConfiguration resolve(
    List<String> args, {
    SecureCredentialStore? credentialStore,
    bool ignoreSavedRegistration = false,
  }) {
    final index = args.indexOf('--data-dir');
    final workspaceRuntimeIndex = args.indexOf('--workspace-runtime-id');
    final installationIndex = args.indexOf('--installation-id');
    final workspaceIndex = args.indexOf('--workspace-id');
    final path = index >= 0 && index + 1 < args.length
        ? args[index + 1]
        : Platform.environment['SYNTILA_WORKSPACE_DATA_DIR'];
    final dataDirectory =
        path == null ? WorkspacePaths.defaultStateDirectory() : Directory(path);
    final settingsStore = WorkspaceSettingsStore(dataDirectory);
    final settings = settingsStore.readSync() ??
        WorkspaceSettings.defaults(dataDirectory: dataDirectory);
    final savedRegistration = WorkspaceRegistrationStore(
      dataDirectory,
    ).readSync();
    final registration = ignoreSavedRegistration ? null : savedRegistration;
    // workspace.nano is authoritative. Local builds only differ in the
    // default `config init` / `reset` write (the local Cloud URL).
    final cloudUrl = settings.cloudUrl;
    final workspaceRuntimeId =
        workspaceRuntimeIndex >= 0 && workspaceRuntimeIndex + 1 < args.length
            ? args[workspaceRuntimeIndex + 1]
            : (!ignoreSavedRegistration && registration != null
                ? registration.workspaceRuntimeId
                : Platform.environment['SYNTILA_WORKSPACE_RUNTIME_ID']);
    final installationId =
        installationIndex >= 0 && installationIndex + 1 < args.length
            ? args[installationIndex + 1]
            : (!ignoreSavedRegistration && registration != null
                ? registration.installationId
                : Platform.environment['SYNTILA_WORKSPACE_INSTALLATION_ID'] ??
                    InstallationIdentityStore(dataDirectory).readSync());
    final workspaceId = workspaceIndex >= 0 && workspaceIndex + 1 < args.length
        ? args[workspaceIndex + 1]
        : (!ignoreSavedRegistration && registration != null
            ? registration.workspaceId
            : Platform.environment['SYNTILA_WORKSPACE_ID']);
    final workRootPath = settings.workRootPath;
    final secureStore = credentialStore ??
        PlatformSecureCredentialStore(
          credentialDirectory: Directory('${dataDirectory.path}/Credentials'),
        );
    final runtimeToken = workspaceRuntimeId == null
        ? null
        : secureStore.readSync(workspaceRuntimeId);
    return ResolvedWorkspaceConfiguration(
      dataDirectory: dataDirectory,
      registration: registration,
      credentials: WorkspaceCredentials(
        // Secure storage is authoritative. The environment token remains only
        // for isolated fixture launches without a saved credential.
        runtimeToken: ignoreSavedRegistration
            ? null
            : runtimeToken ?? Platform.environment['SYNTILA_WORKSPACE_TOKEN'],
      ),
      cloudUri: ignoreSavedRegistration
          ? null
          : workspaceGatewayUri(
              cloudUrl,
              workspaceRuntimeId: workspaceRuntimeId,
            ),
      workspaceRuntimeId: workspaceRuntimeId,
      installationId: installationId,
      workspaceId: workspaceId,
      workRootPath: workRootPath,
      settings: settings,
      settingsFile: settingsStore.file,
    );
  }

  static Directory resolveDataDirectory(List<String> args) {
    final index = args.indexOf('--data-dir');
    final path = index >= 0 && index + 1 < args.length
        ? args[index + 1]
        : Platform.environment['SYNTILA_WORKSPACE_DATA_DIR'];
    return path == null
        ? WorkspacePaths.defaultStateDirectory()
        : Directory(path);
  }

  /// The auth (`cloudUrl`) origin for a gateway URI on the backend.
  static String cloudHttpOrigin(Uri gateway) => workspaceAuthOrigin(_gatewayHttpOrigin(gateway));

  static String _gatewayHttpOrigin(Uri gateway) => Uri(
        scheme: switch (gateway.scheme) {
          'wss' || 'https' => 'https',
          'ws' || 'http' => 'http',
          _ => throw ArgumentError('Unsupported Cloud transport'),
        },
        host: gateway.host,
        port: gateway.hasPort ? gateway.port : null,
      ).toString();

  static Uri? workspaceGatewayUri(String value, {String? workspaceRuntimeId}) {
    var uri = Uri.tryParse(value);
    // An HTTP(S) Cloud origin is the auth Worker; the gateway runs on the backend.
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https') &&
        (uri.path.isEmpty || uri.path == '/')) {
      try {
        final backend = Uri.parse(workspaceBackendOrigin(value));
        uri = uri.replace(
          scheme: backend.scheme,
          host: backend.host,
          port: backend.hasPort ? backend.port : null,
        );
      } on ArgumentError {
        // Leave malformed values to the checks below.
      }
    }
    if (uri == null) return null;
    final socketScheme = switch (uri.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      'wss' => 'wss',
      'ws' => 'ws',
      _ => null,
    };
    if (socketScheme == null) return uri;
    final isHttpOrigin = uri.scheme == 'http' || uri.scheme == 'https';
    final existingPath = uri.path.replaceFirst(RegExp(r'/$'), '');
    final path = isHttpOrigin || uri.path.isEmpty || uri.path == '/'
        ? '$existingPath/api/workspace-gateway/connect'
        : uri.path;
    final port = uri.hasPort
        ? uri.port
        : socketScheme == 'wss'
            ? 443
            : 80;
    final safeQueryParameters = {
      for (final entry in uri.queryParameters.entries)
        if (!RegExp(
          r'(secret|token|password|api[_-]?key|authorization|cookie|credential)',
          caseSensitive: false,
        ).hasMatch(entry.key))
          entry.key: entry.value,
    };
    return Uri(
      scheme: socketScheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: port,
      path: path,
      queryParameters: {
        ...safeQueryParameters,
        if (workspaceRuntimeId != null)
          'workspaceRuntimeId': workspaceRuntimeId,
      },
    );
  }
}

class WorkspaceRegistration {
  const WorkspaceRegistration({
    required this.workspaceRuntimeId,
    required this.workspaceId,
    required this.cloudUrl,
    required this.name,
    required this.hostname,
    required this.installationId,
    this.ownerUserId,
  });

  final String workspaceRuntimeId;
  final String workspaceId;
  final String cloudUrl;
  final String name;
  final String hostname;
  final String? ownerUserId;
  final String installationId;

  factory WorkspaceRegistration.fromJson(Map<String, dynamic> json) {
    String required(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Workspace registration field $key is required');
      }
      return value;
    }

    final workspaceRuntimeId = required('workspaceRuntimeId');
    return WorkspaceRegistration(
      workspaceRuntimeId: workspaceRuntimeId,
      workspaceId: required('workspaceId'),
      cloudUrl: required('cloudUrl'),
      name: required('name'),
      hostname: required('hostname'),
      installationId: required('installationId'),
      ownerUserId: json['ownerUserId'] is String
          ? (json['ownerUserId'] as String).trim()
          : null,
    );
  }

  Map<String, Object?> toJson() => {
        'workspaceRuntimeId': workspaceRuntimeId,
        'workspaceId': workspaceId,
        'cloudUrl': cloudUrl,
        'name': name,
        'hostname': hostname,
        'installationId': installationId,
        if (ownerUserId != null) 'ownerUserId': ownerUserId,
      };
}

class WorkspaceRegistrationStore {
  const WorkspaceRegistrationStore(this.dataDirectory, {this.platform});

  final Directory dataDirectory;
  final PlatformRuntime? platform;

  File get file => File(
        '${dataDirectory.path}${Platform.pathSeparator}workspace-registration.json',
      );

  WorkspaceRegistration? readSync() {
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map
          ? WorkspaceRegistration.fromJson(Map<String, dynamic>.from(decoded))
          : null;
    } on Object {
      return null;
    }
  }

  Future<void> write(WorkspaceRegistration registration) async {
    await dataDirectory.create(recursive: true);
    await file.writeAsString(jsonEncode(registration.toJson()), flush: true);
    await (platform ?? currentPlatformRuntime).restrictPermissions(
      file.path,
      directory: false,
    );
  }

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}

/// Persistent, stable installation identity for one desktop Workspace install.
/// It is independent of hostname/hardware fingerprint and survives application
/// restarts, application updates, computer renames, and workspace renames.
class InstallationIdentityStore {
  const InstallationIdentityStore(this.dataDirectory, {this.platform});

  final Directory dataDirectory;
  final PlatformRuntime? platform;

  File get file =>
      File('${dataDirectory.path}${Platform.pathSeparator}installation-id');

  String? readSync() {
    if (!file.existsSync()) return null;
    try {
      final value = file.readAsStringSync().trim();
      return value.isNotEmpty ? value : null;
    } on Object {
      return null;
    }
  }

  Future<String> getOrCreate({String? initialIdentity}) async {
    if (await file.exists()) {
      final existing = (await file.readAsString()).trim();
      if (existing.isNotEmpty) return existing;
    }
    final identity = initialIdentity?.trim().isNotEmpty == true
        ? initialIdentity!.trim()
        : generateInstallationId();
    await dataDirectory.create(recursive: true);
    await file.writeAsString(identity, flush: true);
    await (platform ?? currentPlatformRuntime).restrictPermissions(
      file.path,
      directory: false,
    );
    return identity;
  }

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }

  static String generateInstallationId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // UUID v4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant 10xxxxxx
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final uuid =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
    return 'install_$uuid';
  }
}

/// Stable local identity for Worker ownership. It exists before Cloud
/// registration and survives disconnecting this machine from a Workspace.
class LocalWorkspaceIdentityStore {
  const LocalWorkspaceIdentityStore(this.dataDirectory, {this.platform});

  final Directory dataDirectory;
  final PlatformRuntime? platform;

  File get file =>
      File('${dataDirectory.path}${Platform.pathSeparator}local-workspace-id');

  Future<String> getOrCreate({String? initialIdentity}) async {
    final registryWorkspaceId = _readExistingWorkerRegistryWorkspaceId();
    if (registryWorkspaceId != null) {
      if (await file.exists()) {
        final existing = (await file.readAsString()).trim();
        if (existing == registryWorkspaceId) return existing;
      }
      await dataDirectory.create(recursive: true);
      await file.writeAsString(registryWorkspaceId, flush: true);
      await (platform ?? currentPlatformRuntime).restrictPermissions(
        file.path,
        directory: false,
      );
      return registryWorkspaceId;
    }
    if (await file.exists()) {
      final existing = (await file.readAsString()).trim();
      if (existing.isNotEmpty) return existing;
    }
    final identity = initialIdentity?.trim().isNotEmpty == true
        ? initialIdentity!.trim()
        : 'local-${_randomToken()}';
    await dataDirectory.create(recursive: true);
    await file.writeAsString(identity, flush: true);
    await (platform ?? currentPlatformRuntime).restrictPermissions(
      file.path,
      directory: false,
    );
    return identity;
  }

  String? _readExistingWorkerRegistryWorkspaceId() {
    final registryFile = File(
      '${dataDirectory.path}${Platform.pathSeparator}configured-workers.json',
    );
    if (!registryFile.existsSync()) return null;
    try {
      final decoded = jsonDecode(registryFile.readAsStringSync());
      if (decoded is! Map) return null;
      final workers = decoded['workers'];
      if (workers is! List || workers.isEmpty) return null;
      String? sharedWorkspaceId;
      for (final item in workers) {
        if (item is! Map) return null;
        final candidate = item['workspaceId'];
        if (candidate is! String || candidate.trim().isEmpty) return null;
        if (sharedWorkspaceId == null) {
          sharedWorkspaceId = candidate.trim();
        } else if (sharedWorkspaceId != candidate.trim()) {
          return null;
        }
      }
      return sharedWorkspaceId;
    } on Object {
      return null;
    }
  }

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }

  static String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // UUID v4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant 10xxxxxx
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }
}
