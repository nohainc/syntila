import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_profile_lab/profile_lab_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProfileLabSession', () {
    test(
        'parses valid Profile Lab session with syntila.profile-lab.management audience',
        () {
      final expiresAt = DateTime.now().toUtc().add(const Duration(days: 30));
      final issuedAt = DateTime.now().toUtc();
      final session = ProfileLabSession.fromJson({
        'credential': 'syntila_dhs_secret123',
        'sessionId': 'session-xyz',
        'audience': 'syntila.profile-lab.management',
        'user': {
          'userId': 'admin-user-1',
          'displayName': 'Admin User',
          'email': 'admin@syntila.test',
        },
        'expiresAt': expiresAt.toIso8601String(),
        'issuedAt': issuedAt.toIso8601String(),
      });

      expect(session.credential, 'syntila_dhs_secret123');
      expect(session.sessionId, 'session-xyz');
      expect(session.userId, 'admin-user-1');
      expect(session.displayName, 'Admin User');
      expect(session.email, 'admin@syntila.test');
      expect(session.audience, 'syntila.profile-lab.management');
      expect(session.isExpired, isFalse);
    });

    test(
        'strictly rejects the Connect session audience syntila.desktop.management',
        () {
      final expiresAt = DateTime.now().toUtc().add(const Duration(days: 30));
      expect(
        () => ProfileLabSession.fromJson({
          'credential': 'syntila_dhs_secret123',
          'sessionId': 'session-xyz',
          'audience': 'syntila.desktop.management',
          'user': {
            'userId': 'admin-user-1',
            'displayName': 'Admin User',
            'email': 'admin@syntila.test',
          },
          'expiresAt': expiresAt.toIso8601String(),
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ProfileLabAuthClient', () {
    test('binds browser passkey proof to the Profile Lab session', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.method, 'POST');
        expect(
            request.uri.path, '/api/desktop-auth/profile-lab/step-up/complete');
        expect(request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer profile-lab-token');
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ok":true,"method":"passkey"}');
        await request.response.close();
      });
      final client =
          ProfileLabAuthClient(cloudUrl: 'http://127.0.0.1:${server.port}');
      addTearDown(client.close);
      final session = ProfileLabSession(
        credential: 'profile-lab-token',
        sessionId: 'session-step-up',
        userId: 'admin-1',
        displayName: 'Admin',
        email: 'admin@syntila.test',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      );

      await client.completeStepUp(session);
    });

    test(
        'creates intent with syntila.profile-lab.management audience and clientName',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/api/desktop-auth/intents');
        final bodyText = await utf8.decoder.bind(request).join();
        final body = jsonDecode(bodyText) as Map<String, dynamic>;
        expect(body['clientName'], 'Syntila Profile Lab');
        expect(body['contractVersion'], '1.1');
        expect(body['audience'], 'syntila.profile-lab.management');

        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'intentId': 'intent-lab-1',
          'pollToken': 'poll-token-lab-xyz',
          'verificationUrl':
              'http://127.0.0.1:${server.port}/desktop-auth/approve',
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 10))
              .toIso8601String(),
          'pollIntervalMs': 1000,
          'audience': 'syntila.profile-lab.management',
        }));
        await request.response.close();
      });

      final client =
          ProfileLabAuthClient(cloudUrl: 'http://127.0.0.1:${server.port}');
      addTearDown(client.close);

      final intent = await client.createIntent();
      expect(intent.intentId, 'intent-lab-1');
      expect(intent.pollToken, 'poll-token-lab-xyz');
      expect(intent.audience, 'syntila.profile-lab.management');
    });

    test('polls, claims, and validates a Profile Lab session', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      var pollCount = 0;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/api/desktop-auth/intents/intent-lab-1' &&
            request.method == 'GET') {
          pollCount++;
          if (pollCount == 1) {
            request.response.write(jsonEncode({'status': 'pending'}));
          } else {
            request.response.write(jsonEncode({'status': 'approved'}));
          }
        } else if (request.uri.path ==
                '/api/desktop-auth/intents/intent-lab-1/claim' &&
            request.method == 'POST') {
          final bodyText = await utf8.decoder.bind(request).join();
          final body = jsonDecode(bodyText) as Map<String, dynamic>;
          expect(body['pollToken'], 'poll-token-lab-xyz');
          request.response.write(jsonEncode({
            'credential': 'syntila_dhs_claimed123',
            'sessionId': 'session-claimed-1',
            'audience': 'syntila.profile-lab.management',
            'user': {
              'userId': 'admin-1',
              'displayName': 'Admin One',
              'email': 'admin1@syntila.test',
            },
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(days: 30))
                .toIso8601String(),
          }));
        } else if (request.uri.path == '/api/desktop-auth/session' &&
            request.method == 'GET') {
          expect(request.headers.value(HttpHeaders.authorizationHeader),
              'Bearer syntila_dhs_claimed123');
          request.response.write(jsonEncode({
            'sessionId': 'session-claimed-1',
            'audience': 'syntila.profile-lab.management',
            'user': {
              'userId': 'admin-1',
              'displayName': 'Admin One',
              'email': 'admin1@syntila.test',
            },
          }));
        }
        await request.response.close();
      });

      final client =
          ProfileLabAuthClient(cloudUrl: 'http://127.0.0.1:${server.port}');
      addTearDown(client.close);

      final intent = ProfileLabAuthIntent(
        intentId: 'intent-lab-1',
        pollToken: 'poll-token-lab-xyz',
        verificationUrl: Uri.parse('http://127.0.0.1:${server.port}/verify'),
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        pollIntervalMs: 100,
        audience: 'syntila.profile-lab.management',
      );

      final session = await client.waitForApprovalAndClaim(intent);
      expect(session.credential, 'syntila_dhs_claimed123');
      expect(session.sessionId, 'session-claimed-1');
      expect(session.audience, 'syntila.profile-lab.management');

      await expectLater(client.validateSession(session), completes);
    });

    test('revokes a Profile Lab session', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final revokedCompleter = Completer<void>();
      server.listen((request) async {
        expect(request.method, 'POST');
        expect(request.uri.path,
            '/api/desktop-auth/sessions/session-lab-1/revoke');
        expect(request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer syntila_dhs_revoke_cred');
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'revoked': true}));
        await request.response.close();
        revokedCompleter.complete();
      });

      final client =
          ProfileLabAuthClient(cloudUrl: 'http://127.0.0.1:${server.port}');
      addTearDown(client.close);

      final session = ProfileLabSession(
        credential: 'syntila_dhs_revoke_cred',
        sessionId: 'session-lab-1',
        userId: 'admin-1',
        displayName: 'Admin',
        email: 'admin@syntila.test',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      );

      await client.revokeSession(session);
      await revokedCompleter.future;
    });
  });
}
