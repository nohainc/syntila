import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart';

import 'base64url.dart';
import 'paths.dart';
import 'windows_dpapi.dart';

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
    // Protect the directory before creating the temporary file, so no other
    // user can read the key during the interval before its mode is set.
    await AgentPaths.restrict(file.parent);
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

/// A per-installation macOS Keychain entry. Existing private files are copied
/// only after Keychain readback succeeds; conflicting identities fail closed.
class MacKeychainKeyStore implements KeyStore {
  MacKeychainKeyStore(this.legacyFile, {this.executable = 'security'})
    : account = sha256
          .convert(utf8.encode(legacyFile.absolute.path))
          .toString();

  final File legacyFile;
  final String executable;
  final String account;
  static const service = 'com.syntila.worker.agent-key.v1';

  Future<AgentKey?> _read() async {
    final result = await Process.run(executable, [
      'find-generic-password',
      '-a',
      account,
      '-s',
      service,
      '-w',
    ]);
    if (result.exitCode == 44) return null;
    if (result.exitCode != 0) {
      throw StateError('macOS Keychain could not read the Worker credential');
    }
    final decoded = jsonDecode((result.stdout as String).trim());
    if (decoded is! Map ||
        decoded['privateKey'] is! String ||
        decoded['publicKey'] is! String) {
      throw const FormatException('the Keychain credential is damaged');
    }
    return AgentKey(
      privateKey: fromBase64Url(decoded['privateKey'] as String),
      publicKey: fromBase64Url(decoded['publicKey'] as String),
    );
  }

  @override
  Future<AgentKey?> load() async {
    final stored = await _read();
    final legacy = await FileKeyStore(legacyFile).load();
    if (legacy == null) return stored;
    if (stored != null &&
        (stored.publicKeyText != legacy.publicKeyText ||
            toBase64Url(stored.privateKey) != toBase64Url(legacy.privateKey))) {
      throw StateError(
        'Worker credentials disagree; preserve both and resolve the migration',
      );
    }
    if (stored == null) await save(legacy);
    final verified = await _read();
    if (verified == null ||
        verified.publicKeyText != legacy.publicKeyText ||
        toBase64Url(verified.privateKey) != toBase64Url(legacy.privateKey)) {
      throw StateError('macOS Keychain credential readback failed');
    }
    await FileKeyStore(legacyFile).delete();
    return verified;
  }

  @override
  Future<void> save(AgentKey key) async {
    final value = jsonEncode({
      'version': 1,
      'privateKey': toBase64Url(key.privateKey),
      'publicKey': key.publicKeyText,
    });
    final hex = utf8
        .encode(value)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final process = await Process.start(executable, ['-i']);
    process.stdin.writeln(
      'add-generic-password -a "$account" -s "$service" -U -X $hex',
    );
    await process.stdin.close();
    final stdoutDone = process.stdout.drain<void>();
    final stderrDone = process.stderr.drain<void>();
    final exitCode = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
    if (exitCode != 0) {
      throw StateError('macOS Keychain rejected the Worker credential');
    }
  }

  @override
  Future<void> delete() async {
    final result = await Process.run(executable, [
      'delete-generic-password',
      '-a',
      account,
      '-s',
      service,
    ]);
    if (result.exitCode != 0 && result.exitCode != 44) {
      throw StateError('macOS Keychain could not delete the Worker credential');
    }
    await FileKeyStore(legacyFile).delete();
  }
}

/// Linux Secret Service adapter, enabled explicitly and recorded per Agent so
/// a service started without the original environment never falls back to a file.
class LinuxSecretKeyStore implements KeyStore {
  LinuxSecretKeyStore(
    this.legacyFile,
    this.marker, {
    this.executable = 'secret-tool',
  }) : account = sha256
           .convert(utf8.encode(legacyFile.absolute.path))
           .toString();
  final File legacyFile;
  final File marker;
  final String executable;
  final String account;
  static const service = 'com.syntila.worker.agent-key.v1';

