import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syntila_app/src/ax/ax_data.dart';

void main() {
  test('native sign-in carries the signed cookie through session and logout',
      () async {
    const cookie = 'better-auth.session_token=signed%2Evalue';
    final api = AxApiClient(
        baseUrl: 'http://localhost:8787/api',
        client: MockClient((request) async {
          switch (request.url.path) {
            case '/api/auth/sign-in/email':
              return http.Response('{"token":"unsigned-token"}', 200, headers: {
                'set-cookie': '$cookie; Path=/; HttpOnly; SameSite=Lax'
              });
            case '/api/session':
              return http.Response(
                  '{"authenticated":${request.headers['cookie'] == cookie}}',
                  200);
            case '/api/auth/sign-out':
              expect(request.headers['cookie'], cookie);
              expect(request.headers['origin'], 'http://localhost:8787');
              expect(request.headers['authorization'], isNull);
              return http.Response('{}', 200);
            default:
              return http.Response('', 404);
          }
        }));
    await api.signInWithEmail(
        email: 'person@example.com', password: 'password');
    expect((await api.loadSession()).authenticated, isTrue);
    await api.logout();
    expect((await api.loadSession()).authenticated, isFalse);
  });
}
