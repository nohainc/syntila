import 'dart:convert';
import 'dart:io';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:syntila_workspace/local_worker_registry.dart';
import 'package:syntila_workspace/plugin_executor.dart';
import 'package:syntila_workspace/plugin_worker_runtime.dart';
import 'package:syntila_workspace/plugin_service.dart';
import 'package:syntila_workspace/plugin_store.dart';
import 'package:test/test.dart';

import 'support/plugin_fakes.dart';
import 'support/plugin_package.dart';

class FakeInspect implements PluginMcpInspectPort {
  List<Map<String, Object?>> tools = [
    for (final name in ['syntila.execute', 'syntila.probe'])
      {
        'name': name,
        'description': 'Syntila Worker tool $name',
        'inputSchema': {'type': 'object'},
      },
  ];
  Object? failure;

  @override
  Future<List<Map<String, Object?>>> listWorkerTools(
    InstalledPlugin plugin,
  ) async {
    if (failure != null) throw failure!;
    return tools;
  }
}

Future<void> expectCode(Future<Object?> future, String code) => expectLater(
      future,
      throwsA(
          isA<PluginServiceException>().having((e) => e.code, 'code', code)),
    );

void main() {
  late Directory temp;
  late FakeInspect inspect;
  late TestPluginService harness;

  String mcpPackage({String name = 'mcp'}) => writePluginPackage(
        temp,
        id: 'echo-worker',
        version: '1.0.0',
        name: name,
        edit: (m) => m['kind'] = 'mcp',
      );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mcp-plugin-service');
    inspect = FakeInspect();
    harness = TestPluginService(temp, mcpInspect: inspect);
  });
  tearDown(() {
    Process.runSync('chmod', ['-R', 'u+w', temp.path]);
    temp.deleteSync(recursive: true);
  });

  group('manifest kind', () {
    Map<String, Object?> manifest(Object? kind, {bool include = true}) {
      final dir = writePluginPackage(
        temp,
        name: 'kind-${kind ?? 'none'}',
        edit: (m) {
          if (include) m['kind'] = kind;
        },
      );
      return jsonDecode(File('$dir/plugin.json').readAsStringSync())
          as Map<String, Object?>;
    }

    test('mcp is valid, absent is NDJSON, anything else is rejected', () {
      final mcp = validatePluginManifest(manifest('mcp'));
      expect(mcp.isValid, isTrue);
      expect(mcp.manifest!.isMcp, isTrue);
      final plain = validatePluginManifest(manifest(null, include: false));
      expect(plain.isValid, isTrue);
      expect(plain.manifest!.isMcp, isFalse);
      final bad = validatePluginManifest(manifest('ndjson'));
      expect(bad.isValid, isFalse);
      expect(bad.issues.single.path, 'kind');
    });
  });

  test('plugins test pins tools and records the profile check', () async {
    await harness.service.import(mcpPackage());
    final report = await harness.service.test('echo-worker');
    expect(report['passed'], isTrue);
    expect(report['suiteVersion'], 'mcp-worker-profile-1');
    expect(report['disclaimer'], contains('not a behavioural conformance'));
    final shown = await harness.service.register('echo-worker');
    expect(shown['consentRequired'], isTrue);
    final mcp = (shown['document'] as Map)['mcp'] as Map;
    expect(mcp['profile'], 'syntila.worker/1');
    final names = [for (final t in mcp['tools'] as List) (t as Map)['name']];
    expect(names, ['syntila.execute', 'syntila.probe']);
    expect((mcp['tools'] as List).first['hash'], hasLength(64));
  });

  test('the consent hash covers the tool definitions', () async {
    await harness.service.import(mcpPackage());
    await harness.service.test('echo-worker');
    final first = await harness.service.register('echo-worker');
    inspect.tools = [
      for (final t in inspect.tools)
        {...t, 'description': 'now with hidden instructions'},
    ];
    await harness.service.test('echo-worker');
    final second = await harness.service.register('echo-worker');
    expect(second['documentHash'], isNot(first['documentHash']));
    // The old hash can no longer be accepted for the changed tools: the
    // service re-issues consent and registers nothing.
    final stale = await harness.service.register(
      'echo-worker',
      acceptHash: first['documentHash'] as String,
    );
    expect(stale['consentRequired'], isTrue);
    expect(harness.cloud.calls, isNot(contains('register:1.0.0')));
  });

  test('a server missing a required tool fails the check and cannot register',
      () async {
    inspect.tools = [inspect.tools.first];
    await harness.service.import(mcpPackage());
    final report = await harness.service.test('echo-worker');
    expect(report['passed'], isFalse);
    expect(
      [
        for (final c in report['cases'] as List)
          if ((c as Map)['status'] == 'failed') c['id'],
      ],
      ['mcp.tool.syntila.probe'],
    );
    await expectCode(
      harness.service.register('echo-worker'),
      'plugin_conformance_required',
    );
  });

  test('an Engine-side failure surfaces with its stable code', () async {
    inspect.failure = const PluginServiceException(
      'mcp_protocol_violation',
      'Worker profile marker missing',
    );
    await harness.service.import(mcpPackage());
    await expectCode(
      harness.service.test('echo-worker'),
      'mcp_protocol_violation',
    );
  });

  test('without an inspector MCP Workers are refused, NDJSON unaffected',
      () async {
    final plain = TestPluginService(
      Directory.systemTemp.createTempSync('mcp-plugin-plain'),
    );
    await plain.service.import(mcpPackage(name: 'm2'));
    await expectCode(
        plain.service.test('echo-worker'), 'plugin_mcp_unavailable');
    await plain.service.import(writePluginPackage(temp, name: 'nd'));
    final report = await plain.service.test('acme-reviewer');
    expect(report['suiteVersion'], isNot('mcp-worker-profile-1'));
  });

  group('executor', () {
    Future<InstalledPlugin> installed(String package, String id) async {
      await harness.service.import(package);
      final store = harness.service.store;
      final record = (await harness.service.registry.all())[id]!;
      final version = record.versions.values.single;
      return store.load(id, version.version, version.manifestDigest);
    }

    test('an MCP executor carries mcp protocol and the pins', () async {
      final plugin = await installed(mcpPackage(), 'echo-worker');
      final pins = ToolPins.fromTools(inspect.tools).hashes;
      final executor = workerExecutorFor(
        plugin,
        Directory(temp.path),
        toolPins: pins,
      );
      expect(executor.isMcp, isTrue);
      expect(executor.toolPins, pins);
      expect(
        () => workerExecutorFor(plugin, Directory(temp.path)),
        throwsStateError,
      );
    });

    test('an NDJSON executor is unchanged', () async {
      final plugin = await installed(
        writePluginPackage(temp, name: 'nd2'),
        'acme-reviewer',
      );
      final executor = workerExecutorFor(plugin, Directory(temp.path));
      expect(executor.isMcp, isFalse);
      expect(executor.toJson().containsKey('toolPins'), isFalse);
    });
  });

  group('inventory', () {
    const ref = 'plugin-3fa91c04b2d7';

    LocalWorker worker() => LocalWorker(
          id: 'w1',
          workspaceId: 'ws-1',
          workerTypeId: ref,
          localPermissions: const [],
          localConcurrencyLimit: 2,
          status: LocalWorkerStatus.needsAttention,
          revision: 1,
          createdAt: '2026-11-06T00:00:00Z',
          updatedAt: '2026-11-06T00:00:00Z',
        );

    Future<String> sessionResumeFor({required bool mcp}) async {
      final id = mcp ? 'echo-worker' : 'acme-reviewer';
      await harness.service.import(
        writePluginPackage(
          temp,
          id: id,
          version: '1.0.0',
          name: mcp ? 'inv-mcp' : 'inv-nd',
          edit: (m) {
            if (mcp) m['kind'] = 'mcp';
            (m['capabilities'] as Map<String, Object?>)['sessionResume'] = true;
          },
        ),
      );
      await harness.service.test(id);
      for (final op in [harness.service.register, harness.service.enable]) {
        final shown = await op(id);
        await op(id, acceptHash: shown['documentHash']! as String);
      }
      final runtime = PluginWorkerRuntime(
        store: harness.service.store,
        registry: harness.service.registry,
        engineStateDirectory: (p) => Directory('${temp.path}/engine/$p'),
        probe: ({
          required executor,
          required workerTypeId,
          required stateDirectory,
          required mode,
        }) async =>
            throw UnimplementedError(),
      );
      final item = await runtime.inventoryFor(
        worker(),
        engineVersion: '1.4.0',
        lastSeenAt: 'x',
      );
      return (item!['executor'] as Map)['sessionResume'] as String;
    }

    test('an NDJSON plugin that passed the suite reports "tested"', () async {
      expect(await sessionResumeFor(mcp: false), 'tested');
    });

    test('an MCP Worker never reports "tested": its check does not resume',
        () async {
      expect(await sessionResumeFor(mcp: true), 'declared_untested');
    });
  });
}