  Future<void> _recordSelection() async {
    if (await marker.exists()) {
      if ((await marker.readAsString()).trim() != 'secret-service') {
        throw StateError(
          'Unknown Worker credential store; state was preserved',
        );
      }
      return;
    }
    await marker.parent.create(recursive: true);
    await AgentPaths.restrict(marker.parent);
    await marker.writeAsString('secret-service\n', flush: true);
    await AgentPaths.restrict(marker);
  }

  Future<AgentKey?> _read() async {
    final result = await Process.run(executable, [
      'lookup',
      'service',
      service,
      'account',
      account,
    ]);
    if (result.exitCode == 1 && (result.stderr as String).trim().isEmpty) {
      return null;
    }
    if (result.exitCode != 0) {
      throw StateError(
        'Linux Secret Service could not read the Worker credential',
      );
    }
    final decoded = jsonDecode((result.stdout as String).trim());
    if (decoded is! Map ||
        decoded['privateKey'] is! String ||
        decoded['publicKey'] is! String) {
      throw const FormatException('the Secret Service credential is damaged');
    }
    return AgentKey(
      privateKey: fromBase64Url(decoded['privateKey'] as String),
      publicKey: fromBase64Url(decoded['publicKey'] as String),
    );
  }

  @override
  Future<AgentKey?> load() async {
    await _recordSelection();
    final stored = await _read();
    final legacy = await FileKeyStore(legacyFile).load();
    if (legacy == null) return stored;
    if (stored != null &&
        (stored.publicKeyText != legacy.publicKeyText ||
            toBase64Url(stored.privateKey) != toBase64Url(legacy.privateKey))) {
      throw StateError(
        'Worker credentials disagree; preserve both and resolve the migration',
      );
    }
    if (stored == null) await save(legacy);
    final verified = await _read();
    if (verified == null ||
        verified.publicKeyText != legacy.publicKeyText ||
        toBase64Url(verified.privateKey) != toBase64Url(legacy.privateKey)) {
      throw StateError('Linux Secret Service credential readback failed');
    }
    await FileKeyStore(legacyFile).delete();
    return verified;
  }

  @override
  Future<void> save(AgentKey key) async {
    await _recordSelection();
    final process = await Process.start(executable, [
      'store',
      '--label',
      'Syntila Worker credential',
      'service',
      service,
      'account',
      account,
    ]);
    process.stdin.write(
      jsonEncode({
        'version': 1,
        'privateKey': toBase64Url(key.privateKey),
        'publicKey': key.publicKeyText,
      }),
    );
    await process.stdin.close();
    final stdoutDone = process.stdout.drain<void>();
    final stderrDone = process.stderr.drain<void>();
    final code = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
    if (code != 0) {
      throw StateError('Linux Secret Service rejected the Worker credential');
    }
  }

  @override
  Future<void> delete() async {
    await _recordSelection();
    final result = await Process.run(executable, [
      'clear',
      'service',
      service,
      'account',
      account,
    ]);
    if (result.exitCode != 0 &&
        !(result.exitCode == 1 && (result.stderr as String).trim().isEmpty)) {
      throw StateError(
        'Linux Secret Service could not delete the Worker credential',
      );
    }
    await FileKeyStore(legacyFile).delete();
  }
}

typedef DpapiTransform =
    List<int> Function(
      List<int> bytes,
      String context, {
      required bool decrypt,
    });

/// Current-user DPAPI protects both the active and pending credentials.
class WindowsDpapiKeyStore implements KeyStore {
  WindowsDpapiKeyStore(this.legacyFile, {DpapiTransform? transform})
    : transform = transform ?? WindowsDpapi.transform,
      context =
          'syntila-worker-key-v1:${sha256.convert(utf8.encode(legacyFile.absolute.path))}';
  final File legacyFile;
  final DpapiTransform transform;
  final String context;
  File get encryptedFile => File('${legacyFile.path}.dpapi');

