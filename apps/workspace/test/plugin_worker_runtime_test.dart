import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:syntila_workspace/local_worker_registry.dart';
import 'package:syntila_workspace/plugin_executor.dart';
import 'package:syntila_workspace/plugin_store.dart'
    show PluginServiceException;
import 'package:syntila_workspace/plugin_worker_runtime.dart';
import 'package:syntila_workspace/worker_readiness.dart';
import 'package:test/test.dart';

import 'support/plugin_fakes.dart';
import 'support/plugin_package.dart';

late Directory temp;
late TestPluginService harness;
late PluginWorkerRuntime runtime;
final probes = <WorkerExecutor>[];
ProbeResult Function(WorkerProbeMode mode) probeResult = (mode) => ProbeResult(
      requestId: 'p1',
      mode: mode,
      ready: true,
      checks: const [],
    );

const ref = 'plugin-3fa91c04b2d7';

LocalWorker worker({
  LocalWorkerStatus status = LocalWorkerStatus.needsAttention,
}) =>
    LocalWorker(
      id: 'w1',
      workspaceId: 'ws-1',
      workerTypeId: ref,
      localPermissions: const [],
      localConcurrencyLimit: 2,
      status: status,
      revision: 3,
      createdAt: '2026-11-03T00:00:00Z',
      updatedAt: '2026-11-03T00:00:00Z',
    );

Future<void> accept(
  Future<Map<String, Object?>> Function(String? hash) call,
) async {
  final first = await call(null);
  await call(first['documentHash'] as String);
}

/// Import, test, register and enable one version of the sample plugin.
Future<void> enabled({Map<String, Object?>? capabilities}) async {
  final service = harness.service;
  await service.import(
    writePluginPackage(
      temp,
      edit: capabilities == null
          ? null
          : (m) =>
              (m['capabilities'] as Map<String, Object?>).addAll(capabilities),
    ),
  );
  await service.test('acme-reviewer');
  await accept((h) => service.register('acme-reviewer', acceptHash: h));
  await accept((h) => service.enable('acme-reviewer', acceptHash: h));
}

