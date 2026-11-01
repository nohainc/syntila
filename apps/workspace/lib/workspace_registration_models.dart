import 'dart:async';
import 'dart:io';

const syntilaProductionCloudUrl = 'https://syntila.app';
const syntilaLocalCloudUrl = 'http://localhost:8787';

/// Build-time target environment, set by the build scripts with
/// `--dart-define=SYNTILA_WORKSPACE_ENVIRONMENT=local|production`.
/// A Workspace build talks to exactly one Cloud; there is no runtime switch.
const syntilaWorkspaceEnvironment = String.fromEnvironment(
  'SYNTILA_WORKSPACE_ENVIRONMENT',
  defaultValue: 'production',
);
const syntilaWorkspaceIsLocalBuild = syntilaWorkspaceEnvironment == 'local';

/// Cloud origin used by registration clients: the value from workspace.nano,
/// falling back to this build's default (local API for local builds).
String resolveWorkspaceCloudUrl(String? savedCloudUrl) {
  if (savedCloudUrl != null && savedCloudUrl.isNotEmpty) return savedCloudUrl;
  return syntilaWorkspaceIsLocalBuild
      ? syntilaLocalCloudUrl
      : syntilaProductionCloudUrl;
}

const syntilaWorkspaceAppVersion =
    String.fromEnvironment('SYNTILA_WORKSPACE_VERSION', defaultValue: '1.0.3');

String normalizeWorkspaceCloudOrigin(String cloudUrl) {
  final parsed = Uri.tryParse(cloudUrl.trim());
  if (parsed == null ||
      !const {'https', 'http'}.contains(parsed.scheme) ||
      parsed.host.isEmpty) {
    throw ArgumentError('Cloud URL must be an HTTP(S) origin.');
  }
  return Uri(
    scheme: parsed.scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
  ).toString();
}

Uri workspaceCloudApiUri(String cloudUrl, String apiPath) {
  if (!apiPath.startsWith('/api/')) {
    throw ArgumentError.value(apiPath, 'apiPath', 'Must start with /api/.');
  }
  return Uri.parse(normalizeWorkspaceCloudOrigin(cloudUrl))
      .replace(path: apiPath);
}

class WorkspaceRegistrationResult {
  const WorkspaceRegistrationResult({
    required this.workspaceRuntimeId,
    required this.workspaceId,
    required this.workspaceName,
    required this.ownerUserId,
    required this.runtimeCredential,
  });

  final String workspaceRuntimeId;
  final String workspaceId;
  final String workspaceName;
  final String? ownerUserId;
  final String runtimeCredential;

  factory WorkspaceRegistrationResult.fromJson(Map<String, Object?> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException(
            'Workspace registration response is missing $key');
      }
      return value.trim();
    }

    return WorkspaceRegistrationResult(
      workspaceRuntimeId: requiredString('workspaceRuntimeId'),
      workspaceId: requiredString('workspaceId'),
      workspaceName: requiredString('workspaceName'),
      ownerUserId: json['ownerUserId'] is String
          ? (json['ownerUserId'] as String).trim()
          : null,
      runtimeCredential: requiredString('runtimeCredential'),
    );
  }
}

/// Safe machine facts submitted during authenticated Workspace registration.
///
/// Under the Syntila safety contract, this payload contains only safe,
/// non-sensitive platform metadata and runtime capabilities. It MUST NEVER
/// contain API keys, credentials, cookies, private paths, or filesystem contents.
class SafeMachineFacts {
  const SafeMachineFacts({
    required this.installationId,
    required this.name,
    required this.hostname,
    required this.platform,
    required this.architecture,
    required this.appVersion,
    required this.runtimeCapabilities,
  });

  final String installationId;
  final String name;
  final String hostname;
  final String platform;
  final String architecture;
  final String appVersion;
  final Map<String, Object?> runtimeCapabilities;

  Map<String, Object?> toRegistrationJson() {
    final payload = <String, Object?>{
      'hostname': hostname.trim(),
      'installationId': installationId.trim(),
      if (name.trim().isNotEmpty) 'name': name.trim(),
      'platform': platform.trim(),
      'architecture': architecture.trim(),
      'appVersion': appVersion.trim(),
      'runtimeCapabilities': runtimeCapabilities,
    };
    validateSafePayload(payload);
    return payload;
  }

