import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'secure_credentials.dart';

/// Encrypts provider failures before they enter the assignment journal.
/// The per-installation key stays in the platform credential store.
class ProviderFailureCipher {
  ProviderFailureCipher(this.credentials, this.journal, this.installationId);

  final SecureCredentialStore credentials;
  final File journal;
  final String installationId;
  final AesGcm _cipher = AesGcm.with256bits();
  Future<SecretKey>? _keyFuture;

  String get _keyName => 'provider-failure-key-v1:$installationId';

  Future<SecretKey> _key({required bool allowCreate}) async {
    final existing = _keyFuture;
    if (existing != null) return existing;
    final pending = _loadKey(allowCreate: allowCreate);
    _keyFuture = pending;
    try {
      return await pending;
    } on Object {
      _keyFuture = null;
      rethrow;
    }
  }

  Future<SecretKey> _loadKey({required bool allowCreate}) async {
    var encoded = await credentials.read(_keyName);
    if (encoded == null) {
      if (!allowCreate ||
          (await journal.exists() &&
              (await journal.readAsString())
                  .contains('"providerFailureEncrypted"'))) {
        throw StateError('Provider failure encryption key is unavailable');
      }
      final key = await _cipher.newSecretKey();
      encoded = base64Encode(await key.extractBytes());
      await credentials.write(_keyName, encoded);
      if (await credentials.read(_keyName) != encoded) {
        throw StateError('Provider failure encryption key was not retained');
      }
    }
    final bytes = base64Decode(encoded);
    if (bytes.length != 32) {
      throw const FormatException('Invalid encryption key');
    }
    return SecretKey(bytes);
  }

  Future<Map<String, Object?>> encrypt(
      String assignmentId, Map<String, Object?> details) async {
    final encrypted = await _cipher.encrypt(
      utf8.encode(jsonEncode(details)),
      secretKey: await _key(allowCreate: true),
      aad: utf8.encode(assignmentId),
    );
    return {
      'version': 1,
      'nonce': base64Encode(encrypted.nonce),
      'ciphertext': base64Encode(encrypted.cipherText),
      'mac': base64Encode(encrypted.mac.bytes),
    };
  }

  Future<Map<String, Object?>> decrypt(
      String assignmentId, Map<String, Object?> envelope) async {
    if (envelope['version'] != 1 ||
        envelope['nonce'] is! String ||
        envelope['ciphertext'] is! String ||
        envelope['mac'] is! String) {
      throw const FormatException('Invalid encrypted provider failure');
    }
    final decoded = await _cipher.decrypt(
      SecretBox(
        base64Decode(envelope['ciphertext']! as String),
        nonce: base64Decode(envelope['nonce']! as String),
        mac: Mac(base64Decode(envelope['mac']! as String)),
      ),
      secretKey: await _key(allowCreate: false),
      aad: utf8.encode(assignmentId),
    );
    final value = jsonDecode(utf8.decode(decoded));
    if (value is! Map) throw const FormatException('Invalid provider failure');
    return Map<String, Object?>.from(value);
  }
}
