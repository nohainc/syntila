import 'dart:convert';
import 'dart:io';

import 'package:syntila_connect/syntila_connect.dart';

/// Integration probe: pair and complete hello/sync against a real backend.
Future<void> main() async {
  final input = jsonDecode(stdin.readLineSync()!) as Map<String, dynamic>;
  final root = await Directory.systemTemp.createTemp('syntila-agent-live-');
  AgentRuntime? runtime;
  try {
    final paths = AgentPaths(root);
    final keys = FileKeyStore(paths.keyFile);
    final identity = await installAgent(
      code: PairingCode(
        serverUrl: input['serverUrl'] as String,
        workerId: input['workerId'] as String,
        challengeId: input['challengeId'] as String,
        secret: input['secret'] as String,
      ),
      paths: paths,
      keyStore: keys,
    );
    if (input['profileDigest'] is String) {
      final api = ServerApi(identity.serverUrl);
      try {
        final key = (await keys.load())!;
        final nonce = await api.nonce(identity.workerId);
        final signature = await signMessage(
          key,
          actionMessage(
            'session',
            identity.workerId,
            nonce.nonceId,
            nonce.nonce,
          ),
        );
        final session = await api.connectSession(
          workerId: identity.workerId,
          nonceId: nonce.nonceId,
          signature: signature,
        );
        final digest = input['profileDigest'] as String;
        final downloaded = await api.downloadProfile(
          workerId: identity.workerId,
          session: session,
          revision: 1,
          digest: digest,
        );
        final cache = ProfileCache(
          paths.profilesDir,
          SignedProfileVerifier({
            'test-key': input['profilePublicKey'] as String,
          }),
        );
        await cache.putSnapshot(
          downloaded.snapshot,
          workerTypeId: 'chatgpt',
          revision: 1,
          digest: digest,
          signature: downloaded.proof,
        );
        if (!await cache.has(digest)) {
          throw StateError('Profile was not cached');
        }
        stdout.writeln('PROFILE_VERIFIED');
      } finally {
        api.close();
      }
    }
    runtime = await AgentRuntime.open(
      paths: paths,
      identity: identity,
      keyStore: keys,
      engine: UnconfiguredEngineLauncher(),
      baseDelay: const Duration(milliseconds: 50),
      stepTimeout: const Duration(seconds: 4),
    );
    await runtime.start();
    await runtime.connection.whenReady(timeout: const Duration(seconds: 12));
    stdout.writeln('AGENT_READY');
  } finally {
    await runtime?.stop();
    await root.delete(recursive: true);
  }
}
