import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'base64url.dart';
import 'profile_cache.dart';

/// Parse build-time trust roots. An invalid configuration trusts no keys.
Map<String, String> parseProfileTrustRoots(String value) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map || decoded.isEmpty || decoded.length > 32) {
      return const {};
    }
    final roots = <String, String>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String ||
          entry.value is! String ||
          !RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(entry.key as String)) {
        return const {};
      }
      final key = entry.value as String;
      if (fromBase64Url(key).length != 32) return const {};
      roots[entry.key as String] = key;
    }
    return Map.unmodifiable(roots);
  } on Object {
    return const {};
  }
}

/// Verification of the v1 signed Profile proof. Trust roots are supplied by
/// the installation, never by the server response carrying the Profile.
class SignedProfileVerifier implements ProfileVerifier {
  SignedProfileVerifier(Map<String, String> trustedKeys)
    : _trustedKeys = Map.unmodifiable(trustedKeys);

  final Map<String, String> _trustedKeys;

  @override
  Future<bool> verify(List<int> profileBytes, String? signature) async {
    if (signature == null || signature.length > 4096) return false;
    try {
      final proof = jsonDecode(signature);
      if (proof is! Map ||
          proof.length != 3 ||
          proof['version'] != 1 ||
          proof['keyId'] is! String ||
          proof['signature'] is! String) {
        return false;
      }
      final keyText = _trustedKeys[proof['keyId']];
      if (keyText == null) return false;
      final key = fromBase64Url(keyText);
      final bytes = fromBase64Url(proof['signature'] as String);
      if (key.length != 32 || bytes.length != 64) return false;
      final message = utf8.encode(
        'syntila-worker-profile-v1\n${profileDigest(profileBytes)}',
      );
      return await Ed25519().verify(
        message,
        signature: Signature(
          bytes,
          publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
        ),
      );
    } on Object {
      return false;
    }
  }
}