  static SafeMachineFacts collect({
    required String installationId,
    required String name,
    String? hostname,
    String? platform,
    String? architecture,
    String? appVersion,
    Map<String, Object?>? capabilities,
  }) {
    final os = platform ?? Platform.operatingSystem;
    final arch = architecture ?? detectArchitecture();
    final ver = appVersion ?? syntilaWorkspaceAppVersion;
    final workspace = hostname ?? Platform.localHostname;
    final caps = capabilities ??
        defaultRuntimeCapabilities(os: os, arch: arch, appVersion: ver);

    return SafeMachineFacts(
      installationId: installationId,
      name: name,
      hostname: workspace,
      platform: os,
      architecture: arch,
      appVersion: ver,
      runtimeCapabilities: caps,
    );
  }

  static Map<String, Object?> defaultRuntimeCapabilities({
    required String os,
    required String arch,
    required String appVersion,
  }) {
    return {
      'os': os,
      'arch': arch,
      'appVersion': appVersion,
      'supportedRuntimes': const <String>['dart'],
      'maxConcurrentWorkers': 1,
    };
  }

  static String detectArchitecture() {
    final version = Platform.version.toLowerCase();
    final envHint =
        '${Platform.environment['PROCESSOR_ARCHITECTURE'] ?? ''} ${Platform.environment['HOSTTYPE'] ?? ''}'
            .toLowerCase();
    if (version.contains('arm64') ||
        version.contains('aarch64') ||
        envHint.contains('arm64') ||
        envHint.contains('aarch64')) {
      return 'arm64';
    }
    return 'x64';
  }

  /// Verifies that no sensitive keys or paths are present in machine facts.
  static void validateSafePayload(Map<String, Object?> payload) {
    const forbidden = {
      'apikey',
      'api_key',
      'secret',
      'secrets',
      'password',
      'cookie',
      'cookies',
      'credential',
      'credentials',
      'authtoken',
      'auth_token',
      'homedirectory',
      'home_directory',
      'workroot',
      'work_root',
      'filesystem',
      'inventory',
    };

    void scan(Object? value, [String path = '']) {
      if (value is Map) {
        for (final entry in value.entries) {
          final key = entry.key.toString().toLowerCase().replaceAll('_', '');
          if (forbidden.contains(key) && entry.key != 'token') {
            throw ArgumentError(
                'Prohibited secret or sensitive metadata in machine facts: ${entry.key}');
          }
          scan(entry.value, '$path.${entry.key}');
        }
      } else if (value is List) {
        for (final item in value) {
          scan(item, path);
        }
      }
    }

    scan(payload);
  }
}

enum WorkspaceRegistrationErrorKind {
  authenticationRequired,
  cloudUnavailable,
  workspaceOwnedByOtherAccount,
  localRegistrationStale,
  installationBindingAmbiguous,
  workspaceRuntimeMissing,
  workspaceIdentityMismatch,
  releaseRequired,
  workspaceNameTaken,
  personalWorkspaceLimitReached,
  registrationConflict,
  accessDenied,
  serverValidationFailure,
  unknown,
}

class WorkspaceRegistrationException implements Exception {
  const WorkspaceRegistrationException({
    required this.kind,
    required this.message,
    required this.action,
    this.statusCode,
    this.serverError,
    this.serverCode,
  });

  final WorkspaceRegistrationErrorKind kind;
  final String message;
  final String action;
  final int? statusCode;
  final String? serverError;
  final String? serverCode;

  String get displayTitle => message;
  String get displayAction => action;

  @override
  String toString() => '$message $action'.trim();

