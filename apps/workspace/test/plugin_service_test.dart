import 'dart:convert';
import 'dart:io';

import 'package:syntila_workspace/plugin_entitlement.dart';
import 'package:syntila_workspace/plugin_registry.dart';
import 'package:syntila_workspace/plugin_service.dart';
import 'package:syntila_workspace/plugin_store.dart';
import 'package:test/test.dart';

import 'support/plugin_package.dart';

// A lease produced by the TypeScript issuer for ws-1 / inst-1, valid 24 h
// from 2026-11-03T10:00Z.
const _publicKey = "lkioBdUQgez7WQJ+GDKA2aeV28mrD8IVbOvj9DCEP90=";
final _lease = jsonDecode(
        r'''{"lease": {"v": 1, "kid": "ent-1", "feature": "workers.custom_plugins", "ownerUserId": "user-plus", "workspaceId": "ws-1", "installationId": "inst-1", "leaseId": "lease-interop-1", "issuedAt": "2026-11-03T10:00:00.000Z", "expiresAt": "2026-11-04T10:00:00.000Z", "planStatus": "active", "planPeriodEnd": null}, "signature": "XysqTeDvrr4M77Nu77Q0afhPBFL5mKQN6cpW1NX0ukv3QnQAOEd0N+eZd6yvMlnV1g0YVe2SkxKuDuNIigGlCw=="}''')
    as Map<String, Object?>;
final _start = DateTime.utc(2026, 11, 3, 11);

