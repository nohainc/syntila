import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_connect/syntila_connect.dart';

class _DeferredEngineRun implements EngineRun {
  _DeferredEngineRun(this._completer);
  final Completer<EngineOutcome> _completer;

  @override
  Future<EngineOutcome> get outcome => _completer.future;

  @override
  Future<void> cancel() async {
    if (!_completer.isCompleted) {
      _completer.complete(
        const EngineOutcome(TerminalKind.cancelled, {'reason': 'cancelled'}),
      );
    }
  }
}

class _DeferredFakeEngineLauncher implements EngineLauncher {
  final List<Completer<EngineOutcome>> _pending = [];

  @override
  Future<EngineRun> launch(EngineRequest request) async {
    final completer = Completer<EngineOutcome>();
    _pending.add(completer);
    stdout.writeln('ENGINE_STARTED ${request.assignmentId}');
    return _DeferredEngineRun(completer);
  }

  void completeAll() {
    for (final c in _pending) {
      if (!c.isCompleted) {
        c.complete(
          const EngineOutcome(TerminalKind.completed, {
            'summary': 'recovered-after-restart',
            'output': 'recovered-after-restart',
          }),
        );
      }
    }
    _pending.clear();
  }

  @override
  Future<int> recoverOrphans() async => 0;

  @override
  Future<String?> probe() async => null;
}

/// Integration probe: pair and complete hello/sync against a real backend.
Future<void> main() async {
  final lines = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .asBroadcastStream();
  final firstLine = await lines.first;
  final input = jsonDecode(firstLine) as Map<String, dynamic>;
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
    final fakeEngine = input['runFakeEngine'] == true
        ? _DeferredFakeEngineLauncher()
        : null;
    runtime = await AgentRuntime.open(
      paths: paths,
      identity: identity,
      keyStore: keys,
      engine: fakeEngine ?? UnconfiguredEngineLauncher(),
      baseDelay: const Duration(milliseconds: 50),
      stepTimeout: const Duration(seconds: 4),
    );
    var readyCount = 0;
    final subscription = runtime.connection.phases.listen((phase) {
      if (phase == ConnectionPhase.ready && ++readyCount > 1) {
        stdout.writeln('AGENT_RECONNECTED');
      }
    });
    await runtime.start();
    await runtime.connection.whenReady(timeout: const Duration(seconds: 12));
    stdout.writeln('AGENT_READY');
    if (input['keepAlive'] == true) {
      await for (final line in lines) {
        if (line.trim() == 'COMPLETE') {
          fakeEngine?.completeAll();
        }
      }
    }
    await subscription.cancel();
  } finally {
    await runtime?.stop();
    await root.delete(recursive: true);
  }
}
