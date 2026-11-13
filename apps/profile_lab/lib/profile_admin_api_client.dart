import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'profile_lab_auth.dart';
import 'profile_lab_cloud_config.dart';
import 'models/profile_admin_read_models.dart';

export 'models/profile_admin_read_models.dart';

/// HTTP Client for Syntila Cloud Profile Admin API endpoints.
///
/// Profile Lab communicates exclusively via this authenticated API client
/// and never connects directly to Cloudflare D1.
class ProfileAdminApiClient {
  ProfileAdminApiClient({
    required String baseUrl,
    this.session,
    HttpClient? httpClient,
  })  : baseUrl = ProfileLabCloudConfig.normalizeOrigin(baseUrl),
        _http = httpClient ?? HttpClient();

  final String baseUrl;
  final ProfileLabSession? session;
  final HttpClient _http;

  /// The admin API runs on the backend; `baseUrl` is the auth Worker origin
  /// (sign-in). Unknown origins are treated as a single-origin deployment.
  static const _backendOrigins = {
    'https://syntila.app': 'https://api.syntila.app',
    'http://localhost:8787': 'http://localhost:8788',
    'http://127.0.0.1:8787': 'http://127.0.0.1:8788',
  };
  static const _backendOverride = String.fromEnvironment('SYNTILA_BACKEND_URL');

  String get backendUrl {
    final origin = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    if (_backendOverride.isNotEmpty) return _backendOverride.replaceFirst(RegExp(r'/$'), '');
    return _backendOrigins[origin] ?? origin;
  }

  String? _backendToken;
  DateTime _backendTokenExpiresAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Exchanges the Profile Lab desktop session for a short-lived backend token.
  Future<String?> _bearer() async {
    final current = session;
    if (current == null || current.isExpired) return null;
    final origin = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    if (backendUrl == origin) return current.credential; // single-origin deployment
    if (_backendToken != null &&
        DateTime.now().isBefore(_backendTokenExpiresAt.subtract(const Duration(seconds: 60)))) {
      return _backendToken;
    }
    final request = await _http
        .postUrl(Uri.parse('$origin/api/backend-token'))
        .timeout(const Duration(seconds: 15));
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${current.credential}')
      ..contentType = ContentType.json;
    request.write('{}');
    final response = await request.close().timeout(const Duration(seconds: 15));
    final text = await utf8.decoder.bind(response).join().timeout(const Duration(seconds: 15));
    if (response.statusCode == HttpStatus.unauthorized || response.statusCode == HttpStatus.forbidden) {
      throw ProfileAdminUnauthorizedException('Sign in to Profile Lab again');
    }
    final decoded = response.statusCode == HttpStatus.ok ? jsonDecode(text) : null;
    if (decoded is! Map || decoded['token'] is! String) {
      throw StateError('Backend token request failed (${response.statusCode})');
    }
    _backendToken = decoded['token'] as String;
    _backendTokenExpiresAt = DateTime.tryParse('${decoded['expiresAt']}') ??
        DateTime.now().add(const Duration(minutes: 5));
    return _backendToken;
  }

  Uri _api(String path, [Map<String, String>? queryParams]) {
    final uri = Uri.parse('$backendUrl$path');
    if (queryParams != null && queryParams.isNotEmpty) {
      return uri.replace(queryParameters: queryParams);
    }
    return uri;
  }

