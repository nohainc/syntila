import 'dart:convert';

import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('downloads binary bytes with an authenticated encoded file path',
      () async {
    final api = AxApiClient(
      baseUrl: 'https://cloud.test/api',
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(
            request.url.toString(), 'https://cloud.test/api/files/a%2Fb%20%3F');
        expect(request.headers['authorization'], 'Bearer session-token');
        expect(request.headers['accept'], 'application/json');
        return http.Response.bytes([0, 128, 255, 42], 200);
      }),
    )..sessionToken = 'session-token';
    expect(await api.downloadUserFile('a/b ?'), [0, 128, 255, 42]);
  });

  test('download reports non-200 responses', () async {
    for (final status in [201, 401, 404, 503]) {
      final api = AxApiClient(
        baseUrl: 'https://cloud.test/api',
        client: MockClient((request) async => http.Response('', status)),
      );
      await expectLater(
        api.downloadUserFile('file'),
        throwsA(isA<AxApiException>()
            .having((error) => error.message, 'message',
                'Downloading the file failed')
            .having((error) => error.statusCode, 'statusCode', status)),
      );
    }
  });

  test('sync follows opaque cursors and phase transitions until complete',
      () async {
    final requests = <Uri>[];
    final api = AxApiClient(
      baseUrl: 'https://cloud.test/api',
      client: MockClient((request) async {
        expect(request.method, 'POST');
        requests.add(request.url);
        return http.Response(
            jsonEncode({
              'next': switch (requests.length) {
                1 => {'phase': 'storage', 'cursor': 'a+/=?'},
                2 => {'phase': 'records'},
                _ => null,
              },
            }),
            200);
      }),
    );
    await api.syncUserFiles();
    expect(requests.length, 3);
    expect(requests.first.path, '/api/files/sync');
    expect(
        requests[1].queryParameters, {'phase': 'storage', 'cursor': 'a+/=?'});
    expect(requests[2].queryParameters, {'phase': 'records'});
  });

  test('sync stops on a failed batch', () async {
    var requests = 0;
    final api = AxApiClient(
      baseUrl: 'https://cloud.test/api',
      client: MockClient((request) async {
        requests++;
        return http.Response('Unavailable', 503);
      }),
    );
    await expectLater(api.syncUserFiles(), throwsA(isA<AxApiException>()));
    expect(requests, 1);
  });
}