  factory WorkspaceRegistrationException.fromError({
    int? statusCode,
    String? serverError,
    String? serverCode,
    Object? underlyingError,
  }) {
    final lowerCode = (serverCode ?? '').toLowerCase();
    if (underlyingError is SocketException ||
        underlyingError is HttpException ||
        underlyingError is HandshakeException ||
        underlyingError is TlsException ||
        underlyingError is TimeoutException ||
        (statusCode != null && statusCode >= 500)) {
      return WorkspaceRegistrationException(
        kind: WorkspaceRegistrationErrorKind.cloudUnavailable,
        message: 'Unable to connect to Syntila Cloud.',
        action: 'Check your internet connection or verify the Cloud URL.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }
    if (lowerCode == 'workspace_owned_by_other_account') {
      return WorkspaceRegistrationException(
        kind: WorkspaceRegistrationErrorKind.workspaceOwnedByOtherAccount,
        message:
            'This Workspace installation is owned by another Syntila account.',
        action:
            'Sign in as its current owner, then disconnect and release ownership before switching accounts.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }
    if (lowerCode == 'local_registration_stale') {
      return WorkspaceRegistrationException(
        kind: WorkspaceRegistrationErrorKind.localRegistrationStale,
        message: 'The local Workspace registration is out of date.',
        action:
            'Reconnect to refresh the canonical Cloud registration before continuing.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }
    if (lowerCode == 'installation_binding_ambiguous') {
      return WorkspaceRegistrationException(
        kind: WorkspaceRegistrationErrorKind.installationBindingAmbiguous,
        message: 'Cloud found conflicting Workspace bindings.',
        action:
            'Do not reconnect until the installation binding has been reviewed.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }
    if (lowerCode == 'workspace_runtime_missing') {
      return WorkspaceRegistrationException(
        kind: WorkspaceRegistrationErrorKind.workspaceRuntimeMissing,
        message: 'The registered Workspace runtime no longer exists in Cloud.',
        action: 'Reconnect to create or recover the Workspace runtime.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }
    if (lowerCode == 'workspace_identity_mismatch') {
      return WorkspaceRegistrationException(
        kind: WorkspaceRegistrationErrorKind.workspaceIdentityMismatch,
        message: 'The local Workspace identity does not match Cloud.',
        action:
            'Check the local registration and retry after correcting the identity.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }
    if (lowerCode == 'release_required') {
      return WorkspaceRegistrationException(
        kind: WorkspaceRegistrationErrorKind.releaseRequired,
        message:
            'This installation must be released before it can be transferred.',
        action:
            'Sign in as the current owner and use Release ownership before connecting another account.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }
    if (lowerCode == 'workspace_name_taken') {
      return WorkspaceRegistrationException(
        kind: WorkspaceRegistrationErrorKind.workspaceNameTaken,
        message: 'You already have a Workspace with this name.',
        action: 'Change workspace.name in workspace.nano '
            '(see: syntila config path), then run: '
            'syntila register',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }
    if (lowerCode == 'personal_workspace_limit_reached') {
      return WorkspaceRegistrationException(
        kind: WorkspaceRegistrationErrorKind.personalWorkspaceLimitReached,
        message: 'Free includes one personal Workspace.',
        action: 'Upgrade to Syntila Plus to connect more machines.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }
    if (lowerCode == 'registration_conflict' || statusCode == 409) {
      return WorkspaceRegistrationException(
        kind: WorkspaceRegistrationErrorKind.registrationConflict,
        message: 'Workspace registration changed while connecting.',
        action: 'Retry registration. If the problem persists, sign in again.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }
    if (statusCode == 401) {
      return WorkspaceRegistrationException(
        kind: WorkspaceRegistrationErrorKind.authenticationRequired,
        message: 'Sign in to Syntila again to connect this Workspace.',
        action: 'Sign in to your Syntila account and retry.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }
    if (statusCode == 403) {
      return WorkspaceRegistrationException(
        kind: WorkspaceRegistrationErrorKind.accessDenied,
        message: 'Your Syntila account cannot register this Workspace.',
        action: 'Check account access and try again.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }
    if (statusCode == 400 || statusCode == 422) {
      return WorkspaceRegistrationException(
        kind: WorkspaceRegistrationErrorKind.serverValidationFailure,
        message: 'Workspace registration details were rejected.',
        action: serverError?.isNotEmpty == true
            ? serverError!
            : 'Check the Workspace name and machine settings.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }
    return WorkspaceRegistrationException(
      kind: WorkspaceRegistrationErrorKind.unknown,
      message: serverError?.isNotEmpty == true
          ? serverError!
          : 'Workspace registration could not be completed.',
      action: 'Please retry or export diagnostics if the problem persists.',
      statusCode: statusCode,
      serverError: serverError,
      serverCode: serverCode,
    );
  }
}
