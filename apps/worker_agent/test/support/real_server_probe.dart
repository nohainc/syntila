import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_agent/syntila_worker_agent.dart';

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
