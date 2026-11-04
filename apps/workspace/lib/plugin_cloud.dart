import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'desktop_auth.dart';
import 'plugin_service.dart';
import 'secure_credentials.dart';
import 'workspace_registration_models.dart';

/// Account-library and enablement calls to Cloud. Account actions use the
/// desktop human session (`syntila login`); the entitlement lease uses the
/// Workspace runtime credential. Only manifest metadata, digests, origin
/// display strings and consent hashes are sent: never executable bytes, local
/// paths, environment values or credentials.
class HttpPluginCloud implements PluginCloudPort {
  HttpPluginCloud({
    required this.cloudUrl,
    required this.credentialStore,
    required this.workspaceId,
    required this.workspaceRuntimeId,
    required this.runtimeToken,
    HttpClient? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? HttpClient();

  final String cloudUrl;
  final SecureCredentialStore credentialStore;
  final String? workspaceId;
  final String? workspaceRuntimeId;
  final String? runtimeToken;
  final Duration timeout;
  final HttpClient _client;

  Future<String> _humanCredential() async {
    final session = await readStoredDesktopHumanSession(credentialStore);
    if (session == null || !session.expiresAt.isAfter(DateTime.now())) {
      throw const PluginCloudException(
        'login_required',
        'Sign in first: syntila login',
      );
    }
    return session.credential;
  }

  Future<Map<String, Object?>> _send(
    String method,
    String path,
    String bearer, {
    Map<String, Object?>? body,
    Map<String, String>? query,
  }) async {
    final base = workspaceCloudApiUri(cloudUrl, path);
    final uri = query == null ? base : base.replace(queryParameters: query);
    try {
      final request = await _client.openUrl(method, uri).timeout(timeout);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(timeout);
      final text = await utf8.decoder.bind(response).join().timeout(timeout);
      Map<String, Object?> parsed = const {};
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) parsed = Map<String, Object?>.from(decoded);
      } on FormatException {
        // A non-JSON error body is handled by status below.
      }
      final status = response.statusCode;
      if (status >= 200 && status < 300) return parsed;
      final code = parsed['code'] as String?;
      final message = parsed['message'];
      throw switch (status) {
        400 => PluginCloudException(
            code ?? 'invalid_request',
            message is String && message.isNotEmpty
                ? message
                : 'Cloud refused the request.',
          ),
        401 => const PluginCloudException(
            'login_required',
            'Sign in again: syntila login',
          ),
        402 => const PluginCloudException(
            'paid_plan_required',
            'Custom Worker plugins require Syntila Plus.',
          ),
        404 => const PluginCloudException(
            'plugin_not_found',
            'Cloud does not know that plugin.',
          ),
        409 => PluginCloudException(
            code ?? 'plugin_version_conflict',
            'Cloud refused the change.',
          ),
        _ => const PluginCloudException(
            'cloud_unavailable',
            'Cloud could not complete the request.',
          ),
      };
    } on PluginCloudException {
      rethrow;
    } on Object {
      throw const PluginCloudException(
        'cloud_unavailable',
        'Cloud could not be reached.',
      );
    }
  }

  @override
  Future<String> registerVersion({
    required Map<String, Object?> manifest,
    required String manifestDigest,
    required Map<String, Object?> origin,
    required Map<String, Object?>? signer,
  }) async {
    final result = await _send(
      'POST',
      '/api/me/worker-plugins',
      await _humanCredential(),
      body: {
        'manifest': manifest,
        'manifestDigest': manifestDigest,
        'origin': {'kind': origin['kind'], 'locator': origin['locator']},
        if (signer != null)
          'signer': {
            'fingerprint': signer['fingerprint'],
            'verified': signer['verified'],
          },
      },
    );
    final ref = result['pluginRef'];
    if (ref is! String || !RegExp(r'^plugin-[0-9a-f]{12}$').hasMatch(ref)) {
      throw const PluginCloudException(
        'cloud_unavailable',
        'Cloud returned an invalid plugin reference.',
      );
    }
    return ref;
  }

  @override
  Future<void> setEnablement({
    required String pluginRef,
    required String version,
    required String manifestDigest,
    required String consentHash,
    required bool enabled,
    required bool shareable,
  }) async {
    final workspace = workspaceId;
    if (workspace == null) {
      throw const PluginCloudException(
        'cloud_unavailable',
        'This Workspace is not registered with Cloud.',
      );
    }
    await _send(
      'PUT',
      '/api/workspaces/$workspace/worker-plugins/$pluginRef',
      await _humanCredential(),
      body: {
        'version': version,
        'manifestDigest': manifestDigest,
        'consentHash': consentHash,
        'enabled': enabled,
        'shareable': shareable,
      },
    );
  }

  @override
  Future<void> removeFromLibrary(String pluginRef) async {
    await _send(
      'DELETE',
      '/api/me/worker-plugins/$pluginRef',
      await _humanCredential(),
    );
  }

  @override
  Future<Map<String, Object?>> fetchLease() async {
    final runtimeId = workspaceRuntimeId;
    final token = runtimeToken;
    if (runtimeId == null || token == null || token.isEmpty) {
      throw const PluginCloudException(
        'cloud_unavailable',
        'This Workspace is not connected to Cloud.',
      );
    }
    return _send(
      'POST',
      '/api/workspace-runtime/worker-plugins/entitlement',
      token,
      query: {'workspaceRuntimeId': runtimeId},
    );
  }
}
