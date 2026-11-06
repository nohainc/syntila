import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart'
    show McpServerLaunch;
import 'package:syntila_workspace/mcp_registry.dart';
import 'package:syntila_workspace/mcp_service.dart';
import 'package:test/test.dart';

class FakeProbe implements McpProbePort {
  List<Map<String, Object?>> tools = [
    {
      'name': 'read',
      'description': 'reads',
      'inputSchema': {'type': 'object'},
    },
  ];
  @override
  Future<List<Map<String, Object?>>> listTools(
    McpServerRecord server,
    McpServerLaunch launch,
  ) async =>
      tools;

  McpRemoteTarget? lastRemote;

  @override
  Future<List<Map<String, Object?>>> listRemoteTools(
    McpServerRecord server,
    McpRemoteTarget remote,
  ) async {
    lastRemote = remote;
    return tools;
  }
}

void main() {
  late Directory root;
  late File server;
  late FakeProbe probe;
  late McpService service;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mcp-service');
    server = File('${root.path}/server')..writeAsBytesSync([0, 1, 200, 255]);
    probe = FakeProbe();
    service = McpService(
      McpRegistry(File('${root.path}/mcp.json')),
      probe,
      environment: {'API_TOKEN': 'secret', 'OTHER': 'nope'},
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<void> addServer({List<String> env = const ['API_TOKEN']}) =>
      service.add(
        serverId: 'files',
        displayName: 'Files',
        command: server.path,
        arguments: ['--root', '/tmp'],
        environmentNames: env,
      );

  Future<String> consentFully() async {
    final shown = await service.consent('files');
    final hash = shown['documentHash']! as String;
    await service.consent('files', acceptHash: hash);
    return hash;
  }

  test('the command digest is the raw SHA-256 of the file bytes', () async {
    await addServer();
    final stored = McpRegistry(File('${root.path}/mcp.json')).get('files')!;
    expect(
      stored.commandSha256,
      sha256.convert(server.readAsBytesSync()).toString(),
    );
  });

  test('a server cannot be enabled or resolved before consent', () async {
    await addServer();
    expect(() => service.enable('files'), throwsA(_code('mcp_not_consented')));
    await expectLater(
      service.resolveLaunches(['files']),
      throwsA(_code('mcp_not_enabled')),
    );
  });

  test('consent shows full definitions and pins them', () async {
    await addServer();
    final shown = await service.consent('files');
    expect(shown['consentRequired'], isTrue);
    final tools = (shown['document']! as Map)['tools'] as List;
    expect((tools.single as Map)['description'], 'reads');
    await service.consent('files',
        acceptHash: shown['documentHash']! as String);
    final pins = service.pinsFor('files');
    expect(pins.allows('read', probe.tools), isTrue);
  });

  test('consent is refused when the tools changed after the document',
      () async {
    await addServer();
    final shown = await service.consent('files');
    probe.tools = [
      {
        'name': 'read',
        'description': 'now exfiltrates',
        'inputSchema': {'type': 'object'},
      },
    ];
    await expectLater(
      service.consent('files', acceptHash: shown['documentHash']! as String),
      throwsA(_code('mcp_consent_mismatch')),
    );
    expect(service.list().single['consented'], isFalse);
  });

  test('resolves launches with only the consented environment names', () async {
    await addServer();
    await consentFully();
    service.enable('files');
    final launch = (await service.resolveLaunches(['files'])).single;
    expect(launch.name, 'files');
    expect(launch.command, server.path);
    expect(launch.arguments, ['--root', '/tmp']);
    expect(launch.environment, {'API_TOKEN': 'secret'});
  });

  test('stored records never contain environment values', () async {
    await addServer();
    await consentFully();
    expect(File('${root.path}/mcp.json').readAsStringSync(),
        isNot(contains('secret')));
  });

  test('a modified binary is refused at resolve time', () async {
    await addServer();
    await consentFully();
    service.enable('files');
    server.writeAsBytesSync([9, 9, 9]);
    await expectLater(
      service.resolveLaunches(['files']),
      throwsA(_code('mcp_binary_changed')),
    );
  });

  test('direct call admission requires enabled consent and the frozen pin',
      () async {
    await addServer();
    final hash = toolDefinitionHash(probe.tools.single);
    Future<McpToolCallAdmission> admit(String pin) => service.admitToolCall(
          serverId: 'files',
          tool: 'read',
          expectedToolHash: pin,
        );
    await expectLater(admit(hash), throwsA(_code('mcp_not_enabled')));
    await consentFully();
    service.enable('files');
    await expectLater(
        admit('0' * 64), throwsA(_code('mcp_tool_not_consented')));
    await expectLater(
      service.admitToolCall(
        serverId: 'files',
        tool: 'write',
        expectedToolHash: hash,
      ),
      throwsA(_code('mcp_tool_not_consented')),
    );
    final admitted = await admit(hash);
    expect(admitted.launch!.command, server.path);
    expect(admitted.launch!.environment, {'API_TOKEN': 'secret'});
    expect(admitted.commandSha256,
        sha256.convert(server.readAsBytesSync()).toString());
    expect(admitted.remote, isNull);
    server.writeAsBytesSync([9]);
    await expectLater(admit(hash), throwsA(_code('mcp_binary_changed')));
    service.disable('files');
    await expectLater(admit(hash), throwsA(_code('mcp_not_enabled')));
  });

  test('remote direct admission resolves secrets only locally', () async {
    service.addRemote(
      serverId: 'remote',
      displayName: 'Remote',
      endpoint: 'https://example.com/mcp',
      tokenEnv: 'API_TOKEN',
    );
    final shown = await service.consent('remote');
    await service.consent('remote',
        acceptHash: shown['documentHash']! as String);
    service.enable('remote');
    final admitted = await service.admitToolCall(
      serverId: 'remote',
      tool: 'read',
      expectedToolHash: toolDefinitionHash(probe.tools.single),
    );
    expect(admitted.remote!.bearerToken, 'secret');
    expect(admitted.launch, isNull);
    expect(File('${root.path}/mcp.json').readAsStringSync(),
        isNot(contains('secret')));
    final missingToken = McpService(
      McpRegistry(File('${root.path}/mcp.json')),
      probe,
      environment: {},
    );
    await expectLater(
      missingToken.admitToolCall(
        serverId: 'remote',
        tool: 'read',
        expectedToolHash: toolDefinitionHash(probe.tools.single),
      ),
      throwsA(_code('mcp_token_missing')),
    );
  });

  test('one unusable server refuses the whole request, not a subset', () async {
    await addServer();
    await consentFully();
    service.enable('files');
    await expectLater(
      service.resolveLaunches(['files', 'ghost']),
      throwsA(_code('mcp_not_enabled')),
    );
  });

  test('disable stops resolution; remove deletes the record', () async {
    await addServer();
    await consentFully();
    service.enable('files');
    service.disable('files');
    await expectLater(
      service.resolveLaunches(['files']),
      throwsA(_code('mcp_not_enabled')),
    );
    service.remove('files');
    expect(service.list(), isEmpty);
  });

  test('rejects bad ids, relative commands and reserved env names', () async {
    for (final bad in <Future<Object?> Function()>[
      () => service.add(
          serverId: 'Bad Id', displayName: 'x', command: server.path),
      () => service.add(serverId: 'ok', displayName: 'x', command: 'rel/x'),
      () => service.add(
          serverId: 'ok',
          displayName: 'x',
          command: server.path,
          environmentNames: ['SYNTILA_TOKEN']),
    ]) {
      await expectLater(bad(), throwsA(_code('invalid_request')));
    }
  });

  group('Worker bindings', () {
    test('nothing is bound by default, so executions get no servers', () async {
      await addServer();
      await consentFully();
      service.enable('files');
      expect(await service.launchesForWorker('chatgpt'), isEmpty);
    });

    test('a bound, consented, enabled server is resolved for that Worker only',
        () async {
      await addServer();
      await consentFully();
      service.enable('files');
      service.bind('chatgpt', 'files');
      expect((await service.launchesForWorker('chatgpt')).single.name, 'files');
      expect(await service.launchesForWorker('claude'), isEmpty);
    });

    test('a Step selection narrows the bound servers and never widens them',
        () async {
      await addServer();
      await consentFully();
      service.enable('files');
      service.bind('chatgpt', 'files');
      // An empty selection exposes nothing, even though a server is bound.
      expect(await service.launchesForWorker('chatgpt', selectedServerIds: []),
          isEmpty);
      expect(
          (await service
                  .launchesForWorker('chatgpt', selectedServerIds: ['files']))
              .single
              .name,
          'files');
      // Naming a server that is not bound refuses, never a silent subset.
      await expectLater(
        service.launchesForWorker('chatgpt', selectedServerIds: ['ghost']),
        throwsA(_code('mcp_server_not_bound')),
      );
      await expectLater(
        service.launchesForWorker('claude', selectedServerIds: ['files']),
        throwsA(_code('mcp_server_not_bound')),
      );
    });

    test('the Step list is read strictly from the assignment input', () {
      expect(assignmentMcpServerIds({}), isNull);
      expect(assignmentMcpServerIds({'input': {}}), isNull);
      expect(
          assignmentMcpServerIds({
            'input': {'mcpServerIds': []}
          }),
          isEmpty);
      expect(
          assignmentMcpServerIds({
            'input': {
              'mcpServerIds': ['files', 'db-1']
            }
          }),
          ['files', 'db-1']);
      for (final bad in <Object>[
        'files',
        ['Files'],
        [1],
        List.generate(9, (i) => 's$i'),
      ]) {
        expect(
            () => assignmentMcpServerIds({
                  'input': {'mcpServerIds': bad}
                }),
            throwsA(_code('invalid_request')));
      }
    });

    test('binding does not bypass consent or enablement', () async {
      await addServer();
      service.bind('chatgpt', 'files');
      await expectLater(
        service.launchesForWorker('chatgpt'),
        throwsA(_code('mcp_not_enabled')),
      );
    });

    test('unbind and remove drop bindings', () async {
      await addServer();
      service.bind('chatgpt', 'files');
      service.bind('claude', 'files');
      service.unbind('chatgpt', 'files');
      expect(service.bindings(), {
        'claude': ['files'],
      });
      service.remove('files');
      expect(service.bindings(), isEmpty);
    });

    test('binding an unknown server or bad Worker type is rejected', () async {
      expect(() => service.bind('chatgpt', 'ghost'),
          throwsA(_code('mcp_not_found')));
      await addServer();
      expect(() => service.bind('Bad Type', 'files'),
          throwsA(_code('invalid_request')));
    });
  });

  test('Profile support requires the slot in every selectable vector', () {
    Map<String, Object?> profile(List<Object?> base,
            [List<Object?>? override]) =>
        {
          'execution': {'arguments': base},
          if (override != null)
            'compatibilityOverrides': [
              {'executionArguments': override},
            ],
        };
    const slot = {
      'mcpConfigArguments': ['--mcp-config', '{{mcpConfigPath}}'],
    };
    expect(profileSupportsMcpServers(profile(['a', slot])), isTrue);
    expect(profileSupportsMcpServers(profile(['a'])), isFalse);
    expect(profileSupportsMcpServers(profile(['a', slot], ['b'])), isFalse);
    expect(
        profileSupportsMcpServers(profile(['a', slot], ['b', slot])), isTrue);
    expect(profileSupportsMcpServers({}), isFalse);
  });

  group('mcpLaunchesForExecution', () {
    const slot = {
      'mcpConfigArguments': ['--mcp-config', '{{mcpConfigPath}}'],
    };
    final withSlot = <String, Object?>{
      'execution': {
        'arguments': ['a', slot],
      },
    };
    final withoutSlot = <String, Object?>{
      'execution': {
        'arguments': ['a'],
      },
    };

    test('official Workers with nothing bound get no servers and no error',
        () async {
      expect(await mcpLaunchesForExecution(service, 'chatgpt', withoutSlot),
          isEmpty);
      expect(
          await mcpLaunchesForExecution(service, 'chatgpt', const {}), isEmpty);
    });

    test('a corrupt registry never breaks Workers: no servers, warning',
        () async {
      File('${root.path}/mcp.json').writeAsStringSync('{ not json');
      String? warning;
      final launches = await mcpLaunchesForExecution(
        service,
        'chatgpt',
        withSlot,
        onRegistryUnreadable: (m) => warning = m,
      );
      expect(launches, isEmpty);
      expect(warning, contains('could not be read'));
    });

    test('structurally wrong registry content is also treated as unreadable',
        () async {
      File('${root.path}/mcp.json')
          .writeAsStringSync('{"servers": 5, "bindings": {"x": 1}}');
      expect(await mcpLaunchesForExecution(service, 'x', withSlot), isEmpty);
    });

    test('bound servers on a Profile without the slot fail the execution',
        () async {
      await addServer();
      await consentFully();
      service.enable('files');
      service.bind('chatgpt', 'files');
      await expectLater(
        mcpLaunchesForExecution(service, 'chatgpt', withoutSlot),
        throwsA(_code('mcp_unsupported')),
      );
      await expectLater(
        mcpLaunchesForExecution(service, 'chatgpt', const {}),
        throwsA(_code('mcp_unsupported')),
      );
      expect(
        (await mcpLaunchesForExecution(service, 'chatgpt', withSlot))
            .single
            .name,
        'files',
      );
    });

    test('a bound but unusable server still fails closed', () async {
      await addServer();
      service.bind('chatgpt', 'files');
      await expectLater(
        mcpLaunchesForExecution(service, 'chatgpt', withSlot),
        throwsA(_code('mcp_not_enabled')),
      );
    });
  });
}

Matcher _code(String code) =>
    isA<McpPolicyException>().having((e) => e.code, 'code', code);
