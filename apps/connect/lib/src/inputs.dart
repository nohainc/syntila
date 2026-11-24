import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'server_api.dart';

/// Input Delivery v1 on the Worker path (docs/specifications/INPUT_DELIVERY_V1.md).
///
/// The person's files for a Work Request are uploaded to R2 before any Step
/// starts. Any Worker that runs a Step downloads them with its own session
/// right before its Engine starts, checks size and SHA-256, keeps a private
/// copy, and places them at `.syntila/inputs/<work-request-id>/file-NNN` in
/// the working directory, the paths the prompt names.

final _inputId = RegExp(
  r'^wrf-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _workRequestId = RegExp(r'^work-request-[0-9a-f-]{36}$');
final _digest = RegExp(r'^sha256:[0-9a-f]{64}$');

/// The largest plan limit; Cloud enforces each account's own limit on upload.
const maxInputBytes = 100 * 1024 * 1024;
const maxInputsPerRequest = 10;

class InputDeliveryException implements Exception {
  InputDeliveryException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The Agent's private copy of delivered files, one file per input ID.
class InputStore {
  InputStore(this.directory);

  final Directory directory;

  File _file(String fileId) {
    if (!_inputId.hasMatch(fileId)) {
      throw InputDeliveryException('invalid input id');
    }
    return File(p.join(directory.path, fileId));
  }

  /// True when a stored copy still has [sizeBytes] and [contentDigest].
  Future<bool> has(String fileId, int sizeBytes, String contentDigest) async {
    final file = _file(fileId);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    return await file.length() == sizeBytes &&
        await digestOf(file) == contentDigest;
  }

  /// Writes [bytes] to the store; keeps it only when size and digest match.
  Future<void> put(
    String fileId,
    Stream<List<int>> bytes, {
    required int sizeBytes,
    required String contentDigest,
  }) async {
    await directory.create(recursive: true);
    final target = _file(fileId);
    final temp = File('${target.path}.part');
    if (await FileSystemEntity.type(temp.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      await temp.delete();
    }
    final sink = temp.openWrite();
    var length = 0;
    try {
      await for (final chunk in bytes) {
        length += chunk.length;
        if (length > sizeBytes) {
          throw InputDeliveryException('the file is larger than announced');
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
    } on Object {
      await sink.close().catchError((Object _) {});
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
    if (length != sizeBytes || await digestOf(temp) != contentDigest) {
      await temp.delete();
      throw InputDeliveryException('the file failed its checksum');
    }
    await temp.rename(target.path);
  }

  /// Copies a stored file to [target], verifying it on the way.
  Future<void> copyTo(
    String fileId,
    File target, {
    required int sizeBytes,
    required String contentDigest,
  }) async {
    if (!await has(fileId, sizeBytes, contentDigest)) {
      throw InputDeliveryException('a file for this request is missing');
    }
    final temp = File('${target.path}.part');
    await _file(fileId).copy(temp.path);
    if (await digestOf(temp) != contentDigest) {
      await temp.delete();
      throw InputDeliveryException('a file for this request changed');
    }
    await temp.rename(target.path);
  }

  static Future<String> digestOf(File file) async =>
      'sha256:${(await sha256.bind(file.openRead()).first)}';
}

/// The Cloud side of Input Delivery, called with the Agent's session.
abstract interface class InputCloud {
  Future<Stream<List<int>>> download(SessionGrant session, String fileId);
}

class HttpInputCloud implements InputCloud {
  HttpInputCloud(this.baseUrl, {required this.workerId, HttpClient? client})
    : _client = client ?? HttpClient();

  final String baseUrl;
  final String workerId;
  final HttpClient _client;

  Uri _uri(String path) {
    final base = Uri.parse(baseUrl);
    return base.replace(
      path: '${base.path}/api/worker-agent/inputs$path'.replaceAll('//', '/'),
    );
  }

  void _auth(HttpClientRequest request, SessionGrant session) {
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${session.sessionToken}')
      ..set('x-worker-id', workerId)
      ..set('x-worker-session-id', session.sessionId);
  }

  @override
  Future<Stream<List<int>>> download(
    SessionGrant session,
    String fileId,
  ) async {
    final request = await _client.getUrl(_uri('/$fileId/content'));
    _auth(request, session);
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode >= 400) {
      await response.drain<void>();
      throw ServerRefusal(response.statusCode, 'input download failed');
    }
    return response;
  }
}

/// Downloads a request's files and places them for an assignment.
class InputDelivery {
  InputDelivery({required this.cloud, required this.store, this.log});

  final InputCloud cloud;
  final InputStore store;
  final void Function(String line)? log;

  /// The Agent's current session, kept up to date by the runtime.
  SessionGrant? session;

  Future<void> _fetch(
    SessionGrant session,
    String fileId,
    int sizeBytes,
    String contentDigest,
  ) async {
    if (await store.has(fileId, sizeBytes, contentDigest)) return;
    await store.put(
      fileId,
      await cloud.download(session, fileId),
      sizeBytes: sizeBytes,
      contentDigest: contentDigest,
    );
  }

  /// Writes each file attachment of [payload] to
  /// `.syntila/inputs/<work-request-id>/file-NNN` under [workingDirectory].
  /// A file this computer does not have yet is downloaded first.
  Future<void> materialize(
    Directory workingDirectory,
    Map<String, Object?> payload,
    SessionGrant? session,
  ) async {
    final input = payload['input'];
    if (input is! Map || input['attachments'] is! List) return;
    final attachments = input['attachments'] as List;
    final files = [
      for (final (index, value) in attachments.indexed)
        if (value is Map && value['kind'] == 'file') (index, value),
    ];
    if (files.isEmpty) return;
    if (attachments.length > maxInputsPerRequest) {
      throw InputDeliveryException('too many files for one request');
    }
    final snapshot = payload['snapshot'];
    final requestId =
        payload['workRequestId'] ??
        (snapshot is Map ? snapshot['workRequestId'] : null);
    if (requestId is! String || !_workRequestId.hasMatch(requestId)) {
      throw InputDeliveryException('files without a valid Work Request');
    }
    var directory = workingDirectory;
    for (final segment in ['.syntila', 'inputs', requestId]) {
      directory = Directory(p.join(directory.path, segment));
      final type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        await directory.create();
      } else if (type != FileSystemEntityType.directory) {
        throw InputDeliveryException('unsafe input folder');
      }
    }
    for (final (index, value) in files) {
      final fileId = value['fileId'];
      final size = value['sizeBytes'];
      final digest = value['contentDigest'];
      if (fileId is! String ||
          !_inputId.hasMatch(fileId) ||
          size is! int ||
          size > maxInputBytes ||
          digest is! String ||
          !_digest.hasMatch(digest)) {
        throw InputDeliveryException('invalid file input');
      }
      final target = File(
        p.join(
          directory.path,
          'file-${(index + 1).toString().padLeft(3, '0')}',
        ),
      );
      final type = await FileSystemEntity.type(target.path, followLinks: false);
      if (type == FileSystemEntityType.file &&
          await target.length() == size &&
          await InputStore.digestOf(target) == digest) {
        continue; // a retry reuses the copy already in place
      }
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw InputDeliveryException('unsafe input file');
      }
      if (!await store.has(fileId, size, digest)) {
        if (session == null) {
          throw InputDeliveryException('a file for this request is missing');
        }
        await _fetch(session, fileId, size, digest);
      }
      await store.copyTo(
        fileId,
        target,
        sizeBytes: size,
        contentDigest: digest,
      );
    }
  }
}
