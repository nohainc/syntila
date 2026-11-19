import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'base64url.dart';
import 'paths.dart';

/// The Worker's Ed25519 key pair. The private key never leaves the host; only
/// [publicKeyText] is sent to the server.
class AgentKey {
  AgentKey({required this.privateKey, required this.publicKey});

  final List<int> privateKey;
  final List<int> publicKey;

  String get publicKeyText => toBase64Url(publicKey);
}

/// Where the private key lives. A platform secret-store adapter implements the
/// same interface; the shipped implementation is an owner-only private file.
abstract class KeyStore {
  Future<AgentKey?> load();
  Future<void> save(AgentKey key);
  Future<void> delete();
}

class MemoryKeyStore implements KeyStore {
  AgentKey? _key;

  @override
  Future<AgentKey?> load() async => _key;

  @override
  Future<void> save(AgentKey key) async => _key = key;

  @override
  Future<void> delete() async => _key = null;
}

/// A private file inside the Worker's own `identity/` directory (mode 0600 on
/// POSIX). Written atomically so a crash never leaves half a key.
class FileKeyStore implements KeyStore {
  FileKeyStore(this.file);

  final File file;

  @override
  Future<AgentKey?> load() async {
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map ||
        decoded['privateKey'] is! String ||
        decoded['publicKey'] is! String) {
      throw const FormatException('the key file is damaged');
    }
    return AgentKey(
      privateKey: fromBase64Url(decoded['privateKey'] as String),
      publicKey: fromBase64Url(decoded['publicKey'] as String),
    );
  }

  @override
  Future<void> save(AgentKey key) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'version': 1,
        'privateKey': toBase64Url(key.privateKey),
        'publicKey': key.publicKeyText,
      }),
      flush: true,
    );
    await AgentPaths.restrict(temp);
    await temp.rename(file.path);
  }

  @override
  Future<void> delete() async {
    if (await file.exists()) {
      // Overwrite before unlinking so the key does not linger in the file.
      await file.writeAsBytes(List<int>.filled(128, 0), flush: true);
      await file.delete();
    }
  }
}

final _ed25519 = Ed25519();

Future<AgentKey> generateAgentKey() async {
  final pair = await _ed25519.newKeyPair();
  final data = await pair.extract();
  final publicKey = await pair.extractPublicKey();
  return AgentKey(
    privateKey: await data.extractPrivateKeyBytes(),
    publicKey: publicKey.bytes,
  );
}

Future<String> signMessage(AgentKey key, String message) async {
  final pair = SimpleKeyPairData(
    key.privateKey,
    publicKey: SimplePublicKey(key.publicKey, type: KeyPairType.ed25519),
    type: KeyPairType.ed25519,
  );
  final signature = await _ed25519.sign(utf8.encode(message), keyPair: pair);
  return toBase64Url(signature.bytes);
}

Future<bool> verifyMessage(
  String publicKeyText,
  String message,
  String signatureText,
) async {
  try {
    return await _ed25519.verify(
      utf8.encode(message),
      signature: Signature(
        fromBase64Url(signatureText),
        publicKey: SimplePublicKey(
          fromBase64Url(publicKeyText),
          type: KeyPairType.ed25519,
        ),
      ),
    );
  } on Object {
    return false;
  }
}

/// Signed texts. They match `pairingMessage` and `actionMessage` in
/// `apps/backend/src/domain/worker-agents.ts` byte for byte.
String pairingMessage(String challengeId, String workerId, String publicKey) =>
    'syntila-worker/v1\npair\n$challengeId\n$workerId\n$publicKey';

String actionMessage(
  String action,
  String workerId,
  String nonceId,
  String nonce, [
  String extra = '',
]) => 'syntila-worker/v1\n$action\n$workerId\n$nonceId\n$nonce\n$extra';

/// What is stored beside the key: who this installation is. The Agent never
/// declares an owner or actor of its own; the server decides both.
class AgentIdentity {
  const AgentIdentity({
    required this.workerId,
    required this.serverUrl,
    required this.pairedAt,
  });

  final String workerId;
  final String serverUrl;
  final DateTime pairedAt;

  Map<String, Object?> toJson() => {
    'version': 1,
    'workerId': workerId,
    'serverUrl': serverUrl,
    'pairedAt': pairedAt.toUtc().toIso8601String(),
  };

  factory AgentIdentity.fromJson(Map<String, Object?> json) {
    final workerId = json['workerId'];
    final serverUrl = json['serverUrl'];
    final pairedAt = json['pairedAt'];
    if (workerId is! String ||
        workerId.isEmpty ||
        serverUrl is! String ||
        serverUrl.isEmpty ||
        pairedAt is! String) {
      throw const FormatException('the identity file is damaged');
    }
    return AgentIdentity(
      workerId: workerId,
      serverUrl: serverUrl,
      pairedAt: DateTime.parse(pairedAt),
    );
  }

  static Future<AgentIdentity?> load(File file) async {
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('the identity file is damaged');
    }
    return AgentIdentity.fromJson(decoded);
  }

  Future<void> save(File file) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(toJson()), flush: true);
    await temp.rename(file.path);
  }
}

/// A pairing code is `syntila-pair:v1:<base64url(json)>` with the server URL,
/// the Worker id, the challenge id and the single-use secret. The owner's
/// device renders it; the secret is never put in a URL.
class PairingCode {
  const PairingCode({
    required this.serverUrl,
    required this.workerId,
    required this.challengeId,
    required this.secret,
  });

  final String serverUrl;
  final String workerId;
  final String challengeId;
  final String secret;

  static const prefix = 'syntila-pair:v1:';

  String encode() =>
      prefix +
      toBase64Url(
        utf8.encode(
          jsonEncode({
            's': serverUrl,
            'w': workerId,
            'c': challengeId,
            'k': secret,
          }),
        ),
      );

  factory PairingCode.parse(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith(prefix)) {
      throw const FormatException('not a Syntila pairing code');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(
        utf8.decode(fromBase64Url(trimmed.substring(prefix.length))),
      );
    } on Object {
      throw const FormatException('the pairing code is damaged');
    }
    if (decoded is! Map ||
        decoded['s'] is! String ||
        decoded['w'] is! String ||
        decoded['c'] is! String ||
        decoded['k'] is! String) {
      throw const FormatException('the pairing code is incomplete');
    }
    final server = decoded['s'] as String;
    final uri = Uri.tryParse(server);
    final local =
        uri != null &&
        (uri.host == 'localhost' ||
            uri.host == '127.0.0.1' ||
            uri.host == '::1');
    if (uri == null ||
        !(uri.scheme == 'https' || (uri.scheme == 'http' && local))) {
      throw const FormatException('the pairing code must name an https server');
    }
    return PairingCode(
      serverUrl: server,
      workerId: decoded['w'] as String,
      challengeId: decoded['c'] as String,
      secret: decoded['k'] as String,
    );
  }
}
