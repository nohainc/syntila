import 'dart:async';
import 'dart:io';

import 'package:syntila_worker_agent/syntila_worker_agent.dart';

import 'fake_cloud.dart';
import 'fake_engine.dart';

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(reason ?? 'condition not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// One Agent installation on a temporary "host".
class AgentHost {
  AgentHost(this.cloud, this.worker, this.paths, this.identity);

  final FakeCloud cloud;
  final FakeWorker worker;
  final AgentPaths paths;
  final AgentIdentity identity;
  AgentRuntime? runtime;

  KeyStore get keys => FileKeyStore(paths.keyFile);

  /// Pairs [worker] into a new data directory under [root].
  static Future<AgentHost> install(
    FakeCloud cloud,
    FakeWorker worker,
    Directory root,
  ) async {
    final paths = AgentPaths(Directory('${root.path}/${worker.id}'));
    final identity = await installAgent(
      code: cloud.createPairing(worker.id),
      paths: paths,
      keyStore: FileKeyStore(paths.keyFile),
    );
    return AgentHost(cloud, worker, paths, identity);
  }

  Future<AgentRuntime> open(
    EngineLauncher engine, {
    FaultPoint? onPoint,
    ProfileCache? profiles,
    Duration permitTimeout = const Duration(seconds: 5),
  }) async {
    final next = await AgentRuntime.open(
      paths: paths,
      identity: identity,
      keyStore: keys,
      engine: engine,
      onPoint: onPoint,
      profiles: profiles,
      baseDelay: const Duration(milliseconds: 20),
      heartbeatInterval: const Duration(milliseconds: 200),
      stepTimeout: const Duration(seconds: 5),
      permitTimeout: permitTimeout,
      permitResend: const Duration(milliseconds: 100),
    );
    runtime = next;
    return next;
  }

  /// Opens and starts, then waits until the connection is ready.
  Future<AgentRuntime> startReady(
    EngineLauncher engine, {
    FaultPoint? onPoint,
  }) async {
    final agent = await open(engine, onPoint: onPoint);
    await agent.start();
    await agent.connection.whenReady();
    return agent;
  }

  Future<void> dispose() async {
    final agent = runtime;
    runtime = null;
    if (agent != null && !agent.isDead) await agent.stop();
  }
}

Future<Directory> tempRoot(String name) =>
    Directory.systemTemp.createTemp('syntila-agent-$name-');

FakeEngine newEngine() => FakeEngine();