  Future<dynamic> _request(
    String method,
    Uri uri, {
    Object? body,
    Map<String, String>? headers,
  }) async {
    final bearer = await _bearer();
    final request =
        await _http.openUrl(method, uri).timeout(const Duration(seconds: 15));
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    headers?.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 15));
    final responseText = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 15));
    dynamic decoded;
    try {
      decoded = jsonDecode(responseText);
    } catch (_) {
      decoded = null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      String errorMessage = 'Request failed (${response.statusCode})';
      if (decoded is Map && decoded['error'] is String) {
        errorMessage = decoded['error'] as String;
      }
      if (response.statusCode == HttpStatus.notFound) {
        throw ProfileAdminNotFoundException(errorMessage);
      }
      if (response.statusCode == HttpStatus.unauthorized ||
          response.statusCode == HttpStatus.forbidden) {
        throw ProfileAdminUnauthorizedException(errorMessage);
      }
      throw StateError(errorMessage);
    }
    return decoded;
  }

  Future<ProfileLabAccessReadModel> fetchLabAccess() async {
    final result = await _request('GET', _api('/api/admin/profile-lab/access'));
    if (result is! Map<String, dynamic> ||
        result['schemaVersion'] != 1 ||
        result['permissions'] is! Map) {
      throw const FormatException('Invalid Profile Lab access response');
    }
    return ProfileLabAccessReadModel.fromJson(result);
  }

  /// Lists logical Workers with their one current V9 Profile summary.
  Future<List<ProfileLabWorkerReadModel>> fetchWorkerCatalog() async {
    return fetchV9WorkerProfiles();
  }

  /// Lists logical Workers with their one current V9 Profile summary.
  Future<List<ProfileLabWorkerReadModel>> fetchV9WorkerProfiles() async {
    final result = await _request('GET', _api('/api/admin/workers'));
    if (result is Map && result['workers'] is List) {
      return _readModels(
        result['workers'] as List,
        ProfileLabWorkerReadModel.fromJson,
        'workers',
      );
    }
    throw const FormatException(
      'V9 Worker Profile response must contain a workers array.',
    );
  }

  /// Reads the one current published Profile for a logical Worker.
  Future<Map<String, dynamic>> fetchCurrentWorkerProfile(
    String workerTypeId,
  ) async {
    final result = await _request(
      'GET',
      _api('/api/admin/workers/${Uri.encodeComponent(workerTypeId)}/profile'),
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw StateError('Invalid current Worker Profile response');
  }

  /// Validates a candidate without publishing or changing the current Profile.
  Future<Map<String, dynamic>> validateWorkerProfileCandidate({
    required String workerTypeId,
    required Map<String, dynamic> profile,
    required String candidateDigest,
    Map<String, Object?>? evidence,
  }) async {
    final result = await _request(
      'POST',
      _api(
        '/api/admin/workers/${Uri.encodeComponent(workerTypeId)}/profile/validate',
      ),
      body: {
        'profile': profile,
        'candidateDigest': candidateDigest,
        if (evidence != null) 'evidence': evidence,
      },
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw StateError('Invalid Worker Profile validation response');
  }

  /// Atomically publishes the validated candidate as the next V9 revision.
  Future<Map<String, dynamic>> publishWorkerProfile({
    required String workerTypeId,
    required int expectedRevision,
    required Map<String, dynamic> profile,
    required String candidateDigest,
    required Map<String, Object?> evidence,
  }) async {
    final result = await _request(
      'PUT',
      _api('/api/admin/workers/${Uri.encodeComponent(workerTypeId)}/profile'),
      body: {
        'expectedRevision': expectedRevision,
        'profile': profile,
        'candidateDigest': candidateDigest,
        'evidence': evidence,
      },
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw StateError('Invalid Worker Profile publication response');
  }

  /// Lists prior signed snapshots for one logical Worker.
  Future<List<Map<String, dynamic>>> fetchWorkerProfileHistory(
    String workerTypeId,
  ) async {
    final result = await _request(
      'GET',
      _api(
        '/api/admin/workers/${Uri.encodeComponent(workerTypeId)}/profile/history',
      ),
    );
    if (result is Map && result['history'] is List) {
      return (result['history'] as List)
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }
    throw const FormatException(
      'Worker Profile history response must contain a history array.',
    );
  }

  /// Restores a history snapshot as a new current signed revision.
  Future<Map<String, dynamic>> restoreWorkerProfile({
    required String workerTypeId,
    required int expectedRevision,
    required int targetRevision,
    required String restorationReason,
  }) async {
    final result = await _request(
      'POST',
      _api(
        '/api/admin/workers/${Uri.encodeComponent(workerTypeId)}/profile/restore',
      ),
      body: {
        'expectedRevision': expectedRevision,
        'targetRevision': targetRevision,
        'restorationReason': restorationReason,
      },
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw StateError('Invalid Worker Profile restore response');
  }

  /// Lists audit events globally or scoped to a definition.
  Future<List<ProfileLabAuditEventReadModel>> fetchAudit([
    String? profileDefinitionId,
  ]) async {
    final path = profileDefinitionId != null
        ? '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/audit'
        : '/api/admin/tool-profiles/audit';
    final result = await _request('GET', _api(path));
    if (result is Map && result['events'] is List) {
      return _readModels(
        result['events'] as List,
        ProfileLabAuditEventReadModel.fromJson,
        'events',
      );
    }
    return [];
  }

  Future<List<ProfileLabIssueReportReadModel>> fetchIssueReports({
    String? status,
    String? component,
    String? errorCode,
    String? workerTypeId,
    DateTime? createdAfter,
    DateTime? createdBefore,
  }) async {
    final query = <String, String>{
      if (status != null) 'status': status,
      if (component != null) 'component': component,
      if (errorCode != null) 'errorCode': errorCode,
      if (workerTypeId != null) 'workerTypeId': workerTypeId,
      if (createdAfter != null)
        'createdAfter': createdAfter.toUtc().toIso8601String(),
      if (createdBefore != null)
        'createdBefore': createdBefore.toUtc().toIso8601String(),
    };
    final result = await _request(
      'GET',
      _api('/api/admin/issue-reports', query),
    );
    if (result is Map && result['reports'] is List) {
      return _readModels(
        result['reports'] as List,
        ProfileLabIssueReportReadModel.fromJson,
        'reports',
      );
    }
    return [];
  }

  Future<Map<String, dynamic>> fetchIssueReport(String id) async {
    final result = await _request(
      'GET',
      _api('/api/admin/issue-reports/${Uri.encodeComponent(id)}'),
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw StateError('Invalid issue report response');
  }

  Future<List<ProfileLabIssueReportGroupReadModel>>
      fetchIssueReportGroups() async {
    final result = await _request(
      'GET',
      _api('/api/admin/issue-reports/groups'),
    );
    if (result is Map && result['groups'] is List) {
      return _readModels(
        result['groups'] as List,
        ProfileLabIssueReportGroupReadModel.fromJson,
        'groups',
      );
    }
    return [];
  }

  Future<Map<String, dynamic>> createIssueReportGroup({
    required String label,
    String? fingerprint,
  }) async {
    final result = await _request(
      'POST',
      _api('/api/admin/issue-reports/groups'),
      body: {
        'label': label,
        if (fingerprint != null) 'fingerprint': fingerprint,
      },
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw StateError('Invalid issue report group response');
  }

  Future<Map<String, dynamic>> updateIssueReport(
    String id, {
    String? status,
    String? note,
    String? groupId,
    bool clearGroup = false,
  }) async {
    final result = await _request(
      'PATCH',
      _api('/api/admin/issue-reports/${Uri.encodeComponent(id)}'),
      body: {
        if (status != null) 'status': status,
        if (note != null) 'note': note,
        if (groupId != null || clearGroup) 'groupId': groupId,
      },
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw StateError('Invalid issue report update response');
  }

  void close() => _http.close(force: true);
}

class ProfileAdminNotFoundException extends StateError {
  ProfileAdminNotFoundException(super.message);
}

List<T> _readModels<T extends ProfileAdminReadModel>(
  List values,
  T Function(Map<String, dynamic>) parse,
  String field,
) {
  return List<T>.unmodifiable(
    values.map((value) {
      if (value is! Map) {
        throw StateError('Invalid $field response item');
      }
      return parse(Map<String, dynamic>.from(value));
    }),
  );
}

class ProfileAdminUnauthorizedException extends StateError {
  ProfileAdminUnauthorizedException(super.message);
}
