import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Checks a signed Tool Profile. The shipped verifier lives with the signed
/// Tool Profile trust roots; the cache only stores what a verifier accepted.
abstract class ProfileVerifier {
  Future<bool> verify(List<int> profileBytes, String? signature);
}

class ProfileRejectedException implements Exception {
  ProfileRejectedException(this.reason);
  final String reason;

  @override
  String toString() => 'Profile rejected: $reason';
}

String profileDigest(List<int> bytes) => 'sha256:${sha256.convert(bytes)}';

/// Last-known-good signed Profile cache. Entries are content-addressed, are
/// re-hashed when read, and a bad update never replaces a good one.
class ProfileCache {
  ProfileCache(this.directory, this.verifier);

  final Directory directory;
  final ProfileVerifier verifier;

  File _file(String digest) =>
      File('${directory.path}/${digest.replaceFirst(':', '-')}.profile');
  File get _pointer => File('${directory.path}/last-known-good.json');

  /// Verifies and stores a Profile; promotes it to last-known-good only when
  /// [revision] is not older than the current one.
  Future<String> put(
    List<int> bytes, {
    String? signature,
    required int revision,
    String? expectedDigest,
  }) async {
    final digest = profileDigest(bytes);
    if (expectedDigest != null && expectedDigest != digest) {
      throw ProfileRejectedException('digest mismatch');
    }
    if (!await verifier.verify(bytes, signature)) {
      throw ProfileRejectedException('signature not valid');
    }
    await directory.create(recursive: true);
    await _file(digest).writeAsBytes(bytes, flush: true);
    final current = await _readPointer();
    if (current == null || revision >= current.revision) {
      final temp = File('${_pointer.path}.tmp');
      await temp.writeAsString(
        jsonEncode({'digest': digest, 'revision': revision}),
        flush: true,
      );
      await temp.rename(_pointer.path);
    }
    return digest;
  }

  /// The bytes for [digest], or null when missing or when the stored bytes no
  /// longer hash to it (tampering or corruption).
  Future<List<int>?> read(String digest) async {
    final file = _file(digest);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return profileDigest(bytes) == digest ? bytes : null;
  }

  Future<({String digest, int revision})?> _readPointer() async {
    if (!await _pointer.exists()) return null;
    try {
      final decoded = jsonDecode(await _pointer.readAsString());
      if (decoded is Map &&
          decoded['digest'] is String &&
          decoded['revision'] is int) {
        return (
          digest: decoded['digest'] as String,
          revision: decoded['revision'] as int,
        );
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<({String digest, int revision, List<int> bytes})?>
  lastKnownGood() async {
    final pointer = await _readPointer();
    if (pointer == null) return null;
    final bytes = await read(pointer.digest);
    if (bytes == null) return null;
    return (digest: pointer.digest, revision: pointer.revision, bytes: bytes);
  }

  /// Whether an assignment's pinned [digest] can be served from the cache.
  Future<bool> has(String digest) async => await read(digest) != null;
}
