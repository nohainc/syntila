import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'secure_credentials.dart';

const desktopHumanCredentialKey = 'desktop-human-session';
const desktopAuthIntentContractVersion = '1.1';

/// Runs all sign-in ownership checks before replacing the stored human session.
Future<void> persistDesktopHumanSessionAfterPreflight({
  required SecureCredentialStore credentialStore,
  required DesktopHumanSession session,
  required Future<void> Function() preflight,
}) async {
  await preflight();
  await credentialStore.write(
    desktopHumanCredentialKey,
    jsonEncode(session.toSecureJson()),
  );
}

/// Stores [session] as this computer's human session and revokes the session
/// it replaces, so repeated sign-ins do not leave live Cloud sessions behind.
Future<void> replaceStoredDesktopHumanSession({
  required SecureCredentialStore credentialStore,
  required DesktopAuthClient client,
  required DesktopHumanSession session,
}) async {
  final previous = await readStoredDesktopHumanSession(credentialStore);
  await credentialStore.write(
    desktopHumanCredentialKey,
    jsonEncode(session.toSecureJson()),
  );
  if (previous != null && previous.sessionId != session.sessionId) {
    await revokeDesktopHumanSessionQuietly(client, previous);
  }
}

/// Returns the stored human session, or null when absent or unreadable.
Future<DesktopHumanSession?> readStoredDesktopHumanSession(
    SecureCredentialStore credentialStore) async {
  try {
    final raw = await credentialStore.read(desktopHumanCredentialKey);
    if (raw == null || raw.isEmpty) return null;
    return DesktopHumanSession.fromSecureJson(
        jsonDecode(raw) as Map<String, dynamic>);
  } on Object {
    return null;
  }
}

/// Revokes [session] in Cloud. Best effort: an expired, already revoked or
/// unreachable session must never block local sign-in or sign-out.
Future<void> revokeDesktopHumanSessionQuietly(
    DesktopAuthClient client, DesktopHumanSession session) async {
  if (!session.expiresAt.isAfter(DateTime.now())) return;
  try {
    await client.revokeSession(session).timeout(const Duration(seconds: 10));
  } on Object {
    // Cloud expiry still bounds the session.
  }
}

class DesktopAuthIntent {
  const DesktopAuthIntent({
    required this.intentId,
    required this.pollToken,
    required this.verificationUrl,
    required this.expiresAt,
    required this.pollIntervalMs,
  });

  final String intentId;
  final String pollToken;
  final Uri verificationUrl;
  final DateTime expiresAt;
  final int pollIntervalMs;

  factory DesktopAuthIntent.fromJson(Map<String, dynamic> json) {
    String required(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Desktop sign-in response is missing $key');
      }
      return value.trim();
    }

    final url = Uri.tryParse(required('verificationUrl'));
    if (url == null ||
        !(url.scheme == 'https' ||
            (url.scheme == 'http' &&
                const {'localhost', '127.0.0.1'}.contains(url.host))) ||
        url.host.isEmpty) {
      throw const FormatException(
          'Desktop sign-in verification URL is invalid');
    }
    return DesktopAuthIntent(
      intentId: required('intentId'),
      pollToken: required('pollToken'),
      verificationUrl: url,
      expiresAt: DateTime.parse(required('expiresAt')),
      pollIntervalMs:
          json['pollIntervalMs'] is int ? json['pollIntervalMs'] as int : 2000,
    );
  }
}

class DesktopHumanSession {
  const DesktopHumanSession({
    required this.credential,
    required this.sessionId,
    required this.userId,
    required this.displayName,
    required this.email,
    required this.expiresAt,
    this.issuedAt,
  });

  final String credential;
  final String sessionId;
  final String userId;
  final String displayName;
  final String email;
  final DateTime expiresAt;
  final DateTime? issuedAt;

  factory DesktopHumanSession.fromJson(Map<String, dynamic> json) {
    if (json['audience'] != 'syntila.desktop.management') {
      throw const FormatException(
          'Desktop session has an unsupported audience');
    }
    final user = json['user'];
    if (user is! Map) {
      throw const FormatException('Desktop session user is missing');
    }
    String required(Object? value, String field) {
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Desktop session is missing $field');
      }
      return value.trim();
    }

