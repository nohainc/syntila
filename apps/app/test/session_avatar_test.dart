import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';

void main() {
  test('AxSession.fromJson preserves user.avatarUrl', () {
    final session = AxSession.fromJson({
      'authenticated': true,
      'user': {
        'id': 'eqC8H9EuQXeKVZTBxslQUhFKqbewXDsh',
        'email': 'vitalii@nohainc.com',
        'displayName': 'Vitalii',
        'avatarUrl':
            'https://api.syntila.app/api/users/eqC8H9EuQXeKVZTBxslQUhFKqbewXDsh/avatar?v=a4e6aaea-2b9b-4eee-8179-85d2cbfa0e55',
        'status': 'active',
      },
      'sessionId': 'sess-1',
      'clientType': 'web',
    });

    expect(session.authenticated, isTrue);
    expect(
      session.viewer?.avatarUrl,
      'https://api.syntila.app/api/users/eqC8H9EuQXeKVZTBxslQUhFKqbewXDsh/avatar?v=a4e6aaea-2b9b-4eee-8179-85d2cbfa0e55',
    );
  });

  test('loadAvatar rewrites private avatar URL to baseUrl origin', () async {
    Uri? requestedUri;
    final client = MockClient((request) async {
      requestedUri = request.url;
      return http.Response.bytes([1, 2, 3, 4], 200);
    });

    final api = AxApiClient(
      baseUrl: 'https://app.syntila.app/api',
      client: client,
    );

    final bytes = await api.loadAvatar(
      url:
          'https://api.syntila.app/api/users/eqC8H9EuQXeKVZTBxslQUhFKqbewXDsh/avatar?v=a4e6aaea-2b9b-4eee-8179-85d2cbfa0e55',
    );

    expect(bytes, [1, 2, 3, 4]);
    expect(
      requestedUri.toString(),
      'https://app.syntila.app/api/users/eqC8H9EuQXeKVZTBxslQUhFKqbewXDsh/avatar?v=a4e6aaea-2b9b-4eee-8179-85d2cbfa0e55',
    );
  });
}
