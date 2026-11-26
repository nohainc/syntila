import 'dart:convert';
import 'package:cryptography/cryptography.dart';

/// Public verification roots shipped with Connect and Profile Lab.
/// Values are base64 raw Ed25519 public keys, keyed by publisher and explicit key ID.
/// This class never accepts signing secrets.
class WorkerTrustPolicy {
  WorkerTrustPolicy({
    Map<String, Map<String, String>> trustedPublicKeys = const {},
    Set<String> revokedDigests = const {},
    Set<String> revokedPublishers = const {},
    Set<String> revokedKeyIds = const {},
    Set<String> revokedReleaseIds = const {},
  })  : trustedPublicKeys = Map.unmodifiable({
          for (final entry in trustedPublicKeys.entries)
            entry.key: Map<String, String>.unmodifiable(entry.value),
        }),
        _revokedDigests = Set.of(revokedDigests),
        _revokedPublishers = Set.of(revokedPublishers),
        _revokedKeyIds = Set.of(revokedKeyIds),
        _revokedReleaseIds = Set.of(revokedReleaseIds);

  final Map<String, Map<String, String>> trustedPublicKeys;

  Set<String> _revokedDigests;
  Set<String> _revokedPublishers;
  Set<String> _revokedKeyIds;
  Set<String> _revokedReleaseIds;
  int _revocationRevision = 0;

  /// Increments every time the revocation sets are replaced. Caches of
  /// verified Profile state compare it to notice a revocation without
  /// re-verifying anything.
  int get revocationRevision => _revocationRevision;

  Set<String> get revokedDigests => Set.unmodifiable(_revokedDigests);
  Set<String> get revokedPublishers => Set.unmodifiable(_revokedPublishers);
  Set<String> get revokedKeyIds => Set.unmodifiable(_revokedKeyIds);
  Set<String> get revokedReleaseIds => Set.unmodifiable(_revokedReleaseIds);

  void updateRevocations({
    Set<String> digests = const {},
    Set<String> publishers = const {},
    Set<String> keyIds = const {},
    Set<String> releaseIds = const {},
  }) {
    _revokedDigests = Set.of(digests);
    _revokedPublishers = Set.of(publishers);
    _revokedKeyIds = Set.of(keyIds);
    _revokedReleaseIds = Set.of(releaseIds);
    _revocationRevision += 1;
  }

  Future<bool> verify({
    required String publisher,
    required String signingKeyId,
    required String digest,
    required String signature,
  }) async {
    if (_revokedDigests.contains(digest) ||
        _revokedPublishers.contains(publisher) ||
        _revokedKeyIds.contains(signingKeyId)) {
      return false;
    }
    return _verifySignature(
      publisher: publisher,
      signingKeyId: signingKeyId,
      signature: signature,
      message: utf8.encode('syntila-worker-release-v1\n$digest'),
    );
  }

  Future<bool> _verifySignature({
    required String publisher,
    required String signingKeyId,
    required String signature,
    required List<int> message,
  }) async {
    final keyBase64 = trustedPublicKeys[publisher]?[signingKeyId];
    if (keyBase64 == null) return false;
    try {
      final publicKeyBytes = base64.decode(keyBase64);
      final signatureBytes = base64.decode(signature);
      if (publicKeyBytes.length != 32 || signatureBytes.length != 64) {
        return false;
      }
      final algorithm = Ed25519();
      final publicKey = SimplePublicKey(
        publicKeyBytes,
        type: KeyPairType.ed25519,
      );
      return await algorithm.verify(
        message,
        signature: Signature(
          signatureBytes,
          publicKey: publicKey,
        ),
      );
    } on Object {
      return false;
    }
  }
}

/// Helper to parse release trust roots from JSON or environment configuration.
class ReleaseTrustRoots {
  const ReleaseTrustRoots._();

  static Map<String, Map<String, String>> parse(String jsonString) {
    try {
      final value = jsonDecode(jsonString);
      if (value is! Map) return const {};
      return {
        for (final publisher in value.entries)
          if (publisher.key is String && publisher.value is Map)
            publisher.key as String: {
              for (final key in (publisher.value as Map).entries)
                if (key.key is String && key.value is String)
                  key.key as String: key.value as String,
            },
      };
    } on Object {
      return const {};
    }
  }

  static WorkerTrustPolicy createPolicy(String jsonString) =>
      WorkerTrustPolicy(trustedPublicKeys: parse(jsonString));
}
