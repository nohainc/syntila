import 'dart:convert';
import 'dart:io';

import 'package:syntila_workspace/mcp_inventory_publisher.dart';
import 'package:syntila_workspace/mcp_registry.dart';
import 'package:syntila_workspace/mcp_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late McpRegistry registry;
  late McpService service;
  late File state;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mcp-inventory-');
    registry = McpRegistry(File('${root.path}/mcp.json'));
    service = McpService(registry, _NoProbe());
    state = File('${root.path}/inventory-revision.json');
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<void> addServer(String id) async {
    final binary = File('${root.path}/$id')..writeAsStringSync('#!/bin/sh\n');
    await service.add(
      serverId: id,
      displayName: 'Server $id',
      command: binary.path,
      arguments: ['--token-file', '/home/me/secret'],
      environmentNames: ['API_TOKEN'],
    );
  }

  test('publishes the sanitized shape and never launch details', () async {
    await addServer('files');
    final snapshot = (await McpInventoryPublisher(service, state).snapshot())!;
    expect(snapshot['schemaVersion'], 1);
    final text = jsonEncode(snapshot);
    for (final secret in [root.path, '--token-file', '/home/me', 'API_TOKEN']) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
    final server = (snapshot['servers'] as List).single as Map;
    expect(server['serverId'], 'files');
    expect(server['availability'], 'unknown');
    expect(server['consented'], isFalse);
  });

  test('the revision rises only when the content changes and survives restart',
      () async {
    final publisher = McpInventoryPublisher(service, state);
    final empty = (await publisher.snapshot())!;
    expect((await publisher.snapshot())!['revision'], empty['revision']);
    await addServer('files');
    final added = (await publisher.snapshot())!;
    expect(added['revision'] as int, greaterThan(empty['revision'] as int));
    // A new publisher (a restarted Service) continues from the stored value.
    final restarted = (await McpInventoryPublisher(service, state).snapshot())!;
    expect(restarted['revision'], added['revision']);
    service.bind('chatgpt', 'files');
    final bound = (await McpInventoryPublisher(service, state).snapshot())!;
    expect(bound['revision'] as int, greaterThan(added['revision'] as int));
  });

  test('an unreadable registry publishes nothing instead of an empty list',
      () async {
    File('${root.path}/mcp.json').writeAsStringSync('{ not json');
    expect(await McpInventoryPublisher(service, state).snapshot(), isNull);
  });
}

class _NoProbe implements McpProbePort {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
