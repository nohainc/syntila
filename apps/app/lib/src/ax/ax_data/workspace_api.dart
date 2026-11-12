part of '../ax_data.dart';

mixin _WorkspaceApi on _AxApiClientCore {
  Future<AxWorkerVisibility> _workerVisibilityRequest(
      String workspaceId, String method,
      [AxWorkerVisibility? value]) async {
    final uri = Uri.parse(
        '$baseUrl/workspaces/${Uri.encodeComponent(workspaceId)}/worker-preferences');
    final headers = _headers(contentType: 'application/json');
    final response = method == 'GET'
        ? await client.get(uri, headers: headers)
        : method == 'PUT'
            ? await client.put(uri,
                headers: headers, body: jsonEncode(value!.toJson()))
            : await client.delete(uri, headers: headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Worker visibility request failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    if (body is! Map || body['preferences'] is! Map) {
      throw const AxApiException('Worker visibility response malformed');
    }
    return AxWorkerVisibility.fromJson(
        Map<String, dynamic>.from(body['preferences'] as Map));
  }

  Future<AxWorkerVisibility> loadWorkerVisibility(String workspaceId) =>
      _workerVisibilityRequest(workspaceId, 'GET');
  Future<AxWorkerVisibility> saveWorkerVisibility(
          String workspaceId, AxWorkerVisibility preferences) =>
      _workerVisibilityRequest(workspaceId, 'PUT', preferences);
  Future<AxWorkerVisibility> resetWorkerVisibility(String workspaceId) =>
      _workerVisibilityRequest(workspaceId, 'DELETE');

  @override
  Future<List<AxWorkspace>> loadWorkspaces() async {
    final response =
        await client.get(Uri.parse('$baseUrl/workspaces'), headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Workspace list failed (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final workspaces = body['workspaces'];
    if (workspaces is! List) {
      throw const AxApiException('Workspace list response is malformed');
    }
    return workspaces
        .whereType<Map>()
        .map((workspace) =>
            AxWorkspace.fromJson(Map<String, dynamic>.from(workspace)))
        .toList();
  }

  Future<AxWorkerUsageReport> readWorkerUsage({
    required String workspaceId,
    required String workerId,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workspaces/${Uri.encodeComponent(workspaceId)}'
          '/workers/${Uri.encodeComponent(workerId)}/usage'),
      headers: _headers(contentType: 'application/json'),
      body: '{}',
    );
    Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      body = null;
    }
    if (body is Map && body['status'] is String) {
      return AxWorkerUsageReport.fromJson(Map<String, dynamic>.from(body));
    }
    final message = body is Map && body['error'] is String
        ? body['error'] as String
        : 'Usage request failed (${response.statusCode})';
    return AxWorkerUsageReport(
        status: 'error',
        errorMessage: response.statusCode == 404
            ? 'Only the Workspace owner can read this Worker\'s usage.'
            : message);
  }

  Future<Map<String, dynamic>> _workspaceJson(Uri uri) async {
    final response = await client.get(uri, headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Workspace settings request failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    if (body is! Map) {
      throw const AxApiException('Workspace settings response malformed');
    }
    return Map<String, dynamic>.from(body);
  }

  @override
  Future<void> setWorkspaceParallelSlots({
    required String workspaceId,
    required int slots,
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/workspaces/$workspaceId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'parallelSlots': slots}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Parallel slots update failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> setWorkspaceSpaceAiSharing({
    required String workspaceId,
    required bool allowChat,
    required bool allowWork,
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/workspaces/$workspaceId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'spaceAiChat': allowChat, 'spaceAiWork': allowWork}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Space AI sharing update failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<AxWorkspace> updateWorkspace({
    required String workspaceId,
    required String name,
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/workspaces/$workspaceId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'name': name}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Workspace update failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final workspace = body is Map ? body['workspace'] : null;
    if (workspace is! Map) {
      throw const AxApiException('Workspace update response malformed');
    }
    return AxWorkspace.fromJson(Map<String, dynamic>.from(workspace));
  }

  @override
  Future<List<AxWorkspaceMember>> loadWorkspaceMembers(
      {required String workspaceId}) async {
    final body = await _workspaceJson(
        Uri.parse('$baseUrl/workspaces/$workspaceId/members'));
    return (body['members'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            AxWorkspaceMember.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<AxWorkspaceInvitation>> loadWorkspaceInvitations(
      {required String workspaceId}) async {
    final body = await _workspaceJson(
        Uri.parse('$baseUrl/workspaces/$workspaceId/invitations'));
    return (body['invitations'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            AxWorkspaceInvitation.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<AxAuditEntry>> loadWorkspaceAudit(
      {required String workspaceId}) async {
    final body = await _workspaceJson(
        Uri.parse('$baseUrl/workspaces/$workspaceId/audit-export'));
    return (body['entries'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxAuditEntry.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<void> _workspaceMutation(Uri uri, Map<String, dynamic> body,
      {String method = 'POST'}) async {
    final request = http.Request(method, uri)
      ..headers.addAll(_headers(contentType: 'application/json'))
      ..body = jsonEncode(body);
    final streamed = await client.send(request);
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw AxApiException('Workspace action failed (${streamed.statusCode})',
          statusCode: streamed.statusCode);
    }
  }

  @override
  Future<void> inviteWorkspaceMember({
    required String workspaceId,
    required String email,
    required String role,
  }) =>
      _workspaceMutation(
        Uri.parse('$baseUrl/workspaces/$workspaceId/invitations'),
        {'email': email, 'role': role},
      );

  @override
  Future<void> changeWorkspaceMemberRole({
    required String workspaceId,
    required String userId,
    required String role,
  }) =>
      _workspaceMutation(
        Uri.parse('$baseUrl/workspaces/$workspaceId/members/$userId/role'),
        {'role': role},
        method: 'PATCH',
      );

  @override
  Future<void> setWorkspaceMemberStatus({
    required String workspaceId,
    required String userId,
    required String status,
  }) =>
      _workspaceMutation(
        Uri.parse('$baseUrl/workspaces/$workspaceId/members/$userId/$status'),
        {},
      );

  @override
  Future<void> expireWorkspaceInvitation({
    required String workspaceId,
    required String invitationId,
  }) =>
      _workspaceMutation(
        Uri.parse(
            '$baseUrl/workspaces/$workspaceId/invitations/$invitationId/expire'),
        {},
      );
}