    return DesktopHumanSession(
      credential: required(json['credential'], 'credential'),
      sessionId: required(json['sessionId'], 'sessionId'),
      userId: required(user['userId'], 'userId'),
      displayName: required(user['displayName'], 'displayName'),
      email: required(user['email'], 'email'),
      expiresAt: DateTime.parse(required(json['expiresAt'], 'expiresAt')),
      issuedAt: DateTime.tryParse(json['issuedAt']?.toString() ?? ''),
    );
  }

  factory DesktopHumanSession.fromSecureJson(Map<String, dynamic> json) {
    String required(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Stored desktop session is missing $key');
      }
      return value.trim();
    }

    return DesktopHumanSession(
      credential: required('credential'),
      sessionId: required('sessionId'),
      userId: required('userId'),
      displayName: required('displayName'),
      email: required('email'),
      expiresAt: DateTime.parse(required('expiresAt')),
      issuedAt: DateTime.tryParse(json['issuedAt']?.toString() ?? ''),
    );
  }

  Map<String, Object?> toSecureJson() => {
        'credential': credential,
        'sessionId': sessionId,
        'userId': userId,
        'displayName': displayName,
        'email': email,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        if (issuedAt != null) 'issuedAt': issuedAt!.toUtc().toIso8601String(),
      };
}

enum WorkspaceOwnershipState {
  unbound,
  ownedByCurrentUser,
  ownedByOtherUser,
  localRegistrationStale,
  installationConflict,
  released,
  corruptOrAmbiguous,
}

class WorkspaceOwnership {
  const WorkspaceOwnership({
    required this.state,
    this.workspaceId,
    this.workspaceName,
    this.workspaceRuntimeId,
    this.ownerUserId,
    this.ownerMatchesCurrentSession,
    this.runtimeState,
  });

  final WorkspaceOwnershipState state;
  final String? workspaceId;
  final String? workspaceName;
  final String? workspaceRuntimeId;
  final String? ownerUserId;
  final bool? ownerMatchesCurrentSession;
  final String? runtimeState;

  factory WorkspaceOwnership.fromJson(Map<String, dynamic> json) {
    final state = switch (json['state']) {
      'unbound' => WorkspaceOwnershipState.unbound,
      'owned_by_current_user' => WorkspaceOwnershipState.ownedByCurrentUser,
      'owned_by_other_user' => WorkspaceOwnershipState.ownedByOtherUser,
      'local_registration_stale' =>
        WorkspaceOwnershipState.localRegistrationStale,
      'installation_conflict' => WorkspaceOwnershipState.installationConflict,
      'released' => WorkspaceOwnershipState.released,
      'corrupt_or_ambiguous' => WorkspaceOwnershipState.corruptOrAmbiguous,
      _ => throw const FormatException(
          'Cloud returned an unsupported Workspace ownership state'),
    };

    String? optionalString(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Cloud returned an invalid $key');
      }
      return value.trim();
    }

    final result = WorkspaceOwnership(
      state: state,
      workspaceId: optionalString('workspaceId'),
      workspaceName: optionalString('workspaceName'),
      workspaceRuntimeId: optionalString('workspaceRuntimeId'),
      ownerUserId: optionalString('ownerUserId'),
      ownerMatchesCurrentSession: json['ownerMatchesCurrentSession'] is bool
          ? json['ownerMatchesCurrentSession'] as bool
          : null,
      runtimeState: optionalString('runtimeState'),
    );
    if (state == WorkspaceOwnershipState.ownedByCurrentUser &&
        (result.workspaceId == null ||
            result.workspaceRuntimeId == null ||
            result.ownerUserId == null ||
            result.ownerMatchesCurrentSession != true ||
            result.runtimeState == null)) {
      throw const FormatException(
        'Cloud omitted canonical current-owner Workspace details',
      );
    }
    if (state == WorkspaceOwnershipState.localRegistrationStale &&
        (result.workspaceId != null ||
            result.workspaceRuntimeId != null ||
            result.ownerUserId != null ||
            result.ownerMatchesCurrentSession != null ||
            result.runtimeState != null) &&
        (result.workspaceId == null ||
            result.ownerUserId == null ||
            result.ownerMatchesCurrentSession != true ||
            result.runtimeState == null)) {
      throw const FormatException(
        'Cloud returned incomplete canonical details for a stale Workspace registration',
      );
    }
    if (state == WorkspaceOwnershipState.ownedByOtherUser &&
        json.keys.any((key) => key != 'state')) {
      throw const FormatException(
        'Cloud exposed details for a Workspace owned by another account',
      );
    }
    return result;
  }
}

class DesktopPasswordSignInException implements Exception {
  const DesktopPasswordSignInException(this.statusCode);
  final int statusCode;
  String get code => switch (statusCode) {
        401 => 'invalid_credentials',
        403 => 'additional_verification_required',
        429 => 'sign_in_rate_limited',
        404 => 'cloud_upgrade_required',
        _ => 'cloud_sign_in_unavailable',
      };
  String get message => switch (statusCode) {
        401 => 'Check your existing Cloud email/password and account status.',
        403 =>
          'This account requires additional verification. Use browser sign-in on another device.',
        429 => 'Too many sign-in attempts. Wait before retrying.',
        404 => 'Cloud must be updated to support headless password sign-in.',
        _ => 'Cloud sign-in is unavailable. Check connectivity and retry.',
      };
}