void main() {
  setUp(() {
    temp = Directory.systemTemp.createTempSync('plugin-runtime-test');
    harness = TestPluginService(temp);
    probes.clear();
    probeResult = (mode) =>
        ProbeResult(requestId: 'p1', mode: mode, ready: true, checks: const []);
    runtime = PluginWorkerRuntime(
      store: harness.service.store,
      registry: harness.service.registry,
      entitlement: harness.service.entitlement,
      probe: ({
        required executor,
        required workerTypeId,
        required stateDirectory,
        required mode,
      }) async {
        probes.add(executor);
        return probeResult(mode);
      },
      engineStateDirectory: (id) => Directory('${temp.path}/engine/$id'),
    );
  });
  tearDown(() {
    Process.runSync('chmod', ['-R', 'u+w', temp.path]);
    temp.deleteSync(recursive: true);
  });

  test('a plugin type id is recognised by shape only', () {
    expect(isPluginWorkerType(ref), isTrue);
    for (final bad in [
      'chatgpt',
      'plugin-xyz',
      'plugin-3FA91C04B2D7',
      'plugin-3fa91c04b2d7a'
    ]) {
      expect(isPluginWorkerType(bad), isFalse, reason: bad);
    }
  });

  test('an unknown or disabled plugin is not ready and never probed', () async {
    var result = await runtime.assess(worker(), LocalWorkerProbeMode.passive);
    expect(result.issueCode, 'plugin_not_enabled');
    expect(result.state, WorkerReadinessState.runtimeUnavailable);
    await enabled();
    await harness.service.disable('acme-reviewer');
    result = await runtime.assess(worker(), LocalWorkerProbeMode.passive);
    expect(result.issueCode, 'plugin_not_enabled');
    expect(probes, isEmpty);
  });

  test('an enabled, entitled plugin is probed with its pinned identity',
      () async {
    await enabled();
    final result = await runtime.assess(worker(), LocalWorkerProbeMode.passive);
    expect(result.state, WorkerReadinessState.ready);
    expect(result.toolName, 'acme-reviewer');
    expect(result.toolVersion, '1.4.2');
    final executor = probes.single;
    expect(executor.pluginId, 'acme-reviewer');
    expect(executor.manifestDigest, result.profileDigest);
    expect(File(executor.executable).existsSync(), isTrue);
    expect(executor.executable, contains(executor.manifestDigest));
  });

  test('probe results map to the existing readiness states', () async {
    await enabled();
    for (final (issue, passive, live) in [
      (
        WorkerIssueCode.providerAuthenticationRequired,
        WorkerReadinessState.signInRequired,
        WorkerReadinessState.signInRequired
      ),
      (
        WorkerIssueCode.providerToolUnavailable,
        WorkerReadinessState.setupRequired,
        WorkerReadinessState.setupRequired
      ),
      (
        WorkerIssueCode.providerFailure,
        WorkerReadinessState.runtimeUnavailable,
        WorkerReadinessState.testFailed
      ),
    ]) {
      probeResult = (mode) => ProbeResult(
            requestId: 'p1',
            mode: mode,
            ready: false,
            checks: const [],
            issueCode: issue,
          );
      expect(
        (await runtime.assess(worker(), LocalWorkerProbeMode.passive)).state,
        passive,
        reason: issue,
      );
      expect(
        (await runtime.assess(worker(), LocalWorkerProbeMode.live)).state,
        live,
        reason: issue,
      );
    }
  });

  test('a lapsed entitlement stops new probes and spawns', () async {
    await enabled();
    harness.now = testStart.add(const Duration(hours: 25));
    final result = await runtime.assess(worker(), LocalWorkerProbeMode.passive);
    expect(result.issueCode, 'plugin_entitlement_lapsed');
    expect(probes, isEmpty);
    expect(await runtime.isEffectivelyEnabled(ref), isFalse);
    await expectLater(
      runtime.prepareExecution(ref),
      throwsA(isA<PluginServiceException>()
          .having((e) => e.code, 'code', 'plugin_entitlement_lapsed')),
    );
  });

  test('changed bytes on disk are refused before anything runs', () async {
    await enabled();
    final execution = await runtime.prepareExecution(ref);
    Process.runSync('chmod', ['-R', 'u+w', execution.plugin.directory.path]);
    File(execution.plugin.executablePath).writeAsStringSync('swapped');
    final result = await runtime.assess(worker(), LocalWorkerProbeMode.passive);
    expect(result.issueCode, 'plugin_digest_mismatch');
    expect(probes, isEmpty);
  });

  test('prepared executions never claim read-only enforcement', () async {
    await enabled();
    expect((await runtime.prepareExecution(ref)).readOnlyEnforced, isFalse);
  });

  group('inventory', () {
    test('an enabled plugin reports its pinned digests and honest isolation',
        () async {
      await enabled();
      final item = (await runtime.inventoryFor(
        worker(),
        engineVersion: '1.4.0',
        lastSeenAt: '2026-11-03T12:00:00Z',
      ))!;
      expect(item['workerTypeId'], ref);
      expect(item['activationState'], 'enabled');
      expect(item['profileDefinitionId'], isNull);
      expect(item['engineVersion'], '1.4.0');
      final executor = item['executor'] as Map;
      expect(executor['kind'], 'plugin');
      expect(executor['manifestDigest'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(executor['artifactDigest'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(
          executor['isolation'], {'tier': 'none', 'readOnlyEnforced': false});
      expect(executor['sessionResume'], 'none');
      expect(executor['shareable'], isFalse);
    });

    test('session resume is "tested" only after a passing run', () async {
      await enabled(capabilities: {'sessionResume': true});
      final item = (await runtime.inventoryFor(
        worker(),
        engineVersion: '1.4.0',
        lastSeenAt: 'x',
      ))!;
      expect((item['executor'] as Map)['sessionResume'], 'tested');
    });

    test('a lapsed plugin reports disabled with the reason, not removed',
        () async {
      await enabled();
      harness.now = testStart.add(const Duration(hours: 25));
      final item = (await runtime.inventoryFor(
        worker(),
        engineVersion: '1.4.0',
        lastSeenAt: 'x',
      ))!;
      expect(item['activationState'], 'disabled');
      expect(item['readinessState'], 'worker_runtime_unavailable');
      expect(item['readinessIssueCode'], 'plugin_entitlement_lapsed');
    });

    test('an unknown plugin has no inventory entry', () async {
      expect(
        await runtime.inventoryFor(worker(),
            engineVersion: '1.4.0', lastSeenAt: 'x'),
        isNull,
      );
    });
  });

  group('local Worker records', () {
    late LocalWorkerRegistry workers;
    late LocalPluginWorkerHost host;

    setUp(() {
      workers = LocalWorkerRegistry(
        dataDirectory: Directory('${temp.path}/workers')..createSync(),
        workspaceId: 'ws-1',
      );
      host = LocalPluginWorkerHost(workers: workers);
    });

    test(
        'activate creates one Worker, deactivate disables, activate re-enables',
        () async {
      await host.activate(
          pluginRef: ref, pluginId: 'acme-reviewer', displayName: 'Acme');
      var all = await workers.list();
      expect(all.single.workerTypeId, ref);
      expect(all.single.activationState, LocalWorkerActivationState.enabled);

      await host.deactivate(ref);
      all = await workers.list();
      expect(all.single.activationState, LocalWorkerActivationState.disabled);

      await host.activate(
          pluginRef: ref, pluginId: 'acme-reviewer', displayName: 'Acme');
      all = await workers.list();
      expect(all, hasLength(1));
      expect(all.single.activationState, LocalWorkerActivationState.enabled);
    });

    test('remove deletes the record', () async {
      await host.activate(
          pluginRef: ref, pluginId: 'acme-reviewer', displayName: 'Acme');
      await host.remove(ref);
      expect(await workers.list(), isEmpty);
    });
  });

  group('lapse drain cap', () {
    test('running work gets 30 minutes after a lapse, then is cancelled',
        () async {
      await enabled();
      var cancelled = 0;
      final enforcer = PluginLapseEnforcer(
        entitlement: harness.service.entitlement,
        cancelPluginWork: () async => ++cancelled,
        clock: () => harness.now,
      );
      expect(await enforcer.tick(), 0);
      expect(enforcer.lapsedAt, isNull);

      harness.now = testStart.add(const Duration(hours: 25));
      expect(await enforcer.tick(), 0); // lapse noticed, drain starts
      expect(enforcer.lapsedAt, harness.now);
      harness.now = harness.now.add(const Duration(minutes: 29));
      expect(await enforcer.tick(), 0);
      expect(cancelled, 0);
      harness.now = harness.now.add(const Duration(minutes: 1));
      expect(await enforcer.tick(), 1);
      expect(cancelled, 1);
    });

    test('renewal resets the clock so a later lapse gets a fresh drain',
        () async {
      await enabled();
      var cancelled = 0;
      final enforcer = PluginLapseEnforcer(
        entitlement: harness.service.entitlement,
        cancelPluginWork: () async => ++cancelled,
        clock: () => harness.now,
      );
      harness.now = testStart.add(const Duration(hours: 25));
      await enforcer.tick();
      harness.now = testStart.add(const Duration(hours: 2));
      await harness.service.entitlement.accept(testLease);
      await enforcer.tick();
      expect(enforcer.lapsedAt, isNull);
      expect(cancelled, 0);
    });
  });

  group('with the real registry and readiness monitor', () {
    late LocalWorkerRegistry workers;
    late WorkerReadinessMonitor monitor;
    late PluginWorkerRuntime wired;

    setUp(() {
      workers = LocalWorkerRegistry(
        dataDirectory: Directory('${temp.path}/workers')..createSync(),
        workspaceId: 'ws-1',
      );
      harness = TestPluginService(
        temp,
        workerHost: LocalPluginWorkerHost(
          workers: workers,
          afterChange: (ref) => monitor.checkNow(
            mode: LocalWorkerProbeMode.passive,
            workerTypeId: ref,
            includeDisabled: true,
          ),
        ),
      );
      wired = PluginWorkerRuntime(
        store: harness.service.store,
        registry: harness.service.registry,
        entitlement: harness.service.entitlement,
        probe: ({
          required executor,
          required workerTypeId,
          required stateDirectory,
          required mode,
        }) async {
          probes.add(executor);
          return probeResult(mode);
        },
        engineStateDirectory: (id) => Directory('${temp.path}/engine/$id'),
      );
      monitor = WorkerReadinessMonitor(
        registry: workers,
        pluginAssessor: wired.assess,
      );
    });

    test('enabling a plugin creates a ready local Worker with no catalog',
        () async {
      await enabled();
      final all = await workers.list();
      expect(all, hasLength(1));
      final plugin = all.single;
      expect(plugin.workerTypeId, ref);
      expect(plugin.readinessState, WorkerReadinessState.ready);
      expect(plugin.status, LocalWorkerStatus.ready);
      expect(plugin.toolName, 'acme-reviewer');
      expect(plugin.toolVersion, '1.4.2');
      expect(probes, isNotEmpty);
    });

    test('a lapse makes the Worker not ready without deleting it', () async {
      await enabled();
      harness.now = testStart.add(const Duration(hours: 25));
      await monitor.checkNow(
        mode: LocalWorkerProbeMode.passive,
        workerTypeId: ref,
        includeDisabled: true,
      );
      final plugin = (await workers.list()).single;
      expect(plugin.status, LocalWorkerStatus.needsAttention);
      expect(plugin.readinessIssueCode, 'plugin_entitlement_lapsed');
      // Intent is preserved: the pin is still enabled.
      final record = await harness.service.registry.find('acme-reviewer');
      expect(record!.pin!.enabled, isTrue);
    });

    test('disabling stops scheduling and the Worker stays listed', () async {
      await enabled();
      await harness.service.disable('acme-reviewer');
      final plugin = (await workers.list()).single;
      expect(plugin.activationState, LocalWorkerActivationState.disabled);
    });

    test('removing the plugin removes its Worker', () async {
      await enabled();
      await harness.service.disable('acme-reviewer');
      await harness.service.remove('acme-reviewer');
      expect(await workers.list(), isEmpty);
    });
  });
}
