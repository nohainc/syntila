import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';

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

String profileDigest(List<int> bytes) => sha256.convert(bytes).toString();

String? _digestHex(String value) {
  final hex = value.startsWith('sha256:') ? value.substring(7) : value;
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? hex : null;
}

/// Last-known-good signed Profile cache. Entries are content-addressed, are
/// re-hashed when read, and a bad update never replaces a good one.
class ProfileCache {
  ProfileCache(this.directory, this.verifier);

  final Directory directory;
  final ProfileVerifier verifier;

  File _file(String digest) => File('${directory.path}/sha256-$digest.profile');
  File _signatureFile(String digest) =>
      File('${directory.path}/sha256-$digest.signature.json');
  File get _pointer => File('${directory.path}/last-known-good.json');

  /// Admit a published snapshot only when it matches the assignment's pin.
  /// The snapshot verifier checks the schema, canonical digest and Type;
  /// [put] additionally requires a trusted signature over the canonical bytes.
  Future<String> putSnapshot(
    Object? snapshot, {
    required String workerTypeId,
    required int revision,
    required String digest,
    required String signature,
  }) async {
    final admitted = await WorkerProfileSnapshotVerifier.verify(
      input: snapshot,
      expectedWorkerTypeId: workerTypeId,
    );
    if (admitted.revision != revision ||
        admitted.payloadDigest != _digestHex(digest)) {
      throw ProfileRejectedException('snapshot does not match assignment');
    }
    final bytes = utf8.encode(canonicalJson(admitted.profile));
    return put(
      bytes,
      signature: signature,
      revision: revision,
      expectedDigest: digest,
    );
  }

  /// Verifies and stores a Profile; promotes it to last-known-good only when
  /// [revision] is not older than the current one.
  Future<String> put(
    List<int> bytes, {
    String? signature,
    required int revision,
    String? expectedDigest,
  }) async {
    final digest = profileDigest(bytes);
    if (expectedDigest != null && _digestHex(expectedDigest) != digest) {
      throw ProfileRejectedException('digest mismatch');
    }
    if (!await verifier.verify(bytes, signature)) {
      throw ProfileRejectedException('signature not valid');
    }
    await directory.create(recursive: true);
    // A cache entry must retain the proof that was verified at admission.
    // Write the proof before publishing the payload; interrupted writes fail
    // closed when the entry is read again.
    final proof = _signatureFile(digest);
    final proofTemp = File('${proof.path}.tmp');
    await proofTemp.writeAsString(
      jsonEncode({'signature': signature}),
      flush: true,
    );
    await proofTemp.rename(proof.path);
    final file = _file(digest);
    final fileTemp = File('${file.path}.tmp');
    await fileTemp.writeAsBytes(bytes, flush: true);
    await fileTemp.rename(file.path);
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
  /// longer hash to it, lack their proof, or fail current trust policy.
  Future<List<int>?> read(String digest) async {
    final hex = _digestHex(digest);
    if (hex == null) return null;
    final file = _file(hex);
    if (!await file.exists()) return null;
    try {
      final bytes = await file.readAsBytes();
      if (profileDigest(bytes) != hex) return null;
      final proof = jsonDecode(await _signatureFile(hex).readAsString());
      if (proof is! Map ||
          !proof.containsKey('signature') ||
          (proof['signature'] != null && proof['signature'] is! String)) {
        return null;
      }
      return await verifier.verify(bytes, proof['signature'] as String?)
          ? bytes
          : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
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

  /// The Engine revalidates the profile digest during initialization.
  Future<File?> verifiedFile(String digest) async {
    final hex = _digestHex(digest);
    if (hex == null || await read(hex) == null) return null;
    return _file(hex);
  }
}
