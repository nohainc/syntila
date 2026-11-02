import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Per-file limit, the largest any Syntila plan uploads (decimal: 100 MB).
/// Cloud enforces each account's own, smaller-or-equal limit at upload time;
/// this bound only protects the Workspace from an oversized manifest.
const maxWorkRequestInputBytes = 100000000;

final _fileIdPattern = RegExp(
    r'^wrf-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _digestPattern = RegExp(r'^sha256:[0-9a-f]{64}$');

/// Whether [fileId] is a Cloud-generated Work Request input identity.
bool isWorkRequestInputId(Object? fileId) =>
    fileId is String && _fileIdPattern.hasMatch(fileId);

/// Thrown when an input cannot be stored or read. [message] is safe to show
/// to the requesting user.
class WorkRequestInputStagingException implements Exception {
  const WorkRequestInputStagingException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Runtime-owned store for Work Request input files downloaded through Input
/// Delivery v1. Files live under Application Support, never the Work Root;
/// each assignment copies them into its execution directory, so every
/// Workflow step and retry reuses one download. Content is verified against
/// its digest on write and again on read, and kept for [retention].
class WorkRequestInputStaging {
  WorkRequestInputStaging(this.directory,
      {this.retention = const Duration(days: 7), DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Directory directory;
  final Duration retention;
  final DateTime Function() _clock;

  File _fileFor(String fileId) =>
      File('${directory.path}${Platform.pathSeparator}$fileId');

  /// Whether a verified copy of [fileId] is already stored.
  Future<bool> contains(String fileId) async =>
      _fileIdPattern.hasMatch(fileId) &&
      await FileSystemEntity.type(_fileFor(fileId).path, followLinks: false) ==
          FileSystemEntityType.file;

  /// Streams [content] to a temporary file while hashing it, then publishes
  /// it atomically only when size and digest match. A failed write leaves
  /// nothing behind, so a retry always restarts the whole file.
  Future<void> stageStream({
    required String fileId,
    required int sizeBytes,
    required String contentDigest,
    required Stream<List<int>> content,
  }) async {
    _checkIdentity(fileId, contentDigest);
    if (sizeBytes < 0 || sizeBytes > maxWorkRequestInputBytes) {
      throw const WorkRequestInputStagingException(
          'size_mismatch', 'The file size is not allowed.');
    }
    await _ensureDirectory();
    final target = _fileFor(fileId);
    final temporary = File('${target.path}.partial');
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var received = 0;
    IOSink? sink;
    try {
      sink = temporary.openWrite();
      await for (final chunk in content) {
        received += chunk.length;
        if (received > sizeBytes) {
          throw const WorkRequestInputStagingException(
              'size_mismatch', 'The file is larger than the upload.');
        }
        hasher.add(chunk);
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      hasher.close();
      if (received != sizeBytes) {
        throw const WorkRequestInputStagingException(
            'size_mismatch', 'The file size does not match the upload.');
      }
      if ('sha256:${digestSink.value}' != contentDigest) {
        throw const WorkRequestInputStagingException(
            'digest_mismatch', 'The file content does not match the upload.');
      }
      await temporary.rename(target.path);
    } catch (error) {
      try {
        await sink?.close();
      } on Object {
        // Already failing.
      }
      try {
        await temporary.delete();
      } on FileSystemException {
        // Nothing to clean up.
      }
      if (error is WorkRequestInputStagingException) rethrow;
      if (error is FileSystemException) {
        throw const WorkRequestInputStagingException(
            'storage_failed', 'The Workspace could not save the file.');
      }
      rethrow;
    }
    await _prune();
  }

  /// Returns staged content that still matches [sizeBytes] and
  /// [contentDigest], or throws when it is missing or changed.
  Future<List<int>> read({
    required String fileId,
    required int sizeBytes,
    required String contentDigest,
  }) async {
    _checkIdentity(fileId, contentDigest);
    final file = _fileFor(fileId);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw const WorkRequestInputStagingException('staged_input_missing',
          'A file for this request is not on the Workspace.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != sizeBytes ||
        'sha256:${sha256.convert(bytes)}' != contentDigest) {
      throw const WorkRequestInputStagingException('staged_input_changed',
          'A file for this request changed on the Workspace.');
    }
    return bytes;
  }

  /// Streams the verified staged copy of [fileId] to [target] without holding
  /// the file in memory. Size and digest are checked while copying and the
  /// result is published atomically, so a failed copy leaves nothing behind.
  Future<void> copyTo({
    required String fileId,
    required int sizeBytes,
    required String contentDigest,
    required File target,
  }) async {
    _checkIdentity(fileId, contentDigest);
    final source = _fileFor(fileId);
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const WorkRequestInputStagingException('staged_input_missing',
          'A file for this request is not on the Workspace.');
    }
    final temporary = File('${target.path}.partial');
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var copied = 0;
    IOSink? sink;
    try {
      sink = temporary.openWrite();
      await for (final chunk in source.openRead()) {
        copied += chunk.length;
        hasher.add(chunk);
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      hasher.close();
      if (copied != sizeBytes ||
          'sha256:${digestSink.value}' != contentDigest) {
        throw const WorkRequestInputStagingException('staged_input_changed',
            'A file for this request changed on the Workspace.');
      }
      await temporary.rename(target.path);
    } catch (_) {
      try {
        await sink?.close();
      } on Object {
        // Already failing.
      }
      try {
        await temporary.delete();
      } on FileSystemException {
        // Nothing to clean up.
      }
      rethrow;
    }
  }

  /// The digest and length of [file], streamed.
  static Future<({int length, String digest})> describe(File file) async {
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var length = 0;
    await for (final chunk in file.openRead()) {
      length += chunk.length;
      hasher.add(chunk);
    }
    hasher.close();
    return (length: length, digest: 'sha256:${digestSink.value}');
  }

  void _checkIdentity(String fileId, String contentDigest) {
    if (!_fileIdPattern.hasMatch(fileId) ||
        !_digestPattern.hasMatch(contentDigest)) {
      throw const WorkRequestInputStagingException(
          'invalid_input', 'The file reference is invalid.');
    }
  }

  Future<void> _ensureDirectory() async {
    final type =
        await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await directory.create(recursive: true);
    } else if (type != FileSystemEntityType.directory) {
      throw const WorkRequestInputStagingException(
          'storage_failed', 'The Workspace input store is unavailable.');
    }
  }

  Future<void> _prune() async {
    final cutoff = _clock().subtract(retention);
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        try {
          if ((await entity.lastModified()).isBefore(cutoff)) {
            await entity.delete();
          }
        } on FileSystemException {
          // Best effort; the next download retries.
        }
      }
    } on FileSystemException {
      // Best effort.
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;
  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
