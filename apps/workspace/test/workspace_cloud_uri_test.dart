import 'dart:io';

import 'package:syntila_workspace/workspace_configuration.dart';
import 'package:test/test.dart';

void main() {
  test('headless management derives a secret-free HTTP origin from transport',
      () {
    expect(
        WorkspaceConfigurationResolver.cloudHttpOrigin(Uri.parse(
            'wss://user:secret@cloud.example.test:8443/api/workspace-gateway/connect?token=secret')),
        'https://cloud.example.test:8443');
    expect(
        WorkspaceConfigurationResolver.cloudHttpOrigin(
            Uri.parse('ws://127.0.0.1:9/api/workspace-gateway/connect')),
        'http://127.0.0.1:9');
    // A backend gateway maps back to its auth (desktop sign-in) origin.
    expect(
        WorkspaceConfigurationResolver.cloudHttpOrigin(
            Uri.parse('wss://api.syntila.app/api/workspace-gateway/connect')),
        'https://syntila.app');
  });
  Uri configFor(String cloudUrl) =>
      WorkspaceConfigurationResolver.workspaceGatewayUri(
        cloudUrl,
        workspaceRuntimeId: 'runtime-test',
      )!;

  test('HTTPS origin becomes WSS with a materialized default port', () {
    final uri = configFor('https://syntila.app/#discard-me');

    expect(uri.scheme, 'wss');
    // The gateway runs on the backend; syntila.app is the auth Worker.
    expect(uri.host, 'api.syntila.app');
    expect(uri.port, 443);
    expect(uri.path, '/api/workspace-gateway/connect');
    expect(uri.queryParameters['workspaceRuntimeId'], 'runtime-test');
    expect(uri.hasFragment, isFalse);
    expect(uri.toString(), isNot(contains(':0')));
  });

  test('explicit Cloud ports are preserved', () {
    final standardPort = configFor('https://cloud.example.test:443');
    final uri = configFor('https://cloud.example.test:8443');

    expect(standardPort.port, 443);
    expect(uri.scheme, 'wss');
    expect(uri.port, 8443);
  });

  test('Cloud URL secrets are never copied into the WebSocket query', () {
    final uri = configFor(
      'https://cloud.example.test?source=desktop&authToken=must-not-leak&api_key=also-secret',
    );

    expect(uri.queryParameters['source'], 'desktop');
    expect(uri.queryParameters['workspaceRuntimeId'], 'runtime-test');
    expect(uri.queryParameters.containsKey('authToken'), isFalse);
    expect(uri.queryParameters.containsKey('api_key'), isFalse);
  });

  test('local auth origin maps to the local backend port', () {
    final uri = configFor('http://127.0.0.1:8787');

    expect(uri.scheme, 'ws');
    expect(uri.host, '127.0.0.1');
    expect(uri.port, 8788);
    expect(uri.path, '/api/workspace-gateway/connect');
  });

  test('other local origins keep their explicit development port', () {
    expect(configFor('http://127.0.0.1:8899').port, 8899);
  });

  test('a saved syntila.app gateway URL is moved to the backend', () {
    final uri = configFor('wss://syntila.app/api/workspace-gateway/connect?source=desktop');
    expect(uri.host, 'api.syntila.app');
    expect(uri.path, '/api/workspace-gateway/connect');
    expect(uri.queryParameters['source'], 'desktop');
  });

  test('an explicit WSS endpoint gets a port without losing its path/query',
      () {
    final uri = configFor(
      'wss://cloud.example.test/api/workspace-gateway/connect?source=desktop#old',
    );

    expect(uri.scheme, 'wss');
    expect(uri.port, 443);
    expect(uri.path, '/api/workspace-gateway/connect');
    expect(uri.queryParameters['source'], 'desktop');
    expect(uri.queryParameters['workspaceRuntimeId'], 'runtime-test');
    expect(uri.hasFragment, isFalse);
  });

  test('configured WebSocket URI completes a local upgrade', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upgrade = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add('ready');
      await socket.close();
    });
    addTearDown(() async {
      await upgrade.cancel();
      await server.close(force: true);
    });

    final uri = configFor('ws://${server.address.address}:${server.port}');
    final socket = await WebSocket.connect(uri.toString());
    expect(await socket.first, 'ready');
  });
}
