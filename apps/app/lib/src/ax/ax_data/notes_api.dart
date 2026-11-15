part of '../ax_data.dart';

mixin _NotesApi on _AxApiClientCore implements AxNotesDataSource {
  AxNote _noteFrom(http.Response response, String action) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw axApiErrorFrom(action, response.statusCode, response.body);
    }
    final body = jsonDecode(response.body);
    final note = body is Map ? body['note'] : null;
    if (note is! Map) throw AxApiException('$action response is malformed');
    return AxNote.fromJson(Map<String, dynamic>.from(note));
  }

  @override
  Future<List<AxNote>> loadNotes() async {
    final notes = <AxNote>[];
    String? cursor;
    // Follow `nextCursor` (500 per page); the cap bounds a runaway loop.
    for (var page = 0; page < 20; page++) {
      final body = await _getJson(Uri.parse('$baseUrl/notes').replace(
          queryParameters: {
            'limit': '500',
            if (cursor != null) 'cursor': cursor,
          }));
      notes.addAll((body['notes'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => AxNote.fromJson(Map<String, dynamic>.from(item))));
      final next = body['nextCursor'];
      if (next is! String || next.isEmpty) break;
      cursor = next;
    }
    return notes;
  }

  @override
  Future<AxNote> loadNote(String id) async {
    final body =
        await _getJson(Uri.parse('$baseUrl/notes/${Uri.encodeComponent(id)}'));
    final note = body['note'];
    if (note is! Map) throw const AxApiException('Note response is malformed');
    return AxNote.fromJson(Map<String, dynamic>.from(note));
  }

  @override
  Future<AxNote> createNote({String title = '', String body = ''}) async {
    final idempotencyKey = newAxIdempotencyKey();
    return _noteFrom(
        await _retryOnceWithKey(
            idempotencyKey,
            () => client.post(Uri.parse('$baseUrl/notes'),
                headers: {
                  ..._headers(contentType: 'application/json'),
                  'Idempotency-Key': idempotencyKey,
                },
                body: jsonEncode({'title': title, 'body': body}))),
        'Creating the note');
  }

  @override
  Future<AxNote> updateNote(String id,
          {String? title, String? body, required int revision}) async =>
      _noteFrom(
          await client.put(
              Uri.parse('$baseUrl/notes/${Uri.encodeComponent(id)}'),
              headers: _headers(contentType: 'application/json'),
              body: jsonEncode({
                if (title != null) 'title': title,
                if (body != null) 'body': body,
                'revision': revision,
              })),
          'Saving the note');

  @override
  Future<void> deleteNote(String id) async {
    final response = await client.delete(
        Uri.parse('$baseUrl/notes/${Uri.encodeComponent(id)}'),
        headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Deleting the note failed',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<AxNote?> loadThreadNote(String threadId) async {
    final body = await _getJson(
        Uri.parse('$baseUrl/threads/${Uri.encodeComponent(threadId)}/note'));
    final note = body['note'];
    return note is Map
        ? AxNote.fromJson(Map<String, dynamic>.from(note))
        : null;
  }

  @override
  Future<AxNote> saveThreadNote(String threadId,
          {required String body, int? revision}) async =>
      _noteFrom(
          await client.put(
              Uri.parse(
                  '$baseUrl/threads/${Uri.encodeComponent(threadId)}/note'),
              headers: _headers(contentType: 'application/json'),
              body: jsonEncode(
                  {'body': body, if (revision != null) 'revision': revision})),
          'Saving the note');
}
