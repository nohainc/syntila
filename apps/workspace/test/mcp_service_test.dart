import 'dart:io';

import 'package:crypto/crypto.dart';
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
}

Matcher _code(String code) =>
    isA<McpPolicyException>().having((e) => e.code, 'code', code);