class DesktopAuthClient {
  DesktopAuthClient({required String cloudUrl, HttpClient? httpClient})
      : _cloudOrigin = _normalizeOrigin(cloudUrl),
        _http = httpClient ?? HttpClient();

  final Uri _cloudOrigin;
  final HttpClient _http;

  static Uri _normalizeOrigin(String value) {
    final parsed = Uri.tryParse(value.trim());
    if (parsed == null ||
        !const {'http', 'https'}.contains(parsed.scheme) ||
        parsed.host.isEmpty) {
      throw ArgumentError('Cloud URL must be an HTTP(S) origin.');
    }
    if (parsed.scheme != 'https' &&
        parsed.host != 'localhost' &&
        parsed.host != '127.0.0.1') {
      throw ArgumentError('Desktop sign-in requires a secure Cloud URL.');
    }
    return Uri(
        scheme: parsed.scheme,
        host: parsed.host,
        port: parsed.hasPort ? parsed.port : null);
  }

  Uri _api(String path) => _cloudOrigin.replace(path: '/api$path');

  Future<Map<String, dynamic>> _requestJson(String method, Uri uri,
      {Map<String, Object?>? body,
      String? bearer,
      bool passwordRequest = false}) async {
    final request =
        await (method == 'GET' ? _http.getUrl(uri) : _http.postUrl(uri))
            .timeout(const Duration(seconds: 20));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 20));
    Map<String, dynamic> decoded = const {};
    try {
      final value = jsonDecode(text);
      if (value is Map) decoded = Map<String, dynamic>.from(value);
    } on Object {
      // Error response text is intentionally not copied into diagnostics.
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (passwordRequest) {
        throw DesktopPasswordSignInException(response.statusCode);
      }
      final message = decoded['error'] is String
          ? decoded['error'] as String
          : 'Cloud sign-in failed (HTTP ${response.statusCode})';
      throw StateError(message);
    }
    return decoded;
  }

  Future<DesktopAuthIntent> createIntent() async {
    final json =
        await _requestJson('POST', _api('/desktop-auth/intents'), body: {
      'clientName': 'Syntila Workspace',
      'contractVersion': desktopAuthIntentContractVersion,
    });
    final intent = DesktopAuthIntent.fromJson(json);
    // The browser approval page may be served by the AX web application while
    // the API is hosted on a separate Cloud origin (and local development
    // commonly uses different ports). The URL is generated by the trusted
    // Cloud endpoint and is independently restricted to HTTPS or loopback by
    // DesktopAuthIntent.fromJson.
    return intent;
  }

  /// [deviceId] identifies this install so Cloud revokes its older sessions.
  Future<DesktopHumanSession> signInWithPassword(String email, String password,
      {String? deviceId}) async {
    final result = await _requestJson('POST', _api('/desktop-auth/password'),
        body: {
          'email': email,
          'password': password,
          if (deviceId != null) 'deviceId': deviceId,
        },
        passwordRequest: true);
    return DesktopHumanSession.fromJson(result);
  }

  Future<void> openVerification(DesktopAuthIntent intent) async {
    final url = intent.verificationUrl.toString();
    final command = switch (Platform.operatingSystem) {
      'macos' => ('open', [url]),
      'windows' => ('rundll32', ['url.dll,FileProtocolHandler', url]),
      'linux' => ('xdg-open', [url]),
      _ => throw UnsupportedError(
          'Opening a system browser is not supported on this platform.'),
    };
    await Process.start(command.$1, command.$2,
        runInShell: false, mode: ProcessStartMode.detached);
  }

  Future<void> cancelIntent(DesktopAuthIntent intent) async {
    await _requestJson(
      'POST',
      _api(
          '/desktop-auth/intents/${Uri.encodeComponent(intent.intentId)}/cancel'),
      bearer: intent.pollToken,
      body: const <String, Object?>{},
    );
  }

  Future<DesktopHumanSession> waitForApprovalAndClaim(
    DesktopAuthIntent intent, {
    bool Function()? isCancelled,
    String? deviceId,
  }) async {
    while (DateTime.now().toUtc().isBefore(intent.expiresAt.toUtc())) {
      if (isCancelled?.call() ?? false) {
        throw StateError('Workspace sign-in was cancelled.');
      }
      final status = await _requestJson(
        'GET',
        _api('/desktop-auth/intents/${Uri.encodeComponent(intent.intentId)}'),
        bearer: intent.pollToken,
      );
      switch (status['status']) {
        case 'approved':
          final response = await _requestJson(
            'POST',
            _api(
                '/desktop-auth/intents/${Uri.encodeComponent(intent.intentId)}/claim'),
            body: {
              'pollToken': intent.pollToken,
              if (deviceId != null) 'deviceId': deviceId,
            },
          );
          return DesktopHumanSession.fromJson(response);
        case 'denied':
          throw StateError('This Syntila Workspace sign-in was denied.');
        case 'expired':
        case 'claimed':
          throw StateError(
              'This Syntila Workspace sign-in request is no longer available.');
        case 'pending':
          final waitUntil = DateTime.now().add(Duration(
            milliseconds: intent.pollIntervalMs.clamp(1000, 10000),
          ));
          while (DateTime.now().isBefore(waitUntil)) {
            if (isCancelled?.call() ?? false) {
              throw StateError('Workspace sign-in was cancelled.');
            }
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
      }
    }
    throw StateError(
        'This Syntila Workspace sign-in request expired. Start sign-in again.');
  }

  Future<void> validateSession(DesktopHumanSession session) async {
    final result = await _requestJson(
      'GET',
      _api('/desktop-auth/session'),
      bearer: session.credential,
    );
    final user = result['user'];
    if (result['sessionId'] != session.sessionId ||
        result['audience'] != 'syntila.desktop.management' ||
        user is! Map ||
        user['userId'] != session.userId) {
      throw const FormatException(
        'Cloud did not confirm the desktop management session',
      );
    }
  }

  /// Rotates a still-valid management credential without creating a new
  /// browser-authenticated session or changing Workspace runtime state.
  Future<DesktopHumanSession> rotateSession(
    DesktopHumanSession session,
  ) async {
    final response = await _requestJson(
      'POST',
      _api(
        '/desktop-auth/sessions/${Uri.encodeComponent(session.sessionId)}/rotate',
      ),
      bearer: session.credential,
      body: const <String, Object?>{},
    );
    final rotated = DesktopHumanSession.fromJson(response);
    if (rotated.sessionId != session.sessionId ||
        rotated.userId != session.userId) {
      throw const FormatException(
        'Cloud rotated the desktop session to a different account',
      );
    }
    return rotated;
  }

  Future<WorkspaceOwnership> checkWorkspaceOwnership({
    required DesktopHumanSession session,
    required String installationId,
    String? workspaceId,
    String? runtimeId,
  }) async {
    final response = await _requestJson(
      'POST',
      _api('/workspace-runtime/ownership'),
      bearer: session.credential,
      body: {
        'contractVersion': '1.0',
        'installationId': installationId,
        if (workspaceId != null) 'workspaceId': workspaceId,
        if (runtimeId != null) 'runtimeId': runtimeId,
      },
    );
    return WorkspaceOwnership.fromJson(response);
  }

  Future<WorkspaceOwnership> reconcileWorkspaceOwnership({
    required DesktopHumanSession session,
    required String installationId,
    required String workspaceId,
    required String runtimeId,
  }) async {
    final response = await _requestJson(
      'POST',
      _api('/workspace-runtime/ownership/reconcile'),
      bearer: session.credential,
      body: {
        'contractVersion': '1.0',
        'installationId': installationId,
        'workspaceId': workspaceId,
        'runtimeId': runtimeId,
      },
    );
    return WorkspaceOwnership.fromJson(response);
  }

  Future<void> releaseWorkspace({
    required DesktopHumanSession session,
    required String installationId,
    required String workspaceId,
    required String runtimeId,
  }) async {
    await _requestJson(
      'POST',
      _api('/workspace-runtime/release'),
      bearer: session.credential,
      body: {
        'installationId': installationId,
        'workspaceId': workspaceId,
        'runtimeId': runtimeId,
      },
    );
  }

  Future<void> disconnectWorkspace({
    required DesktopHumanSession session,
    required String installationId,
    required String workspaceId,
    required String runtimeId,
  }) async {
    await _requestJson(
      'POST',
      _api('/workspace-runtime/disconnect'),
      bearer: session.credential,
      body: {
        'installationId': installationId,
        'workspaceId': workspaceId,
        'runtimeId': runtimeId,
      },
    );
  }

  Future<void> revokeSession(DesktopHumanSession session) async {
    await _requestJson(
      'POST',
      _api(
          '/desktop-auth/sessions/${Uri.encodeComponent(session.sessionId)}/revoke'),
      bearer: session.credential,
      body: const <String, Object?>{},
    );
  }

  void close() => _http.close(force: true);
}
