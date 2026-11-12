import 'dart:io';

import 'package:syntila_cli_worker_engine/src/model_discovery.dart';
import 'package:test/test.dart';

void main() {
  test('Claude Models API sends the full id and shows display_name', () {
    final models = parseClaudeApiModels({
      'data': [
        {
          'id': 'claude-fable-5-2',
          'display_name': 'Claude Fable 5.2',
          'lifecycle': 'active',
          'capabilities': {
            'effort': {
              'supported': true,
              'low': {'supported': true},
              'medium': {'supported': true},
              'high': {'supported': true},
              'xhigh': {'supported': false},
              'max': {'supported': true},
            },
          },
        },
        {'id': 'claude-old-1', 'display_name': 'Old', 'lifecycle': 'retired'},
        {'id': 'other-model', 'display_name': 'Other'},
      ],
    }, 'claude-');
    expect(models.map((m) => m.id), ['claude-fable-5-2']);
    expect(models.single.name, 'Claude Fable 5.2');
    expect(models.single.supportedReasoningEfforts, [
      'low',
      'medium',
      'high',
      'max',
    ]);
  });

  group('rejected credential', () {
    late HttpServer server;
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response
          ..statusCode = 401
          ..close();
      });
    });
    tearDown(() => server.close(force: true));

    Uri local() => Uri.http('127.0.0.1:${server.port}', '/v1/models');

    test('an expired Claude Code sign-in token is not a sign-in problem', () {
      expect(
        discoverClaudeApiModels(
          idPrefix: 'claude-',
          environment: const {},
          credentialReader: (_) async => {
            'authorization': 'Bearer expired',
            'anthropic-beta': 'oauth-2025-04-20',
          },
          endpoint: local(),
        ),
        throwsA(isA<ClaudeSignInTokenNeedsRefreshException>()),
      );
    });

    test('a rejected API key still asks the user to sign in', () {
      expect(
        discoverClaudeApiModels(
          idPrefix: 'claude-',
          environment: const {},
          credentialReader: (_) async => {'x-api-key': 'bad'},
          endpoint: local(),
        ),
        throwsA(isA<ProviderNotAuthenticatedException>()),
      );
    });
  });
}
