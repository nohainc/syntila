import 'dart:convert';
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

  test('sanitized inventory excludes local launch data and reports pins',
      () async {
    await addServer();
    await consentFully();
    service.enable('files');
    final item = service.sanitizedInventory().single;
    expect(item, {
      'serverId': 'files',
      'displayName': 'Files',
      'transport': 'local',
      'consented': true,
      'enabled': true,
      'availability': 'unknown',
      'tools': [
        {
          'name': 'read',
          'definitionHash': service.pinsFor('files').hashes['read']
        }
      ],
    });
    final encoded = item.toString();
    for (final value in [
      server.path,
      '--root',
      '/tmp',
      'API_TOKEN',
      'secret'
    ]) {
      expect(encoded, isNot(contains(value)));
    }
  });

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
    expect(await service.launchesForOwnerExecution(), isEmpty);
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
    final launch = (await service.launchesForOwnerExecution()).single;
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

  test('a modified binary is never launched and is reported', () async {
    await addServer();
    await consentFully();
    service.enable('files');
    server.writeAsBytesSync([9, 9, 9]);
    final skipped = <String>[];
    expect(
      await service.launchesForOwnerExecution(onSkipped: skipped.add),
      isEmpty,
    );
    expect(skipped.single, contains('changed since it was added'));
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

  test('one unusable server is left out; the others still launch', () async {
    await addServer();
    await consentFully();
    service.enable('files');
    final other = File('${root.path}/other')..writeAsBytesSync([1, 2, 3]);
    await service.add(
        serverId: 'other', displayName: 'Other', command: other.path);
    final shown = await service.consent('other');
    await service.consent('other',
        acceptHash: shown['documentHash']! as String);
    service.enable('other');
    other.writeAsBytesSync([4, 5, 6]);
    final skipped = <String>[];
    final launches =
        await service.launchesForOwnerExecution(onSkipped: skipped.add);
    expect([for (final l in launches) l.name], ['files']);
    expect(skipped.single, contains('"other"'));
  });

  test('disable stops resolution; remove deletes the record', () async {
    await addServer();
    await consentFully();
    service.enable('files');
    service.disable('files');
    expect(await service.launchesForOwnerExecution(), isEmpty);
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

  group('owner grants', () {
    test('every enabled, consented server is offered, for any Worker',
        () async {
      await addServer();
      await consentFully();
      expect(await service.launchesForOwnerExecution(), isEmpty);
      service.enable('files');
      expect((await service.launchesForOwnerExecution()).single.name, 'files');
    });

    test('only the authenticated Workspace owner counts as the owner', () {
      expect(assignmentRequestedByOwner({'requestedByUserId': 'u1'}, 'u1'),
          isTrue);
      expect(assignmentRequestedByOwner({'requestedByUserId': 'u2'}, 'u1'),
          isFalse);
      expect(assignmentRequestedByOwner({}, 'u1'), isFalse);
      expect(assignmentRequestedByOwner({'requestedByUserId': 'u1'}, null),
          isFalse);
      expect(
          assignmentRequestedByOwner({'requestedByUserId': ''}, ''), isFalse);
      // A value inside the request's own input is never trusted.
      expect(
          assignmentRequestedByOwner({
            'input': {'requestedByUserId': 'u1'}
          }, 'u1'),
          isFalse);
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

  group('official Profile assets', () {
    Map<String, Object?> asset(String name) =>
        jsonDecode(File('../profile_lab/assets/profiles/$name.json')
            .readAsStringSync()) as Map<String, Object?>;

    test('supported profiles carry the MCP slot in every vector', () {
      expect(profileSupportsMcpServers(asset('claude')), isTrue);
      expect(profileSupportsMcpServers(asset('chatgpt')), isTrue);
      expect(profileSupportsMcpServers(asset('copilot')), isTrue);
      expect(profileSupportsMcpServers(asset('grok')), isFalse);
      // agy has no session-only MCP setting (`--settings` rejects mcpServers),
      // so Gemini stays unsupported rather than falling back to global config.
      expect(profileSupportsMcpServers(asset('gemini')), isFalse);
    });

    test('Claude pre-approves exactly the selected servers', () {
      final args = (asset('claude')['execution'] as Map)['arguments'] as List;
      expect(
        args.whereType<Map>().where((p) => p.containsKey('forEachMcpServer')),
        [
          {
            'forEachMcpServer': ['--allowedTools', 'mcp__{{mcpServer}}'],
          },
        ],
      );
    });

    test('Copilot loads and authorizes the supplied server names', () {
      final execution = asset('copilot')['execution'] as Map;
      final args = execution['arguments'] as List;
      expect(
        args.whereType<Map>().singleWhere((part) =>
            part.containsKey('mcpConfigArguments'))['mcpConfigArguments'],
        ['--additional-mcp-config', '@{{mcpConfigPath}}'],
      );
      expect(
        args.whereType<Map>().singleWhere(
            (part) => part.containsKey('forEachMcpServer'))['forEachMcpServer'],
        ['--allow-tool', '{{mcpServer}}'],
      );
    });

    test('Codex isolates user config and takes servers from the table', () {
      List<Object?> slot(List<Object?> args) => [
            for (final part in args)
              if (part is Map && part.containsKey('mcpConfigArguments'))
                ...(part['mcpConfigArguments'] as List),
          ];
      final chatgpt = asset('chatgpt');
      final vectors = <List<Object?>>[
        (chatgpt['execution'] as Map)['arguments'] as List<Object?>,
        for (final override in chatgpt['compatibilityOverrides'] as List)
          (override as Map)['executionArguments'] as List<Object?>,
      ];
      expect(vectors, isNotEmpty);
      for (final args in vectors) {
        expect(slot(args), [
          '--ignore-user-config',
          '-c',
          'mcp_servers={{mcpServersToml}}',
        ]);
      }
    });
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

    test('official Workers with no servers get none and no error', () async {
      expect(
          await mcpLaunchesForExecution(service, withoutSlot,
              requestedByOwner: true),
          isEmpty);
      expect(
          await mcpLaunchesForExecution(service, const {},
              requestedByOwner: true),
          isEmpty);
    });

    test('a corrupt registry never breaks Workers: no servers, warning',
        () async {
      File('${root.path}/mcp.json').writeAsStringSync('{ not json');
      String? warning;
      final launches = await mcpLaunchesForExecution(
        service,
        withSlot,
        requestedByOwner: true,
        onSkipped: (m) => warning = m,
      );
      expect(launches, isEmpty);
      expect(warning, contains('could not be read'));
    });

    test('structurally wrong registry content is also treated as unreadable',
        () async {
      File('${root.path}/mcp.json')
          .writeAsStringSync('{"servers": 5, "bindings": {"x": 1}}');
      expect(
          await mcpLaunchesForExecution(service, withSlot,
              requestedByOwner: true),
          isEmpty);
    });

    test('the owner gets every enabled server; anyone else gets none',
        () async {
      await addServer();
      await consentFully();
      service.enable('files');
      expect(
          (await mcpLaunchesForExecution(service, withSlot,
                  requestedByOwner: true))
              .single
              .name,
          'files');
      expect(
          await mcpLaunchesForExecution(service, withSlot,
              requestedByOwner: false),
          isEmpty);
    });

    test('a Profile without the slot runs without servers and is reported',
        () async {
      await addServer();
      await consentFully();
      service.enable('files');
      final skipped = <String>[];
      expect(
          await mcpLaunchesForExecution(service, withoutSlot,
              requestedByOwner: true, onSkipped: skipped.add),
          isEmpty);
      expect(skipped.single, contains('cannot use MCP servers'));
    });
  });
}

Matcher _code(String code) =>
    isA<McpPolicyException>().having((e) => e.code, 'code', code);
