import 'dart:convert';
import 'dart:io';

/// A refusal from the server: the HTTP status and a short message.
class ServerRefusal implements Exception {
  ServerRefusal(this.status, this.message);
  final int status;
  final String message;

  /// The credential or Worker is gone for good: do not keep retrying.
  bool get fatal => status == 401 || status == 404 || status == 410;

  @override
  String toString() => 'server refused ($status): $message';
}

class SessionGrant {
  const SessionGrant({
    required this.sessionId,
    required this.epoch,
    required this.sessionToken,
    required this.leaseSeconds,
    this.actorId,
    this.workerName,
    this.workerType,
    this.workerTypeId,
    this.profileRevision,
    this.profileDigest,
  });

  final String sessionId;
  final int epoch;
  final String sessionToken;
  final int leaseSeconds;
  final String? actorId;
  final String? workerName;
  final String? workerType;

  /// The Type's current published Profile, so the Agent can discover and
  /// report its models before it has any work.
  final String? workerTypeId;
  final int? profileRevision;
  final String? profileDigest;
}

/// The Agent's HTTP calls. No secret is ever placed in a URL; the pairing
/// secret and the session token travel in bodies and headers only.
class ServerApi {
  ServerApi(this.baseUrl, {HttpClient? client})
    : _client = client ?? HttpClient();

  final String baseUrl;
  final HttpClient _client;

  /// Publishes what the provider CLI offers (or why it could not be captured)
  /// to this Worker. The session token travels in a header only.
  Future<void> publishModels({
    required String workerId,
    required SessionGrant session,
    required Map<String, Object?> report,
  }) async {
    final base = Uri.parse(baseUrl);
    final uri = base.replace(
      path: '${base.path}/api/worker-agent/models'.replaceAll('//', '/'),
    );
    final request = await _client
        .putUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${session.sessionToken}')
      ..set(HttpHeaders.contentTypeHeader, 'application/json')
      ..set('x-worker-id', workerId)
      ..set('x-worker-session-id', session.sessionId);
    request.add(utf8.encode(jsonEncode(report)));
    final response = await request.close().timeout(const Duration(seconds: 20));
    await response.drain<void>();
    if (response.statusCode != 200) {
      throw ServerRefusal(response.statusCode, 'Publishing models failed');
    }
  }

  /// Answers the owner's usage request with the provider's report. The Cloud
  /// relays it to the waiting owner and keeps nothing.
  Future<void> publishUsage({
    required String workerId,
    required SessionGrant session,
    required String requestId,
    required Map<String, Object?> report,
  }) async {
    final base = Uri.parse(baseUrl);
    final uri = base.replace(
      path: '${base.path}/api/worker-agent/usage'.replaceAll('//', '/'),
    );
    final request = await _client
        .putUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${session.sessionToken}')
      ..set(HttpHeaders.contentTypeHeader, 'application/json')
      ..set('x-worker-id', workerId)
      ..set('x-worker-session-id', session.sessionId);
    request.add(utf8.encode(jsonEncode({...report, 'requestId': requestId})));
    final response = await request.close().timeout(const Duration(seconds: 20));
    await response.drain<void>();
    if (response.statusCode != 200) {
      throw ServerRefusal(response.statusCode, 'Publishing usage failed');
    }
  }

