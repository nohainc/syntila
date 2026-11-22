import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'output_images.dart';
import 'server_api.dart';

/// A step's input names an artifact ID (or a Git reference). A local path from
/// another machine is never a handoff.
class MissingArtifactException implements Exception {
  MissingArtifactException(this.reason);
  final String reason;

  @override
  String toString() => 'Missing artifact: $reason';
}

final _artifactId = RegExp(
  r'^art-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// One reference from a step's `contextRefs`.
class ArtifactRef {
  ArtifactRef({
    required this.artifactId,
    required this.name,
    required this.sizeBytes,
    required this.sha256,
    required this.grantToken,
  });

  final String artifactId;
  final String name;
  final int sizeBytes;
  final String sha256;
  final String grantToken;

  /// Refuses anything that is not an artifact ID with a grant.
  static ArtifactRef parse(Object? raw) {
    if (raw is! Map) {
      throw MissingArtifactException('a handoff must be an artifact reference');
    }
    final id = raw['artifactId'];
    if (id is! String || !_artifactId.hasMatch(id)) {
      throw MissingArtifactException(
        'a step hands off by artifact ID, never by a local path',
      );
    }
    final grant = raw['grant'];
    final token = grant is Map ? grant['token'] : null;
    final sha = raw['sha256'];
    if (token is! String || sha is! String) {
      throw MissingArtifactException('$id has no download grant');
    }
    return ArtifactRef(
      artifactId: id,
      name: raw['name'] is String ? raw['name'] as String : 'artifact',
      sizeBytes: raw['sizeBytes'] is int ? raw['sizeBytes'] as int : 0,
      sha256: sha.replaceFirst('sha256:', '').toLowerCase(),
      grantToken: token,
    );
  }
}

/// The server-chosen name reduced to one safe file name, so it can never point
/// outside the folder the Agent picked.
String safeArtifactName(String name) {
  final cleaned = p
      .basename(name.replaceAll('\\', '/'))
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return cleaned.isEmpty || cleaned == '.' || cleaned == '..'
      ? 'artifact'
      : cleaned;
}

/// Uploads and downloads handoff artifacts with the Agent's session. The
/// local path is always chosen here, never by the server.
class ArtifactClient {
  ArtifactClient(this.baseUrl, {HttpClient? client})
    : _client = client ?? HttpClient();

  final String baseUrl;
  final HttpClient _client;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(baseUrl);
    return base.replace(
      path: '${base.path}$path'.replaceAll('//', '/'),
      queryParameters: query,
    );
  }

  void _auth(HttpClientRequest request, SessionGrant session, String workerId) {
    request.headers.set('authorization', 'Bearer ${session.sessionToken}');
    request.headers.set('x-worker-id', workerId);
    request.headers.set('x-worker-session-id', session.sessionId);
  }

  /// Uploads [file] for [assignmentId]; returns the artifact ID.
  Future<String> upload({
    required SessionGrant session,
    required String workerId,
    required String assignmentId,
    required File file,
    required String name,
  }) async {
    final digest = await sha256.bind(file.openRead()).first;
    final request = await _client.postUrl(
      _uri('/api/worker-agent/artifacts', {
        'assignmentId': assignmentId,
        'name': name,
      }),
    );
    _auth(request, session, workerId);
    request.headers.set('x-content-sha256', digest.toString());
    request.headers.contentType = ContentType.binary;
    request.contentLength = await file.length();
    await request.addStream(file.openRead());
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    if (response.statusCode >= 400) {
      throw ServerRefusal(response.statusCode, text);
    }
    final decoded = jsonDecode(text);
    final artifact = decoded is Map ? decoded['artifact'] : null;
    final id = artifact is Map ? artifact['artifactId'] : null;
    if (id is! String) throw ServerRefusal(502, 'the upload answer was bad');
    return id;
  }

  /// Uploads one image the Worker made for the user; returns its descriptor
  /// for the result's `output.images`.
  Future<Map<String, Object?>> uploadOutputImage({
    required SessionGrant session,
    required String workerId,
    required String assignmentId,
    required File file,
  }) async {
    final name = p.basename(file.path);
    final request = await _client.postUrl(
      _uri('/api/worker-agent/outputs', {
        'assignmentId': assignmentId,
        'name': name,
      }),
    );
    _auth(request, session, workerId);
    request.headers.contentType = ContentType.parse(outputFileMediaType(name));
    request.contentLength = await file.length();
    await request.addStream(file.openRead());
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    if (response.statusCode >= 400) {
      throw ServerRefusal(response.statusCode, text);
    }
    final decoded = jsonDecode(text);
    final image = decoded is Map ? decoded['image'] : null;
    if (image is! Map || image['fileId'] is! String) {
      throw ServerRefusal(502, 'the upload answer was bad');
    }
    return Map<String, Object?>.from(image);
  }

  /// Downloads [ref] into [directory] (chosen by the caller, already checked
  /// against the Allowed Folders). The file is kept only if its checksum matches.
  Future<File> download({
    required SessionGrant session,
    required String workerId,
    required ArtifactRef ref,
    required Directory directory,
  }) async {
    final request = await _client.getUrl(
      _uri('/api/worker-agent/artifacts/${ref.artifactId}/content'),
    );
    _auth(request, session, workerId);
    request.headers.set('x-artifact-grant', ref.grantToken);
    final response = await request.close();
    if (response.statusCode >= 400) {
      await response.drain<void>();
      throw MissingArtifactException(
        '${ref.artifactId} could not be downloaded (${response.statusCode})',
      );
    }
    await directory.create(recursive: true);
    final target = File(p.join(directory.path, safeArtifactName(ref.name)));
    final temp = File('${target.path}.part');
    final sink = temp.openWrite();
    try {
      await sink.addStream(response);
      await sink.close();
    } on Object {
      await sink.close().catchError((Object _) {});
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
    final actual = (await sha256.bind(temp.openRead()).first).toString();
    if (actual != ref.sha256) {
      await temp.delete();
      throw MissingArtifactException(
        '${ref.artifactId} failed its checksum and was discarded',
      );
    }
    await temp.rename(target.path);
    return target;
  }

  void close() => _client.close(force: true);
}
