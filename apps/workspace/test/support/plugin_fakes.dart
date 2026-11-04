import 'dart:io';

import 'package:syntila_workspace/plugin_registry.dart';
import 'package:syntila_workspace/plugin_service.dart';
import 'package:syntila_workspace/plugin_store.dart';

final testStart = DateTime.utc(2026, 11, 3, 11);

class FakePluginCloud implements PluginCloudPort {
  bool online = true;
  final calls = <String>[];
  var nextRef = 'plugin-3fa91c04b2d7';

  void _check() {
    if (!online) {
      throw const PluginCloudException('cloud_unavailable', 'offline');
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

class FakePluginConformance implements PluginConformancePort {
  bool passes = true;
  int runs = 0;

  @override
  Future<Map<String, Object?>> run(
    InstalledPlugin plugin, {
    required String workerTypeId,
    required bool declaresResume,
    required Map<String, Object?> declaredCapabilities,
    void Function(String progress)? onProgress,
  }) async {
    runs += 1;
    onProgress?.call('conformance:handshake.identity:passed');
    return {
      'suiteVersion': '1.0.0',
      'protocol': '1.0',
      'passed': passes,
      'cases': [
        {'id': 'handshake.identity', 'status': 'passed', 'ms': 1},
        if (!passes)
          {
            'id': 'cancel.within_grace',
            'status': 'failed',
            'ms': 5300,
            'detail': 'x'
          },
      ],
    };
  }
}

/// Does nothing; the default when a test does not model local Workers.
class NoopPluginWorkerHost implements PluginWorkerHost {
  const NoopPluginWorkerHost();
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

/// A real service over temp directories with fake Cloud and Engine ports.
class TestPluginService {
  TestPluginService(
    Directory temp, {
    DateTime? start,
    PluginWorkerHost? workerHost,
  }) : now = start ?? testStart {
    final state = Directory('${temp.path}/state/Plugins');
    service = WorkspacePluginService(
      store: PluginStore(
        root: state,
        forbiddenRoots: ['${temp.path}/state'],
        platform: 'linux-x64',
        clock: () => now,
      ),
      registry: PluginRegistry(File('${state.path}/registry.json')),
      cloud: cloud,
      conformance: conformance,
      clock: () => now,
      workerHost: workerHost ?? const NoopPluginWorkerHost(),
    );
  }

  DateTime now;
  final cloud = FakePluginCloud();
  final conformance = FakePluginConformance();
  late final WorkspacePluginService service;
}