  Future<({Object? snapshot, String proof})> downloadProfile({
    required String workerId,
    required SessionGrant session,
    required int revision,
    required String digest,
  }) async {
    final base = Uri.parse(baseUrl);
    final uri = base.replace(
      path: '${base.path}/api/worker-agent/profile'.replaceAll('//', '/'),
      queryParameters: {'revision': '$revision', 'digest': digest},
    );
    final request = await _client
        .getUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${session.sessionToken}',
    );
    request.headers.set('x-worker-id', workerId);
    request.headers.set('x-worker-session-id', session.sessionId);
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw ServerRefusal(response.statusCode, 'Profile download failed');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      bytes.addAll(chunk);
      if (bytes.length > 1024 * 1024) {
        throw const FormatException('Profile response too large');
      }
    }
    final result = jsonDecode(utf8.decode(bytes));
    if (result is! Map || result['proof'] is! String) {
      throw const FormatException('Invalid Profile response');
    }
    return (snapshot: result['snapshot'], proof: result['proof'] as String);
  }

  Future<Map<String, Object?>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    final base = Uri.parse(baseUrl);
    final uri = base.replace(path: '${base.path}$path'.replaceAll('//', '/'));
    final request = await _client
        .postUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await utf8.decodeStream(response);
    Object? decoded;
    try {
      decoded = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      decoded = null;
    }
    if (response.statusCode >= 400) {
      final message = decoded is Map && decoded['error'] is String
          ? decoded['error'] as String
          : 'request failed';
      throw ServerRefusal(response.statusCode, message);
    }
    return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
  }

  Future<({String? workerName, String? workerType})> claim({
    required String challengeId,
    required String secret,
    required String publicKey,
    required String signature,
    List<String> pairedWorkerIds = const [],
  }) async {
    final response = await _post('/api/worker-agent/claim', {
      'challengeId': challengeId,
      'secret': secret,
      'publicKey': publicKey,
      'signature': signature,
      if (pairedWorkerIds.isNotEmpty) 'pairedWorkerIds': pairedWorkerIds,
    });
    final pairing = response['pairing'];
    if (pairing is Map) {
      final name = pairing['workerName'] ?? pairing['name'];
      final type =
          pairing['workerTypeName'] ??
          pairing['workerType'] ??
          pairing['workerTypeId'];
      return (
        workerName: name is String ? name : null,
        workerType: type is String ? type : null,
      );
    }
    return (workerName: null, workerType: null);
  }

  Future<({String nonceId, String nonce})> nonce(String workerId) async {
    final response = await _post('/api/worker-agent/nonce', {
      'workerId': workerId,
    });
    final body = response['nonce'];
    if (body is! Map<String, Object?>) {
      throw ServerRefusal(502, 'the nonce answer was incomplete');
    }
    final nonceId = body['nonceId'];
    final nonce = body['nonce'];
    if (nonceId is! String || nonce is! String) {
      throw ServerRefusal(502, 'the nonce answer was incomplete');
    }
    return (nonceId: nonceId, nonce: nonce);
  }

  Future<SessionGrant> connectSession({
    required String workerId,
    required String nonceId,
    required String signature,
    String? clientVersion,
  }) async {
    final response = await _post('/api/worker-agent/sessions', {
      'workerId': workerId,
      'nonceId': nonceId,
      'signature': signature,
      if (clientVersion != null) 'clientVersion': clientVersion,
    });
    final body = response['session'];
    if (body is! Map<String, Object?>) {
      throw ServerRefusal(502, 'the session answer was incomplete');
    }
    final sessionId = body['sessionId'];
    final epoch = body['epoch'];
    final token = body['sessionToken'];
    if (sessionId is! String || epoch is! int || token is! String) {
      throw ServerRefusal(502, 'the session answer was incomplete');
    }
    return SessionGrant(
      sessionId: sessionId,
      epoch: epoch,
      sessionToken: token,
      leaseSeconds: body['leaseSeconds'] is int
          ? body['leaseSeconds'] as int
          : 300,
      actorId: body['actorId'] as String?,
      workerName: body['workerName'] is String
          ? body['workerName'] as String
          : null,
      workerType: body['workerType'] is String
          ? body['workerType'] as String
          : null,
      workerTypeId: body['workerTypeId'] is String
          ? body['workerTypeId'] as String
          : null,
      profileRevision:
          body['profile'] is Map && (body['profile'] as Map)['revision'] is int
          ? (body['profile'] as Map)['revision'] as int
          : null,
      profileDigest:
          body['profile'] is Map && (body['profile'] as Map)['digest'] is String
          ? (body['profile'] as Map)['digest'] as String
          : null,
    );
  }

  Future<void> rotate({
    required String workerId,
    required String nonceId,
    required String signature,
    required String newPublicKey,
    required String newKeySignature,
  }) async {
    await _post('/api/worker-agent/rotate', {
      'workerId': workerId,
      'nonceId': nonceId,
      'signature': signature,
      'newPublicKey': newPublicKey,
      'newKeySignature': newKeySignature,
    });
  }

  /// Publishes the folders this computer allows, with the device and its name,
  /// so the owner can pick one for a Space. Only ids, folder names and the
  /// access travel; never a path.
  Future<void> publishFolders({
    required String workerId,
    required SessionGrant session,
    required String deviceId,
    required String deviceName,
    required List<Map<String, String>> folders,
  }) async {
    final base = Uri.parse(baseUrl);
    final uri = base.replace(
      path: '${base.path}/api/worker-agent/folders'.replaceAll('//', '/'),
    );
    final request = await _client
        .putUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${session.sessionToken}')
      ..set(HttpHeaders.contentTypeHeader, 'application/json')
      ..set('x-worker-id', workerId)
      ..set('x-worker-session-id', session.sessionId);
    request.add(
      utf8.encode(
        jsonEncode({
          'deviceId': deviceId,
          'deviceName': deviceName,
          'folders': folders,
        }),
      ),
    );
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await utf8.decodeStream(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'folders publish ${response.statusCode}: ${text.length > 200 ? text.substring(0, 200) : text}',
        uri: uri,
      );
    }
    if (response.statusCode != 200) {
      throw ServerRefusal(response.statusCode, 'Publishing folders failed');
    }
  }

  /// Ends this Worker's pairing on the server (signed with its key).
  Future<void> unpair({
    required String workerId,
    required String nonceId,
    required String signature,
  }) async {
    await _post('/api/worker-agent/unpair', {
      'workerId': workerId,
      'nonceId': nonceId,
      'signature': signature,
    });
  }

  void close() => _client.close(force: true);
}
