import 'dart:convert';
import 'dart:io';

import 'package:syntila_workspace/plugin_entitlement.dart';
import 'package:syntila_workspace/plugin_registry.dart';
import 'package:syntila_workspace/plugin_service.dart';
import 'package:syntila_workspace/plugin_store.dart';

// A lease produced by the TypeScript issuer for ws-1 / inst-1, valid 24 h
// from 2026-11-03T10:00Z.
const testLeasePublicKey = "lkioBdUQgez7WQJ+GDKA2aeV28mrD8IVbOvj9DCEP90=";
final testLease = jsonDecode(
        r'''{"lease": {"v": 1, "kid": "ent-1", "feature": "workers.custom_plugins", "ownerUserId": "user-plus", "workspaceId": "ws-1", "installationId": "inst-1", "leaseId": "lease-interop-1", "issuedAt": "2026-11-03T10:00:00.000Z", "expiresAt": "2026-11-04T10:00:00.000Z", "planStatus": "active", "planPeriodEnd": null}, "signature": "XysqTeDvrr4M77Nu77Q0afhPBFL5mKQN6cpW1NX0ukv3QnQAOEd0N+eZd6yvMlnV1g0YVe2SkxKuDuNIigGlCw=="}''')
    as Map<String, Object?>;
final testStart = DateTime.utc(2026, 11, 3, 11);

class FakePluginCloud implements PluginCloudPort {
  bool paid = true;
  bool online = true;
  final calls = <String>[];
  var nextRef = 'plugin-3fa91c04b2d7';

  void _check() {
    if (!online) {
      throw const PluginCloudException('cloud_unavailable', 'offline');
    }
  }

  void _requirePaid() {
    _check();
    if (!paid) {
      throw const PluginCloudException('paid_plan_required', 'Plus required');
    }
  }

  @override
  Future<Map<String, Object?>> fetchLease() async {
    calls.add('fetchLease');
    _requirePaid();
    return testLease;
  }

  @override
  Future<String> registerVersion({
    required Map<String, Object?> manifest,
    required String manifestDigest,
    required Map<String, Object?> origin,
    required Map<String, Object?>? signer,
  }) async {
    calls.add('register:${manifest['version']}');
    _requirePaid();
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
    if (enabled) {
      _requirePaid();
    } else {
      _check();
    }
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
      entitlement: PluginEntitlementStore(
        file: File('${state.path}/entitlement.json'),
        verifier: PluginLeaseVerifier({
          pluginEntitlementPublisher: {'ent-1': testLeasePublicKey},
        }),
        workspaceId: 'ws-1',
        installationId: 'inst-1',
        clock: () => now,
      ),
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
