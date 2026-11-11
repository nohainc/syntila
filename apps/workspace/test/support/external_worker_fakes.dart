import 'dart:io';

import 'package:syntila_workspace/external_worker_registry.dart';
import 'package:syntila_workspace/external_worker_service.dart';
import 'package:syntila_workspace/external_worker_store.dart';

final testStart = DateTime.utc(2026, 11, 3, 11);

class FakeExternalWorkerCloud implements ExternalWorkerCloudPort {
  bool online = true;
  final calls = <String>[];
  var nextRef = 'plugin-3fa91c04b2d7';

  void _check() {
    if (!online) {
      throw const ExternalWorkerCloudException('cloud_unavailable', 'offline');
    }
  }

  @override
  Future<String> registerVersion({
    required Map<String, Object?> manifest,
    required String manifestDigest,
    required Map<String, Object?> origin,
    required Map<String, Object?>? signer,
  }) async {
    calls.add('register:${manifest['version']}');
    _check(); // Registration is free on every plan.
    return nextRef;
  }

  @override
  Future<void> setEnablement({
    required String pluginRef,
    required String version,
    required String manifestDigest,
    required String consentHash,
    required bool enabled,
    required bool shareable,
  }) async {
    calls.add('${enabled ? 'enable' : 'disable'}:$version');
    _check(); // Enablement is free; Cloud gates plugin use.
  }

  @override
  Future<void> removeFromLibrary(String pluginRef) async {
    calls.add('remove:$pluginRef');
    _check();
  }
}

/// Does nothing; the default when a test does not model local Workers.
class NoopExternalWorkerHost implements ExternalWorkerHost {
  const NoopExternalWorkerHost();
  @override
  Future<void> activate({
    required String pluginRef,
    required String pluginId,
    required String displayName,
  }) async {}
  @override
  Future<void> deactivate(String pluginRef) async {}
  @override
  Future<void> remove(String pluginRef) async {}
}

/// A fake MCP tool inspector for plugin packages.
class FakeExternalWorkerMcpInspect implements ExternalWorkerMcpInspectPort {
  FakeExternalWorkerMcpInspect([this.tools]);

  List<Map<String, Object?>>? tools;

  @override
  Future<List<Map<String, Object?>>> listWorkerTools(
    InstalledExternalWorker plugin,
  ) async {
    return tools ??
        [
          for (final name in ['syntila.execute', 'syntila.probe'])
            {
              'name': name,
              'description': 'Syntila Worker tool $name',
              'inputSchema': {'type': 'object'},
            },
        ];
  }
}

const Object _unspecifiedInspect = Object();

/// A real service over temp directories with fake Cloud and Engine ports.
class TestExternalWorkerService {
  TestExternalWorkerService(
    Directory temp, {
    DateTime? start,
    ExternalWorkerHost? workerHost,
    Object? mcpInspect = _unspecifiedInspect,
  }) : now = start ?? testStart {
    final state = Directory('${temp.path}/state/Plugins');
    final inspectPort = identical(mcpInspect, _unspecifiedInspect)
        ? this.mcpInspect
        : mcpInspect as ExternalWorkerMcpInspectPort?;
    service = ExternalWorkerService(
      store: ExternalWorkerStore(
        root: state,
        forbiddenRoots: ['${temp.path}/state'],
        platform: 'linux-x64',
        clock: () => now,
      ),
      registry: ExternalWorkerRegistry(File('${state.path}/registry.json')),
      cloud: cloud,
      clock: () => now,
      workerHost: workerHost ?? const NoopExternalWorkerHost(),
      mcpInspect: inspectPort,
    );
  }

  DateTime now;
  final cloud = FakeExternalWorkerCloud();
  final mcpInspect = FakeExternalWorkerMcpInspect();
  late final ExternalWorkerService service;
}
