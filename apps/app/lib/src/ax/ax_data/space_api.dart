part of '../ax_data.dart';

mixin _SpaceApi on _AxApiClientCore {
  @override
  Future<AxSpace> loadSpace({required String spaceId}) async {
    final response = await _getJson(Uri.parse('$baseUrl/spaces/$spaceId'),
        conditional: true);
    final value = response['space'];
    if (value is! Map) {
      throw const AxApiException('Space response is malformed');
    }
    final space = AxSpace.fromJson(Map<String, dynamic>.from(value));
    if (space.id != spaceId) {
      throw const AxApiException('Space response identity does not match');
    }
    return space.copyWith(threads: const []);
  }

  @override
  Future<AxSpace> createSpace({
    required String name,
    String? description,
    String? instructions,
    String? workspaceId,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/spaces'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'name': name,
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
        if (instructions != null && instructions.trim().isNotEmpty)
          'settings': {'instructions': instructions.trim()},
        if (workspaceId != null) 'workspaceId': workspaceId,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['error'] is String) {
          detail = ': ${body['error']}';
        }
      } on Object {
        // Keep the status useful even when the server response is not JSON.
      }
      throw AxApiException(
        'Space creation failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final space = body is Map ? (body['space']) : null;
    if (space is! Map) {
      throw const AxApiException('Space creation response is malformed');
    }
    final value = Map<String, dynamic>.from(space);
    return AxSpace.fromJson({
      ...value,
      'branch': value['branch'] ?? '',
      'lastActivity': value['lastActivity'] ?? value['updatedAt'] ?? '',
      'settings': value['settings'] ?? const {},
    });
  }

  @override
  Future<AxSpace> updateSpace({
    required String spaceId,
    String? name,
    String? description,
    String? instructions,
    Map<String, dynamic>? settings,
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/spaces/$spaceId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (instructions != null) 'instructions': instructions,
        if (instructions != null || settings != null)
          'settings': {
            if (settings != null)
              ...Map<String, dynamic>.from(settings)
                ..remove('memberPermissions')
                ..remove('invitationPermissions'),
            if (instructions != null) 'instructions': instructions,
          },
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep the status useful when the server response is not JSON.
      }
      throw AxApiException(
          'Space update failed (${response.statusCode})$detail',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final space = body is Map ? (body['space']) : null;
    if (space is! Map) {
      throw const AxApiException('Space update response is malformed');
    }
    final value = Map<String, dynamic>.from(space);
    return AxSpace.fromJson({
      ...value,
      'lastActivity': value['lastActivity'] ?? value['updatedAt'] ?? '',
      'settings': value['settings'] ?? const {},
    });
  }

  @override
  Future<void> archiveSpace({required String spaceId, bool direct = false}) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/spaces/$spaceId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode(direct ? {'hidden': true} : {'archived': true}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Space archive failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> deleteSpace({required String spaceId}) async {
    final response = await client.delete(Uri.parse('$baseUrl/spaces/$spaceId'),
        headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['error'] is String) {
          detail = ': ${body['error']}';
        }
      } catch (_) {
        // Keep the status-only message when the server returned non-JSON.
      }
      throw AxApiException(
          'Space deletion failed (${response.statusCode})$detail',
          statusCode: response.statusCode);
    }
  }

  Future<Map<String, dynamic>> _spaceJson(Uri uri) async {
    final response = await client.get(uri, headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Space collaboration request failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    if (body is! Map) {
      throw const AxApiException('Space collaboration response malformed');
    }
    return Map<String, dynamic>.from(body);
  }

  @override
  Future<List<AxSpaceMember>> loadSpaceMembers({
    required String spaceId,
  }) async {
    final body =
        await _spaceJson(Uri.parse('$baseUrl/spaces/$spaceId/members'));
    return (body['members'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxSpaceMember.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<AxSpaceMemberUsage> loadSpaceMemberUsage({
    required String spaceId,
  }) async {
    final body =
        await _spaceJson(Uri.parse('$baseUrl/spaces/$spaceId/members'));
    final usage = body['usage'];
    return usage is Map
        ? AxSpaceMemberUsage.fromJson(Map<String, dynamic>.from(usage))
        : const AxSpaceMemberUsage(members: 0, pendingInvitations: 0);
  }

  @override
  Future<List<AxSpaceInvitation>> loadSpaceInvitations({
    required String spaceId,
  }) async {
    final body =
        await _spaceJson(Uri.parse('$baseUrl/spaces/$spaceId/invitations'));
    return (body['invitations'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            AxSpaceInvitation.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<AxAuditEntry>> loadSpaceAudit({
    required String spaceId,
  }) async {
    final body = await _spaceJson(Uri.parse('$baseUrl/spaces/$spaceId/audit'));
    return (body['entries'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxAuditEntry.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<void> _spaceMutation(Uri uri, Map<String, dynamic> body,
      {String method = 'POST', String? idempotencyKey}) async {
    Future<http.StreamedResponse> send() =>
        client.send(http.Request(method, uri)
          ..headers.addAll({
            ..._headers(contentType: 'application/json'),
            if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
          })
          ..body = jsonEncode(body));
    final response = await _retryOnceWithKey(idempotencyKey, send);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final responseBody = await response.stream.bytesToString();
      var detail = '';
      try {
        final errorBody = jsonDecode(responseBody);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep the status-only message when the server response is not JSON.
      }
      throw AxApiException(
          'Space collaboration action failed (${response.statusCode})$detail',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> updateSpaceMemberPermissions(
          {required String spaceId,
          required String userId,
          required AxSpacePermissions permissions}) =>
      _spaceMutation(
          Uri.parse('$baseUrl/spaces/$spaceId/members/$userId/permissions'),
          {'permissions': permissions.toJson()},
          method: 'PATCH');

  Future<void> invitePersonToSpace(
          {required String spaceId,
          required String userId,
          required String role,
          required AxSpacePermissions permissions}) =>
      _spaceMutation(Uri.parse('$baseUrl/spaces/$spaceId/invitations'),
          {'userId': userId, 'role': role, 'permissions': permissions.toJson()},
          idempotencyKey: newAxIdempotencyKey());

  @override
  Future<void> inviteSpaceMemberWithPermissions(
          {required String spaceId,
          required String email,
          required String role,
          required AxSpacePermissions permissions}) =>
      _spaceMutation(Uri.parse('$baseUrl/spaces/$spaceId/invitations'),
          {'email': email, 'role': role, 'permissions': permissions.toJson()},
          idempotencyKey: newAxIdempotencyKey());

  @override
  Future<void> changeSpaceMemberRole(
          {required String spaceId,
          required String userId,
          required String role}) =>
      _spaceMutation(Uri.parse('$baseUrl/spaces/$spaceId/members/$userId/role'),
          {'role': role},
          method: 'PATCH');

  @override
  Future<void> removeSpaceMember(
          {required String spaceId, required String userId}) =>
      _spaceMutation(
          Uri.parse('$baseUrl/spaces/$spaceId/members/$userId/remove'), {},
          method: 'POST');

  @override
  Future<void> expireSpaceInvitation(
          {required String spaceId, required String invitationId}) =>
      _spaceMutation(
          Uri.parse(
              '$baseUrl/spaces/$spaceId/invitations/$invitationId/expire'),
          {},
          method: 'POST');

  @override
  Future<List<AxSpaceInvitation>> loadCurrentUserInvitations() async {
    final body = await _spaceJson(Uri.parse('$baseUrl/me/invitations'));
    return (body['invitations'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            AxSpaceInvitation.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<void> acceptSpaceInvitation({required String invitationId}) =>
      _spaceMutation(Uri.parse('$baseUrl/invitations/$invitationId/accept'), {},
          method: 'POST');

  @override
  Future<void> declineSpaceInvitation({required String invitationId}) =>
      _spaceMutation(
          Uri.parse('$baseUrl/invitations/$invitationId/decline'), {},
          method: 'POST');
}
