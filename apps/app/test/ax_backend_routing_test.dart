import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syntila_app/src/ax/ax_backend_routing.dart';

void main() {
  test('auth-owned paths stay on the auth Worker', () {
    for (final path in ['/session', '/session/logout', '/auth/sign-in/email', '/desktop-auth/intents', '/backend-token', '/dev/sign-in']) {
      expect(isAuthOwnedApiPath(path), isTrue, reason: path);
    }
    for (final path in ['/spaces', '/me/plan', '/profile/avatar', '/sessions', '/authors', '/realtime/tickets']) {
      expect(isAuthOwnedApiPath(path), isFalse, reason: path);
    }
  });

  test('routes product calls to the backend with a cached backend token', () async {
    final seen = <http.Request>[];
    var issued = 0;
    final inner = MockClient((request) async {
      seen.add(request);
      if (request.url.path == '/api/backend-token') {
        issued++;
        return http.Response(jsonEncode({'token': 'jwt-$issued', 'expiresAt': DateTime.now().add(const Duration(minutes: 15)).toIso8601String()}), 200);
      }
      return http.Response('{"ok":true}', 200);
    });
    final tokens = AxBackendTokenSource(() async => AxBackendTokenSource.parse(
        (await inner.post(Uri.parse('https://syntila.app/api/backend-token'))).body));
    final client = AxBackendRoutingClient(
      inner: inner,
      authBaseUrl: 'https://syntila.app/api',
      backendBaseUrl: 'https://api.syntila.app/api',
      tokens: tokens,
    );

    await client.get(Uri.parse('https://syntila.app/api/session'), headers: {'cookie': 'better-auth.session_token=x'});
    await client.post(Uri.parse('https://syntila.app/api/spaces?x=1'),
        headers: {'cookie': 'better-auth.session_token=x', 'authorization': 'Bearer syntila_dhs_secret', 'content-type': 'application/json'},
        body: '{"name":"S"}');
    await client.get(Uri.parse('https://syntila.app/api/spaces'));

    expect(seen.map((r) => r.url.toString()), [
      'https://syntila.app/api/session',
      'https://syntila.app/api/backend-token',
      'https://api.syntila.app/api/spaces?x=1',
      'https://api.syntila.app/api/spaces',
    ]);
    final routed = seen[2];
    expect(routed.headers['authorization'], 'Bearer jwt-1');
    expect(routed.headers.containsKey('cookie'), isFalse);
    expect(routed.body, '{"name":"S"}');
    expect(issued, 1); // reused until close to expiry
  });

  test('signed out: backend calls go without a token and get the backend 401', () async {
    final seen = <http.Request>[];
    final inner = MockClient((request) async {
      seen.add(request);
      if (request.url.path == '/api/backend-token') return http.Response('{"error":"Authentication required"}', 401);
      return http.Response('{"error":"Authentication required"}', 401);
    });
    final tokens = AxBackendTokenSource(() async {
      final response = await inner.post(Uri.parse('https://syntila.app/api/backend-token'));
      return response.statusCode == 401 ? null : AxBackendTokenSource.parse(response.body);
    });
    final client = AxBackendRoutingClient(inner: inner, authBaseUrl: 'https://syntila.app/api', backendBaseUrl: 'https://api.syntila.app/api', tokens: tokens);
    final response = await client.get(Uri.parse('https://syntila.app/api/spaces'));
    expect(response.statusCode, 401);
    expect(seen.last.url.host, 'api.syntila.app');
    expect(seen.last.headers.containsKey('authorization'), isFalse);
  });

  test('relative request URLs (web: SYNTILA_API_URL=/api) are routed too', () async {
    final seen = <Uri>[];
    final inner = MockClient((request) async {
      seen.add(request.url);
      if (request.url.path.endsWith('/backend-token')) {
        return http.Response(jsonEncode({'token': 't', 'expiresAt': DateTime.now().add(const Duration(minutes: 15)).toIso8601String()}), 200);
      }
      return http.Response('{}', 200);
    });
    final tokens = AxBackendTokenSource(() async => AxBackendTokenSource.parse((await inner.post(Uri.parse('/api/backend-token'))).body));
    final client = AxBackendRoutingClient(inner: inner, authBaseUrl: '/api', backendBaseUrl: 'https://api.syntila.app/api', tokens: tokens);
    await client.get(Uri.parse('/api/session'));
    await client.get(Uri.parse('/api/spaces'));
    expect(seen.first.path, '/api/session');
    expect(seen.last.toString(), 'https://api.syntila.app/api/spaces');
  });

  test('a 401 from the backend drops the cached token', () async {
    var issued = 0;
    var calls = 0;
    final inner = MockClient((request) async {
      if (request.url.host == 'api.syntila.app') return http.Response('', ++calls == 1 ? 401 : 200);
      issued++;
      return http.Response(jsonEncode({'token': 't$issued', 'expiresAt': DateTime.now().add(const Duration(minutes: 15)).toIso8601String()}), 200);
    });
    final tokens = AxBackendTokenSource(() async => AxBackendTokenSource.parse(
        (await inner.post(Uri.parse('https://syntila.app/api/backend-token'))).body));
    final client = AxBackendRoutingClient(inner: inner, authBaseUrl: 'https://syntila.app/api', backendBaseUrl: 'https://api.syntila.app/api', tokens: tokens);
    expect((await client.get(Uri.parse('https://syntila.app/api/spaces'))).statusCode, 401);
    expect((await client.get(Uri.parse('https://syntila.app/api/spaces'))).statusCode, 200);
    expect(issued, 2);
  });
}
