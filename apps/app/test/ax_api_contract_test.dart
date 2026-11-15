import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syntila_app/src/ax/ax_data.dart';

http.Response _json(Object body, int status) => http.Response(
    jsonEncode(body), status,
    headers: const {'content-type': 'application/json'});

void main() {
  test('invalid_request errors list every problem the server found', () {
    final error = axApiErrorFrom(
        'Space creation',
        400,
        jsonEncode({
          'error': 'Required',
          'code': 'invalid_request',
          'requestId': 'r1',
          'details': [
            {'path': 'name', 'message': 'Required'},
            {'path': 'settings.instructions', 'message': 'Too long'},
          ],
        }));
    expect(error.statusCode, 400);
    expect(error.code, 'invalid_request');
    expect(error.details.map((d) => d.path), ['name', 'settings.instructions']);
    expect(error.message,
        'Space creation failed (400): name: Required; settings.instructions: Too long');
  });

  test('errors without details keep the server text, non-JSON keeps the status',
      () {
    expect(
        axApiErrorFrom('Creating the note', 403,
                jsonEncode({'error': 'Forbidden', 'code': 'forbidden'}))
            .message,
        'Creating the note failed (403): Forbidden');
    final proxy = axApiErrorFrom('Creating the note', 502, '<html>');
    expect(proxy.message, 'Creating the note failed (502)');
    expect(proxy.details, isEmpty);
  });

  test('creating a Space sends one Idempotency-Key and retries a lost response',
      () async {
    final keys = <String?>[];
    var attempts = 0;
    final client = MockClient((request) async {
      keys.add(request.headers['Idempotency-Key']);
      if (attempts++ == 0) throw http.ClientException('connection reset');
      return _json({
        'space': {
          'id': 's1',
          'name': 'Trip',
          'kind': 'group',
          'createdAt': '2026-11-01T00:00:00.000Z',
          'updatedAt': '2026-11-01T00:00:00.000Z',
        }
      }, 201);
    });
    final api = AxApiClient(baseUrl: 'https://syntila.test/api', client: client);
    final space = await api.createSpace(name: 'Trip');
    expect(space.id, 's1');
    expect(keys, hasLength(2));
    expect(keys.first, isNotNull);
    expect(keys.last, keys.first);
  });

  test('creating a Space surfaces validation details', () async {
    final api = AxApiClient(
        baseUrl: 'https://syntila.test/api',
        client: MockClient((_) async => _json({
              'error': 'Required',
              'code': 'invalid_request',
              'details': [
                {'path': 'name', 'message': 'Required'}
              ],
            }, 400)));
    await expectLater(
        api.createSpace(name: ''),
        throwsA(isA<AxApiException>()
            .having((e) => e.code, 'code', 'invalid_request')
            .having((e) => e.message, 'message',
                'Space creation failed (400): name: Required')));
  });

  test('notes follow nextCursor until the last page', () async {
    final cursors = <String?>[];
    final client = MockClient((request) async {
      final cursor = request.url.queryParameters['cursor'];
      cursors.add(cursor);
      Map<String, Object?> note(String id) => {
            'id': id,
            'title': id,
            'body': '',
            'revision': 1,
            'createdAt': '2026-11-01T00:00:00.000Z',
            'updatedAt': '2026-11-01T00:00:00.000Z',
          };
      return cursor == null
          ? _json({
              'notes': [note('n1'), note('n2')],
              'nextCursor': 'page-2'
            }, 200)
          : _json({
              'notes': [note('n3')],
              'nextCursor': null
            }, 200);
    });
    final api = AxApiClient(baseUrl: 'https://syntila.test/api', client: client);
    final notes = await api.loadNotes();
    expect(notes.map((n) => n.id), ['n1', 'n2', 'n3']);
    expect(cursors, [null, 'page-2']);
  });
}