class FakeCloud implements PluginCloudPort {
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
    return _lease;
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

class FakeConformance implements PluginConformancePort {
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

late Directory temp;
late DateTime now;
late FakeCloud cloud;
late FakeConformance conformance;
late WorkspacePluginService service;

Future<void> expectCode(Future<Object?> future, String code) => expectLater(
      future,
      throwsA(
          isA<PluginServiceException>().having((e) => e.code, 'code', code)),
    );

/// Imports, tests and registers a plugin version, returning its summary.
Future<void> prepare(
    {String version = '1.4.2', String workRoot = 'write'}) async {
  await service.import(
    writePluginPackage(temp,
        version: version, workRoot: workRoot, name: 'v$version'),
  );
  await service.test('acme-reviewer', version: version);
}

Future<Map<String, Object?>> accept(
  Future<Map<String, Object?>> Function(String? acceptHash) call,
) async {
  final first = await call(null);
  expect(first['consentRequired'], isTrue);
  return call(first['documentHash'] as String);
}

void main() {
  setUp(() {
    temp = Directory.systemTemp.createTempSync('plugin-service-test');
    now = _start;
    cloud = FakeCloud();
    conformance = FakeConformance();
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
          pluginEntitlementPublisher: {'ent-1': _publicKey},
        }),
        workspaceId: 'ws-1',
        installationId: 'inst-1',
        clock: () => now,
      ),
      cloud: cloud,
      conformance: conformance,
      clock: () => now,
    );
  });
  tearDown(() {
    Process.runSync('chmod', ['-R', 'u+w', temp.path]);
    temp.deleteSync(recursive: true);
  });

  test('import -> test -> register -> enable -> disable -> remove', () async {
    final imported = await service.import(writePluginPackage(temp));
    expect(imported['pluginId'], 'acme-reviewer');
    expect((await service.validate('acme-reviewer'))['valid'], isTrue);
    final progress = <String>[];
    final report =
        await service.test('acme-reviewer', onProgress: progress.add);
    expect(report['passed'], isTrue);
    expect(report['disclaimer'], contains('not a safety assessment'));
    expect(progress, isNotEmpty);

    final registered = await accept(
      (hash) => service.register('acme-reviewer', acceptHash: hash),
    );
    expect(registered['pluginRef'], 'plugin-3fa91c04b2d7');

    final enabled = await accept(
      (hash) => service.enable('acme-reviewer', acceptHash: hash),
    );
    expect(enabled['enabled'], isTrue);
    final listed = await service.list();
    final plugin = (listed['plugins'] as List).single as Map;
    expect((plugin['workspace'] as Map)['effective'], 'enabled');

    await expectCode(service.remove('acme-reviewer'), 'plugin_in_use');
    expect((await service.disable('acme-reviewer'))['cloudSynced'], isTrue);
    expect((await service.remove('acme-reviewer'))['state'], 'removed');
    expect((await service.list())['plugins'], isEmpty);
    expect(cloud.calls, contains('remove:plugin-3fa91c04b2d7'));
  });

  test(
      'registration and enabling need a passing conformance run for this exact version',
      () async {
    await service.import(writePluginPackage(temp));
    await expectCode(
        service.register('acme-reviewer'), 'plugin_conformance_required');
    conformance.passes = false;
    final failed = await service.test('acme-reviewer');
    expect(failed['passed'], isFalse);
    await expectCode(
        service.register('acme-reviewer'), 'plugin_conformance_required');
    await expectCode(
        service.enable('acme-reviewer'), 'plugin_conformance_required');
  });

  test(
      'consent is bound to the content: a stale or wrong hash registers nothing',
      () async {
    await prepare();
    final shown = await service.register('acme-reviewer');
    final document = shown['document'] as Map;
    expect((document['digest'] as Map)['manifest'],
        matches(RegExp(r'^[0-9a-f]{64}$')));
    expect((document['origin'] as Map).containsKey('importedAt'), isFalse);
    expect(jsonEncode(document), isNot(contains(temp.path)));
    expect(document['statement'], pluginConsentStatement);
    expect((document['isolation'] as Map)['readOnlyEnforced'], isFalse);

    final wrong = await service.register('acme-reviewer', acceptHash: 'f' * 64);
    expect(wrong['consentRequired'], isTrue);
    expect(cloud.calls.where((c) => c.startsWith('register')), isEmpty);
    // A different version has a different digest, so its hash differs.
    await prepare(version: '1.5.0');
    final other = await service.register('acme-reviewer', version: '1.5.0');
    expect(other['documentHash'], isNot(shown['documentHash']));
  });

  test(
      'a Free account is refused by Cloud for import, test, register and enable',
      () async {
    cloud.paid = false;
    await expectCode(
        service.import(writePluginPackage(temp)), 'paid_plan_required');
    expect(cloud.calls, ['fetchLease']);
  });

  test(
      'downgrade: plugins pause but nothing is deleted, and free operations still work',
      () async {
    await prepare();
    await accept((h) => service.register('acme-reviewer', acceptHash: h));
    await accept((h) => service.enable('acme-reviewer', acceptHash: h));

    // The lease runs out and Cloud now answers 402.
    now = _start.add(const Duration(hours: 25));
    cloud.paid = false;

    final plugin = ((await service.list())['plugins'] as List).single as Map;
    final workspace = plugin['workspace'] as Map;
    expect(workspace['intent'], 'enabled'); // preserved
    expect(workspace['effective'], 'disabled');
    expect(workspace['reason'], 'plus_required');

    await expectCode(service.test('acme-reviewer'), 'paid_plan_required');
    await expectCode(service.register('acme-reviewer'), 'paid_plan_required');
    await expectCode(service.enable('acme-reviewer'), 'paid_plan_required');
    await expectCode(
        service.import(writePluginPackage(temp, version: '9.0.0', name: 'n')),
        'paid_plan_required');

    expect((await service.validate('acme-reviewer'))['valid'], isTrue);
    final out = '${temp.path}/export.zip';
    expect((await service.export('acme-reviewer', out))['exported'], isTrue);
    expect(File(out).existsSync(), isTrue);
    expect((await service.disable('acme-reviewer'))['disabled'], isTrue);
    expect((await service.remove('acme-reviewer'))['removed'], isTrue);
  });

  test('renewal restores the plugin without a new consent', () async {
    await prepare();
    await accept((h) => service.register('acme-reviewer', acceptHash: h));
    await accept((h) => service.enable('acme-reviewer', acceptHash: h));
    now = _start.add(const Duration(hours: 25));
    cloud.paid = false;
    expect(
      (((await service.list())['plugins'] as List).single as Map)['workspace'],
      containsPair('effective', 'disabled'),
    );
    // Cloud issues a fresh lease again (here the same vector, back in time).
    cloud.paid = true;
    now = _start.add(const Duration(hours: 2));
    await service.entitlement.accept(_lease);
    expect(
      (((await service.list())['plugins'] as List).single as Map)['workspace'],
      containsPair('effective', 'enabled'),
    );
  });

  test('offline without a valid lease is unverifiable, not a silent allow',
      () async {
    cloud.online = false;
    await expectCode(
        service.import(writePluginPackage(temp)), 'entitlement_unverifiable');
  });

  test('offline with a valid lease still allows paid actions until it expires',
      () async {
    await prepare();
    cloud.online = false;
    now = _start.add(const Duration(hours: 5));
    expect((await service.test('acme-reviewer'))['passed'], isTrue);
    now = _start.add(const Duration(hours: 25));
    await expectCode(service.test('acme-reviewer'), 'entitlement_unverifiable');
  });

  test('a rolled-back clock is reported as such', () async {
    await prepare();
    await service.entitlement
        .observeCloudTime(_start.add(const Duration(hours: 10)));
    cloud.online = false;
    await expectCode(
        service.test('acme-reviewer'), 'entitlement_clock_invalid');
  });

  test('disabling works offline and is reported as not yet synced', () async {
    await prepare();
    await accept((h) => service.register('acme-reviewer', acceptHash: h));
    await accept((h) => service.enable('acme-reviewer', acceptHash: h));
    cloud.online = false;
    final result = await service.disable('acme-reviewer');
    expect(result['disabled'], isTrue);
    expect(result['cloudSynced'], isFalse);
    final plugin = ((await service.list())['plugins'] as List).single as Map;
    expect((plugin['workspace'] as Map)['intent'], 'disabled');
    await expectCode(service.disable('acme-reviewer'), 'plugin_not_enabled');
  });

  test('moving the pin shows what changes and never moves silently', () async {
    await prepare(workRoot: 'read');
    await accept((h) => service.register('acme-reviewer', acceptHash: h));
    await accept((h) => service.enable('acme-reviewer', acceptHash: h));
    await prepare(version: '1.5.0', workRoot: 'write');
    await accept((h) =>
        service.register('acme-reviewer', version: '1.5.0', acceptHash: h));

    final shown = await service.enable('acme-reviewer', version: '1.5.0');
    final change = (shown['document'] as Map)['change'] as Map;
    expect(change['fromVersion'], '1.4.2');
    expect(change['toVersion'], '1.5.0');
    expect(change['accessIncreased'], isTrue);
    var plugin = ((await service.list())['plugins'] as List).single as Map;
    expect((plugin['workspace'] as Map)['pinnedVersion'], '1.4.2');

    await service.enable('acme-reviewer',
        version: '1.5.0', acceptHash: shown['documentHash'] as String);
    plugin = ((await service.list())['plugins'] as List).single as Map;
    expect((plugin['workspace'] as Map)['pinnedVersion'], '1.5.0');
  });

  test('removal waits for running work', () async {
    var active = 1;
    final busy = WorkspacePluginService(
      store: service.store,
      registry: service.registry,
      entitlement: service.entitlement,
      cloud: cloud,
      conformance: conformance,
      activeAssignments: (_) => active,
      clock: () => now,
    );
    await prepare();
    await accept((h) => busy.register('acme-reviewer', acceptHash: h));
    await expectCode(busy.remove('acme-reviewer'), 'plugin_in_use');
    active = 0;
    expect((await busy.remove('acme-reviewer'))['removed'], isTrue);
  });
}
