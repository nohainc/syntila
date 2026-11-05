import 'dart:convert';
import 'dart:io';

import 'package:syntila_workspace/plugin_service.dart';
import 'package:syntila_workspace/plugin_store.dart';
import 'package:test/test.dart';

import 'support/plugin_fakes.dart';
import 'support/plugin_package.dart';

late Directory temp;
late FakePluginCloud cloud;
late FakePluginConformance conformance;
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
  late TestPluginService harness;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('plugin-service-test');
    harness = TestPluginService(temp);
    cloud = harness.cloud;
    conformance = harness.conformance;
    service = harness.service;
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

  test('a Free account can import, test, register and enable; Cloud gates use',
      () async {
    await prepare();
    await accept((h) => service.register('acme-reviewer', acceptHash: h));
    await accept((h) => service.enable('acme-reviewer', acceptHash: h));
    expect(cloud.calls, isNot(contains('fetchLease')));
    final workspace = (((await service.list())['plugins'] as List).single
        as Map)['workspace'] as Map;
    expect(workspace['effective'], 'enabled');
    expect(workspace.containsKey('reason'), isFalse);
  });

  test('a lapsed plan changes nothing locally; free operations still work',
      () async {
    await prepare();
    await accept((h) => service.register('acme-reviewer', acceptHash: h));
    await accept((h) => service.enable('acme-reviewer', acceptHash: h));
    harness.now = testStart.add(const Duration(hours: 25));

    expect((await service.test('acme-reviewer'))['passed'], isTrue);
    expect((await service.validate('acme-reviewer'))['valid'], isTrue);
    final out = '${temp.path}/export.zip';
    expect((await service.export('acme-reviewer', out))['exported'], isTrue);
    expect((await service.disable('acme-reviewer'))['disabled'], isTrue);
    expect((await service.remove('acme-reviewer'))['removed'], isTrue);
  });

  test('local import and test need no Cloud connection', () async {
    cloud.online = false;
    await prepare();
    expect(cloud.calls, isEmpty);
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
    cloud.online = true;
    expect((await service.disable('acme-reviewer'))['cloudSynced'], isTrue);
    expect(cloud.calls.where((call) => call == 'disable:1.4.2').length, 2);
  });

  test('remove reconciles a previously offline disable before removal',
      () async {
    await prepare();
    await accept((h) => service.register('acme-reviewer', acceptHash: h));
    await accept((h) => service.enable('acme-reviewer', acceptHash: h));
    cloud.online = false;
    expect((await service.disable('acme-reviewer'))['cloudSynced'], false);
    await expectCode(service.remove('acme-reviewer'), 'cloud_unavailable');
    cloud.online = true;
    expect((await service.remove('acme-reviewer'))['removed'], true);
    expect(cloud.calls.sublist(cloud.calls.length - 2),
        ['disable:1.4.2', 'remove:plugin-3fa91c04b2d7']);
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
      cloud: cloud,
      conformance: conformance,
      activeAssignments: (_) async => active,
      clock: () => harness.now,
    );
    await prepare();
    await accept((h) => busy.register('acme-reviewer', acceptHash: h));
    await expectCode(busy.remove('acme-reviewer'), 'plugin_in_use');
    active = 0;
    expect((await busy.remove('acme-reviewer'))['removed'], isTrue);
  });
}
