import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'secure_credentials.dart';
import 'workspace_configuration.dart';
import 'workspace_registration_models.dart';

export 'workspace_registration_models.dart';

class WorkspaceRegistrationClient {
  WorkspaceRegistrationClient({
    required this.cloudUrl,
    HttpClient? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? HttpClient();

  final String cloudUrl;
  final Duration timeout;
  final HttpClient _client;

  Future<WorkspaceRegistrationResult> register({
    required String credential,
    required SafeMachineFacts facts,
  }) async {
    final uri = workspaceCloudApiUri(
      cloudUrl,
      '/api/workspace-runtime/register',
    );
    final bearer = await backendBearerForHumanSession(cloudUrl, credential,
        client: _client, timeout: timeout);
    final request = await _client.postUrl(uri).timeout(timeout);
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    final payload = facts.toRegistrationJson();
    payload['contractVersion'] = '1.0';
    payload['proposedWorkspaceName'] = payload.remove('name');
    request.write(jsonEncode(payload));
    final response = await request.close().timeout(timeout);
    final body = await utf8.decoder.bind(response).join().timeout(timeout);
    if (response.statusCode != HttpStatus.created) {
      String? detail;
      String? code;
      try {
        final parsed = jsonDecode(body);
        if (parsed is Map) {
          detail = parsed['error'] as String?;
          code = parsed['code'] as String?;
        }
      } on Object {
        detail = body;
      }
      throw WorkspaceRegistrationException.fromError(
        statusCode: response.statusCode,
        serverError: detail,
        serverCode: code,
      );
    }
    final parsed = jsonDecode(body);
    if (parsed is! Map) {
      throw const FormatException(
        'Workspace registration response is invalid.',
      );
    }
    return WorkspaceRegistrationResult.fromJson(
      Map<String, Object?>.from(parsed),
    );
  }

  void close() => _client.close(force: true);
}

class WorkspaceRegistrationService {
  WorkspaceRegistrationService({
    required this.dataDirectory,
    SecureCredentialStore credentialStore =
        const PlatformSecureCredentialStore(),
  }) : _credentialStore = credentialStore;

  final Directory dataDirectory;
  final SecureCredentialStore _credentialStore;

  /// Recovers a missing local runtime credential for this registered install.
  /// Cloud verifies the signed-in owner against the persistent installation ID
  /// before it issues a replacement credential.
  Future<void> recoverMissingRuntimeCredential({
    required WorkspaceRegistration registration,
    required String desktopCredential,
    required String expectedOwnerUserId,
    String? name,
  }) async {
    final existing = await _credentialStore.read(
      registration.workspaceRuntimeId,
    );
    if (existing?.trim().isNotEmpty == true) return;

    await registerWithDesktopSession(
      cloudUrl: registration.cloudUrl,
      desktopCredential: desktopCredential,
      expectedOwnerUserId: expectedOwnerUserId,
      facts: SafeMachineFacts.collect(
        installationId: registration.installationId,
        name:
            name?.trim().isNotEmpty == true ? name!.trim() : registration.name,
        hostname: registration.hostname,
      ),
    );
  }

  /// Replaces stale local IDs only after Cloud confirms the same owner and
  /// supplies a canonical Workspace identity for this installation.
  Future<WorkspaceRegistration> recoverStaleRegistration({
    required WorkspaceRegistration registration,
    required String desktopCredential,
    required String expectedOwnerUserId,
    required String confirmedOwnerUserId,
    required String canonicalWorkspaceId,
  }) async {
    if (confirmedOwnerUserId != expectedOwnerUserId ||
        canonicalWorkspaceId.trim().isEmpty) {
      throw StateError(
        'Cloud did not confirm the signed-in account as the Workspace owner.',
      );
    }
    final repaired = await registerWithDesktopSession(
      cloudUrl: registration.cloudUrl,
      desktopCredential: desktopCredential,
      expectedOwnerUserId: expectedOwnerUserId,
      expectedWorkspaceId: canonicalWorkspaceId,
      facts: SafeMachineFacts.collect(
        installationId: registration.installationId,
        name: registration.name,
        hostname: registration.hostname,
      ),
    );
    if (repaired.workspaceRuntimeId != registration.workspaceRuntimeId) {
      try {
        await _credentialStore.delete(registration.workspaceRuntimeId);
      } on Object {
        // Cloud has revoked the old runtime identity; local cleanup is best effort.
      }
    }
    return repaired;
  }

  Future<WorkspaceRegistration> registerWithDesktopSession({
    required String cloudUrl,
    required String desktopCredential,
    required SafeMachineFacts facts,
    required String expectedOwnerUserId,
    String? expectedWorkspaceId,
  }) async {
    final client = WorkspaceRegistrationClient(cloudUrl: cloudUrl);
    try {
      final result = await client.register(
        credential: desktopCredential,
        facts: facts,
      );
      if (result.ownerUserId == null ||
          result.ownerUserId != expectedOwnerUserId) {
        throw StateError(
          'Cloud returned a Workspace owned by a different Syntila account.',
        );
      }
      if (expectedWorkspaceId != null &&
          result.workspaceId != expectedWorkspaceId) {
        throw StateError(
          'The canonical Workspace changed during registration recovery. Check ownership and retry.',
        );
      }
      await _credentialStore.write(
        result.workspaceRuntimeId,
        result.runtimeCredential,
      );
      final registration = WorkspaceRegistration(
        workspaceRuntimeId: result.workspaceRuntimeId,
        workspaceId: result.workspaceId,
        cloudUrl: normalizeWorkspaceCloudOrigin(cloudUrl),
        name: result.workspaceName,
        hostname: facts.hostname,
        ownerUserId: result.ownerUserId,
        installationId: facts.installationId,
      );
      try {
        await WorkspaceRegistrationStore(dataDirectory).write(registration);
      } on Object {
        await _credentialStore.delete(result.workspaceRuntimeId);
        rethrow;
      }
      return registration;
    } finally {
      client.close();
    }
  }
}
