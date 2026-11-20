import 'identity.dart';
import 'lock.dart';
import 'paths.dart';
import 'server_api.dart';

/// Claims a Worker Instance with a pairing code and writes the Agent's
/// identity. The Agent generates the key pair here; only the public key is
/// sent, with a signature that proves it holds the private key.
///
/// If the claim fails nothing is left behind. A crash in the middle leaves a
/// `pairing.pending` marker, and the next `install` cleans the partial state
/// before trying again.
Future<AgentIdentity> installAgent({
  required PairingCode code,
  required AgentPaths paths,
  required KeyStore keyStore,
  ServerApi? api,
}) async {
  await paths.ensure();
  final lock = await AgentLock.acquire(paths.lockFile);
  final client = api ?? ServerApi(code.serverUrl);
  try {
    if (await paths.pairingMarker.exists()) {
      await keyStore.delete();
      if (await paths.identityFile.exists()) await paths.identityFile.delete();
      await paths.pairingMarker.delete();
    }
    if (await paths.identityFile.exists()) {
      throw StateError(
        'this data directory is already paired; start a transfer to move the Worker',
      );
    }
    final key = await generateAgentKey();
    final identity = AgentIdentity(
      workerId: code.workerId,
      serverUrl: code.serverUrl,
      pairedAt: DateTime.now().toUtc(),
    );
    await paths.pairingMarker.writeAsString('pending', flush: true);
    await keyStore.save(key);
    await identity.save(paths.identityFile);
    try {
      await client.claim(
        challengeId: code.challengeId,
        secret: code.secret,
        publicKey: key.publicKeyText,
        signature: await signMessage(
          key,
          pairingMessage(code.challengeId, code.workerId, key.publicKeyText),
        ),
      );
    } on Object {
      await keyStore.delete();
      if (await paths.identityFile.exists()) await paths.identityFile.delete();
      await paths.pairingMarker.delete();
      rethrow;
    }
    await paths.pairingMarker.delete();
    return identity;
  } finally {
    if (api == null) client.close();
    await lock.release();
  }
}

/// Replaces the key pair. Both keys sign, so neither a stolen old key nor a
/// stranger's new key can do it alone. The new key is written beside the old
/// one first and only replaces it after the server accepted the rotation.
Future<void> rotateCredential({
  required AgentPaths paths,
  required AgentIdentity identity,
  required KeyStore keyStore,
  ServerApi? api,
}) async {
  final lock = await AgentLock.acquire(paths.lockFile);
  final client = api ?? ServerApi(identity.serverUrl);
  final next = _pendingKeyStore(paths, keyStore);
  try {
    final current = await keyStore.load();
    if (current == null) throw StateError('this Worker has no credential');
    final fresh = await generateAgentKey();
    final nonce = await client.nonce(identity.workerId);
    await next.save(fresh);
    final extra = fresh.publicKeyText;
    try {
      await client.rotate(
        workerId: identity.workerId,
        nonceId: nonce.nonceId,
        signature: await signMessage(
          current,
          actionMessage(
            'rotate',
            identity.workerId,
            nonce.nonceId,
            nonce.nonce,
            extra,
          ),
        ),
        newPublicKey: extra,
        newKeySignature: await signMessage(
          fresh,
          actionMessage(
            'rotate-new',
            identity.workerId,
            nonce.nonceId,
            nonce.nonce,
            extra,
          ),
        ),
      );
    } on ServerRefusal {
      await next.delete(); // the server kept the old key
      rethrow;
    }
    await keyStore.save(fresh);
    await next.delete();
  } finally {
    if (api == null) client.close();
    await lock.release();
  }
}

/// Finishes a rotation that was interrupted after the server accepted it but
/// before the new key replaced the old one. Safe to call on every start.
Future<bool> recoverPendingRotation({
  required AgentPaths paths,
  required AgentIdentity identity,
  required KeyStore keyStore,
  required ServerApi api,
}) async {
  final next = _pendingKeyStore(paths, keyStore);
  final fresh = await next.load();
  if (fresh == null) return false;
  try {
    final nonce = await api.nonce(identity.workerId);
    await api.connectSession(
      workerId: identity.workerId,
      nonceId: nonce.nonceId,
      signature: await signMessage(
        fresh,
        actionMessage('session', identity.workerId, nonce.nonceId, nonce.nonce),
      ),
    );
  } on ServerRefusal catch (refusal) {
    if (refusal.status == 401) {
      await next.delete(); // the server never rotated
      return false;
    }
    rethrow;
  }
  await keyStore.save(fresh);
  await next.delete();
  return true;
}

/// Removes this Agent's private state: key, journal, caches and logs. It never
/// touches the user's working folders, which live outside the data directory.
/// Revoking the Worker on the server is the owner's action.
Future<void> uninstallAgent({
  required AgentPaths paths,
  required KeyStore keyStore,
}) async {
  final lock = await AgentLock.acquire(paths.lockFile);
  try {
    await keyStore.delete();
    final next = _pendingKeyStore(paths, keyStore);
    await next.delete();
  } finally {
    await lock.release();
  }
  if (await paths.root.exists()) await paths.root.delete(recursive: true);
}

KeyStore _pendingKeyStore(AgentPaths paths, KeyStore current) {
  if (current is WindowsDpapiKeyStore) {
    return WindowsDpapiKeyStore(
      paths.nextKeyFile,
      transform: current.transform,
    );
  }
  if (current is MacKeychainKeyStore) {
    return MacKeychainKeyStore(
      paths.nextKeyFile,
      executable: current.executable,
    );
  }
  if (current is LinuxSecretKeyStore) {
    return LinuxSecretKeyStore(
      paths.nextKeyFile,
      current.marker,
      executable: current.executable,
    );
  }
  return FileKeyStore(paths.nextKeyFile);
}
