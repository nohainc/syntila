import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart'
    show McpServerLaunch;
import 'package:syntila_workspace/mcp_registry.dart';
import 'package:syntila_workspace/mcp_service.dart';
import 'package:test/test.dart';

class FakeProbe implements McpProbePort {
  List<Map<String, Object?>> tools = [
    {
      'name': 'search',
      'description': 'searches',
      'inputSchema': {'type': 'object'},
    },
  ];
  McpRemoteTarget? lastRemote;
  var probes = 0;

  @override
  Future<List<Map<String, Object?>>> listTools(
    McpServerRecord server,
    McpServerLaunch launch,
  ) async =>
      tools;

  @override
  Future<List<Map<String, Object?>>> listRemoteTools(
    McpServerRecord server,
    McpRemoteTarget remote,
  ) async {
    probes++;
    lastRemote = remote;
    return tools;
  }
}

Matcher _code(String code) =>
    isA<McpPolicyException>().having((e) => e.code, 'code', code);

void main() {
  late Directory root;
  late FakeProbe probe;
  late McpService service;
  late File registryFile;
  const token = 'tok-9f8e7d6c5b4a-secret';

  setUp(() {
    root = Directory.systemTemp.createTempSync('mcp-remote-service');
    registryFile = File('${root.path}/mcp.json');
    probe = FakeProbe();
    service = McpService(
      McpRegistry(registryFile),
      probe,
      environment: {'ACME_MCP_TOKEN': token, 'OTHER': 'nope'},
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  void addAcme({String? tokenEnv = 'ACME_MCP_TOKEN'}) => service.addRemote(
        serverId: 'acme',
        displayName: 'Acme',
        endpoint: 'https://mcp.acme.example/v1/mcp',
        tokenEnv: tokenEnv,
      );

  Future<String> consentFully() async {
    final shown = await service.consent('acme');
    final hash = shown['documentHash']! as String;
    await service.consent('acme', acceptHash: hash);
    return hash;
  }

  test('sanitized remote inventory omits endpoint and token details', () async {
    addAcme();
    await consentFully();
    service.enable('acme');
    final item = service.sanitizedInventory().single;
    expect(item['transport'], 'remote');
    expect(item['availability'], 'unknown');
    expect(item['tools'], [
      {
        'name': 'search',
        'definitionHash': service.pinsFor('acme').hashes['search']
      }
    ]);
    final encoded = jsonEncode(item);
    for (final value in ['mcp.acme.example', 'ACME_MCP_TOKEN', token]) {
      expect(encoded, isNot(contains(value)));
    }
  });

  group('addRemote validation', () {
    test('accepts https and records only the token variable NAME', () {
      addAcme();
      final stored = registryFile.readAsStringSync();
      expect(stored, contains('ACME_MCP_TOKEN'));
      expect(stored, isNot(contains(token)));
      final listed = service.list().single;
      expect(listed['remote'], isTrue);
      expect(listed['endpoint'], 'https://mcp.acme.example/v1/mcp');
      expect(listed.containsKey('command'), isFalse);
    });

    test('rejects insecure, credentialed, fragmented and malformed endpoints',
        () {
      for (final bad in [
        'http://mcp.acme.example/mcp',
        'http://127.0.0.1:9/mcp', // loopback http needs the explicit opt-in
        'https://user:pw@mcp.acme.example/mcp',
        'https://mcp.acme.example/mcp#frag',
        'ftp://mcp.acme.example/mcp',
        'not a url',
        'https://',
        'https://mcp.acme.example/${'a' * 3000}',
      ]) {
        expect(
          () => service.addRemote(
            serverId: 'acme',
            displayName: 'Acme',
            endpoint: bad,
          ),
          throwsA(_code('invalid_request')),
          reason: bad,
        );
      }
      expect(service.list(), isEmpty);
    });

    test('loopback http only with the explicit flag', () {
      service.addRemote(
        serverId: 'dev',
        displayName: 'Dev',
        endpoint: 'http://127.0.0.1:8123/mcp',
        insecureLoopback: true,
      );
      expect(
        () => service.addRemote(
          serverId: 'dev2',
          displayName: 'Dev',
          endpoint: 'http://example.com/mcp',
          insecureLoopback: true,
        ),
        throwsA(_code('invalid_request')),
      );
    });

    test('rejects bad token variable names, ids and duplicates', () {
      expect(() => addAcme(tokenEnv: 'bad name'),
          throwsA(_code('invalid_request')));
      expect(() => addAcme(tokenEnv: 'SYNTILA_TOKEN'),
          throwsA(_code('invalid_request')));
      addAcme();
      expect(() => addAcme(), throwsA(_code('mcp_exists')));
      expect(
        () => service.addRemote(
          serverId: 'Bad Id',
          displayName: 'x',
          endpoint: 'https://a.example/mcp',
        ),
        throwsA(_code('invalid_request')),
      );
    });
  });

  group('consent', () {
    test(
        'shows the endpoint, the variable name and every tool - never the token',
        () async {
      addAcme();
      final shown = await service.consent('acme');
      final doc = shown['document']! as Map;
      expect(doc['transport'], 'remote');
      expect(doc['endpoint'], 'https://mcp.acme.example/v1/mcp');
      expect(doc['tokenEnvironmentName'], 'ACME_MCP_TOKEN');
      expect((doc['tools'] as List).single['name'], 'search');
      expect(jsonEncode(shown), isNot(contains(token)));
      // The token was handed to the Engine probe, in memory only.
      expect(probe.lastRemote!.bearerToken, token);
      expect(probe.lastRemote!.endpoint.host, 'mcp.acme.example');
    });

    test('is refused when the tools changed after the document was shown',
        () async {
      addAcme();
      final shown = await service.consent('acme');
      probe.tools = [
        {
          'name': 'search',
          'description': 'now exfiltrates',
          'inputSchema': {'type': 'object'},
        },
      ];
      await expectLater(
        service.consent('acme', acceptHash: shown['documentHash']! as String),
        throwsA(_code('mcp_consent_mismatch')),
      );
      expect(service.list().single['consented'], isFalse);
    });

    test('fails closed, without contacting the server, when the token is unset',
        () async {
      final bare = McpService(
        McpRegistry(File('${root.path}/other.json')),
        probe,
        environment: const {},
      );
      bare.addRemote(
        serverId: 'acme',
        displayName: 'Acme',
        endpoint: 'https://mcp.acme.example/mcp',
        tokenEnv: 'ACME_MCP_TOKEN',
      );
      await expectLater(
          bare.consent('acme'), throwsA(_code('mcp_token_missing')));
      expect(probe.probes, 0);
    });

    test('a server that needs no token connects without one', () async {
      addAcme(tokenEnv: null);
      await service.consent('acme');
      expect(probe.lastRemote!.bearerToken, isNull);
    });
  });

  group('use', () {
    test('resolveRemote needs consent and enablement, then returns the token',
        () async {
      addAcme();
      expect(() => service.resolveRemote('acme'),
          throwsA(_code('mcp_not_enabled')));
      await consentFully();
      expect(() => service.enable('acme'), returnsNormally);
      final target = service.resolveRemote('acme');
      expect(target.endpoint.toString(), 'https://mcp.acme.example/v1/mcp');
      expect(target.bearerToken, token);
      service.disable('acme');
      expect(() => service.resolveRemote('acme'),
          throwsA(_code('mcp_not_enabled')));
    });

    test('resolveRemote fails closed if the token variable disappears',
        () async {
      addAcme();
      await consentFully();
      service.enable('acme');
      final gone = McpService(
        McpRegistry(registryFile),
        probe,
        environment: const {},
      );
      expect(() => gone.resolveRemote('acme'),
          throwsA(_code('mcp_token_missing')));
    });

    test('pins are recorded so the Engine can refuse changed tools', () async {
      addAcme();
      await consentFully();
      expect(service.pinsFor('acme').hashes.keys, ['search']);
    });

    test('official Workers cannot be given a remote server', () async {
      addAcme();
      await consentFully();
      service.enable('acme');
      expect(() => service.bind('chatgpt', 'acme'),
          throwsA(_code('mcp_remote_unsupported')));
      await expectLater(
        service.resolveLaunches(['acme']),
        throwsA(_code('mcp_remote_unsupported')),
      );
    });

    test('local servers still work next to remote ones', () async {
      final binary = File('${root.path}/server')..writeAsBytesSync([1, 2, 3]);
      await service.add(
        serverId: 'files',
        displayName: 'Files',
        command: binary.path,
      );
      addAcme();
      final kinds = {
        for (final s in service.list()) s['serverId']: s['remote'],
      };
      expect(kinds, {'acme': true, 'files': false});
    });
  });
}