  Future<AgentKey?> _read() async {
    if (!await encryptedFile.exists()) return null;
    if (await encryptedFile.length() > 1024 * 1024) {
      throw StateError('Credential exceeds limit');
    }
    final decoded = jsonDecode(
      utf8.decode(
        transform(await encryptedFile.readAsBytes(), context, decrypt: true),
      ),
    );
    if (decoded is! Map ||
        decoded['privateKey'] is! String ||
        decoded['publicKey'] is! String) {
      throw const FormatException('the DPAPI credential is damaged');
    }
    return AgentKey(
      privateKey: fromBase64Url(decoded['privateKey'] as String),
      publicKey: fromBase64Url(decoded['publicKey'] as String),
    );
  }

  @override
  Future<AgentKey?> load() async {
    final stored = await _read();
    final legacy = await FileKeyStore(legacyFile).load();
    if (legacy == null) return stored;
    if (stored != null &&
        (stored.publicKeyText != legacy.publicKeyText ||
            toBase64Url(stored.privateKey) != toBase64Url(legacy.privateKey))) {
      throw StateError(
        'Worker credentials disagree; preserve both and resolve the migration',
      );
    }
    if (stored == null) await save(legacy);
    final verified = await _read();
    if (verified == null ||
        verified.publicKeyText != legacy.publicKeyText ||
        toBase64Url(verified.privateKey) != toBase64Url(legacy.privateKey)) {
      throw StateError('Windows DPAPI credential readback failed');
    }
    await FileKeyStore(legacyFile).delete();
    return verified;
  }

  @override
  Future<void> save(AgentKey key) async {
    await encryptedFile.parent.create(recursive: true);
    final payload = utf8.encode(
      jsonEncode({
        'version': 1,
        'privateKey': toBase64Url(key.privateKey),
        'publicKey': key.publicKeyText,
      }),
    );
    final encrypted = transform(payload, context, decrypt: false);
    final temporary = File('${encryptedFile.path}.$pid.tmp');
    try {
      await temporary.writeAsBytes(encrypted, flush: true);
      await temporary.rename(encryptedFile.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<void> delete() async {
    if (await encryptedFile.exists()) await encryptedFile.delete();
    await FileKeyStore(legacyFile).delete();
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
    this.workerName,
    this.workerType,
  });

  final String workerId;
  final String serverUrl;
  final DateTime pairedAt;
  final String? workerName;
  final String? workerType;

  /// Human-friendly label: the configured name, the Worker Type, or the ID.
  String get displayName {
    final name = workerName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final type = workerType?.trim();
    if (type != null && type.isNotEmpty) return type;
    return workerId;
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'workerId': workerId,
    'serverUrl': serverUrl,
    'pairedAt': pairedAt.toUtc().toIso8601String(),
    if (workerName != null && workerName!.trim().isNotEmpty)
      'workerName': workerName!.trim(),
    if (workerType != null && workerType!.trim().isNotEmpty)
      'workerType': workerType!.trim(),
  };

  factory AgentIdentity.fromJson(Map<String, Object?> json) {
    final workerId = json['workerId'];
    final serverUrl = json['serverUrl'];
    final pairedAt = json['pairedAt'];
    final workerName = json['workerName'];
    final workerType = json['workerType'];
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
      workerName: workerName is String ? workerName : null,
      workerType: workerType is String ? workerType : null,
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
/// the Worker id, the challenge id and the single-use secret (plus optional
/// `n` name and `t` workerType metadata). The owner's device renders it; the
/// secret is never put in a URL.
class PairingCode {
  const PairingCode({
    required this.serverUrl,
    required this.workerId,
    required this.challengeId,
    required this.secret,
    this.workerName,
    this.workerType,
  });

  final String serverUrl;
  final String workerId;
  final String challengeId;
  final String secret;
  final String? workerName;
  final String? workerType;

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
            if (workerName != null) 'n': workerName,
            if (workerType != null) 't': workerType,
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
      workerName: decoded['n'] is String ? decoded['n'] as String : null,
      workerType: decoded['t'] is String ? decoded['t'] as String : null,
    );
  }
}
