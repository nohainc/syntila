part of '../ax_data.dart';

mixin _CatalogApi on _AxApiClientCore {
  /// User-level workflow endpoints address one Workspace; without it Cloud
  /// uses the user's selected Workspace.
  String _userWorkflowUrl(String path, String? workspaceId) =>
      '$baseUrl/user/$path${workspaceId == null ? '' : '?workspaceId=${Uri.encodeQueryComponent(workspaceId)}'}';

  Future<List<AxUserWorkflowConfiguration>> loadWorkflowConfigurations(
      {String? workspaceId}) async {
    final body = await _getJson(
        Uri.parse(_userWorkflowUrl('workflow-configurations', workspaceId)));
    return (body['configurations'] as List)
        .map((value) => AxUserWorkflowConfiguration.fromJson(
            Map<String, dynamic>.from(value as Map)))
        .toList();
  }

  Future<AxUserWorkflowConfiguration> saveWorkflowConfiguration(
      AxUserWorkflowConfiguration configuration,
      {String? workspaceId}) async {
    final response = await client.put(
        Uri.parse(_userWorkflowUrl(
            'workflow-configurations/${Uri.encodeComponent(configuration.workflowId)}',
            workspaceId)),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode(configuration.toJson()));
    return _configurationResponse(response);
  }

  Future<AxUserWorkflowConfiguration> resetWorkflowConfiguration(
      String workflowId,
      {String? workspaceId}) async {
    final response = await client.delete(
        Uri.parse(_userWorkflowUrl(
            'workflow-configurations/${Uri.encodeComponent(workflowId)}',
            workspaceId)),
        headers: _headers());
    return _configurationResponse(response);
  }

  Future<AxWorkerUsageReport> readWorkerUsage({
    required String workspaceId,
    required String workerId,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workers/${Uri.encodeComponent(workerId)}/usage'),
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
            ? 'Only the Worker owner can read this Worker\'s usage.'
            : message);
  }

  Future<List<AxUserWorkflowConfiguration>> loadSpaceWorkflowConfigurations(
      String spaceId) async {
    final body = await _getJson(Uri.parse(
        '$baseUrl/spaces/${Uri.encodeComponent(spaceId)}/workflow-configurations'));
    return (body['configurations'] as List)
        .map((value) => AxUserWorkflowConfiguration.fromJson(
            Map<String, dynamic>.from(value as Map)))
        .toList();
  }

  Future<String> loadWorkflowDefault({String? workspaceId}) async =>
      (await _getJson(
              Uri.parse(_userWorkflowUrl('workflow-default', workspaceId))))[
          'defaultWorkflowId'] as String;

  Future<String> saveWorkflowDefault(String workflowId,
      {String? workspaceId}) async {
    final response = await client.put(
        Uri.parse(_userWorkflowUrl('workflow-default', workspaceId)),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode({'defaultWorkflowId': workflowId}));
    return _workflowDefaultResponse(response);
  }

  Future<String> loadSpaceWorkflowDefault(String spaceId) async =>
      (await _getJson(Uri.parse(
              '$baseUrl/spaces/${Uri.encodeComponent(spaceId)}/workflow-default')))[
          'defaultWorkflowId'] as String;

  Future<List<AxPerson>> loadPeople() async {
    final response = await _getJson(Uri.parse('$baseUrl/people'));
    return List.unmodifiable((response['people'] as List).map(
        (row) => AxPerson.fromJson(Map<String, dynamic>.from(row as Map))));
  }

  Future<String> openPersonalSpace(String userId) async {
    final response = await client.post(
      Uri.parse(
          '$baseUrl/people/connections/${Uri.encodeComponent(userId)}/space'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Failed to open personal Space',
          statusCode: response.statusCode);
    }
    return (jsonDecode(response.body) as Map<String, dynamic>)['spaceId']
        as String;
  }

  Future<void> sendPersonInvitation({String? email, String? userId}) async {
    final idempotencyKey = newAxIdempotencyKey();
    final response = await _retryOnceWithKey(
      idempotencyKey,
      () => client.post(
        Uri.parse('$baseUrl/people/invitations'),
        headers: {
          ..._headers(contentType: 'application/json'),
          'Idempotency-Key': idempotencyKey,
        },
        body: jsonEncode({
          if (email != null) 'email': email,
          if (userId != null) 'userId': userId,
        }),
      ),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw axApiErrorFrom(
          'Sending the invitation', response.statusCode, response.body);
    }
  }

  Future<void> acceptPersonInvitation(String invitationId) async {
    final response = await client.post(
      Uri.parse(
          '$baseUrl/people/invitations/${Uri.encodeComponent(invitationId)}/accept'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Failed to accept personal invitation (${response.statusCode}): ${response.body}',
        statusCode: response.statusCode,
      );
    }
  }

  Future<void> declinePersonInvitation(String invitationId) async {
    final response = await client.post(
      Uri.parse(
          '$baseUrl/people/invitations/${Uri.encodeComponent(invitationId)}/decline'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Failed to decline personal invitation (${response.statusCode}): ${response.body}',
        statusCode: response.statusCode,
      );
    }
  }

  Future<void> cancelPersonInvitation(String invitationId) async {
    final response = await client.post(
      Uri.parse(
          '$baseUrl/people/invitations/${Uri.encodeComponent(invitationId)}/cancel'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Failed to cancel personal invitation (${response.statusCode}): ${response.body}',
        statusCode: response.statusCode,
      );
    }
  }

  Future<void> disconnectPersonConnection(String userId) async {
    final response = await client.post(
      Uri.parse(
          '$baseUrl/people/connections/${Uri.encodeComponent(userId)}/disconnect'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Failed to disconnect connection (${response.statusCode}): ${response.body}',
        statusCode: response.statusCode,
      );
    }
  }

  Future<void> blockPerson(String userId) async {
    final response = await client.post(
      Uri.parse('$baseUrl/people/blocks/${Uri.encodeComponent(userId)}'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Failed to block person (${response.statusCode}): ${response.body}',
        statusCode: response.statusCode,
      );
    }
  }

  Future<void> unblockPerson(String userId) async {
    final response = await client.delete(
      Uri.parse('$baseUrl/people/blocks/${Uri.encodeComponent(userId)}'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Failed to unblock person (${response.statusCode}): ${response.body}',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<List<AxDeviceFolder>> loadDeviceFolders() async {
    final body = await _getJson(Uri.parse('$baseUrl/device-folders'));
    final list = body['folders'];
    if (list is! List) {
      throw const AxApiException('Folder list response is malformed');
    }
    return [
      for (final item in list)
        if (item is Map)
          AxDeviceFolder.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  String _spaceFolderUrl(String spaceId) =>
      '$baseUrl/spaces/${Uri.encodeComponent(spaceId)}/folder';

  @override
  Future<AxSpaceFolder> loadSpaceFolder(String spaceId) async =>
      AxSpaceFolder.fromJson(
          await _getJson(Uri.parse(_spaceFolderUrl(spaceId))));

  @override
  Future<AxSpaceFolder> setSpaceFolder(String spaceId,
      {required String deviceId, required String folderId}) async {
    final response = await client.put(Uri.parse(_spaceFolderUrl(spaceId)),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode({'deviceId': deviceId, 'folderId': folderId}));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['error'] is String) {
          detail = body['error'] as String;
        }
      } on FormatException {
        /* Use the status alone. */
      }
      throw AxApiException(
          detail.isNotEmpty
              ? detail
              : 'Could not set the folder (${response.statusCode})',
          statusCode: response.statusCode);
    }
    return AxSpaceFolder.fromJson(
        Map<String, dynamic>.from(jsonDecode(response.body) as Map));
  }

  @override
  Future<void> clearSpaceFolder(String spaceId) async {
    final response = await client.delete(Uri.parse(_spaceFolderUrl(spaceId)),
        headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Could not clear the folder (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<int> removeDeviceFolders(String deviceId,
      {String? folderId, bool dryRun = false}) async {
    final path = '$baseUrl/device-folders/${Uri.encodeComponent(deviceId)}'
        '${folderId == null ? '' : '/${Uri.encodeComponent(folderId)}'}'
        '${dryRun ? '?dryRun=1' : ''}';
    final response = await client.delete(Uri.parse(path), headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        detail = (jsonDecode(response.body) as Map)['error']?.toString() ?? '';
      } on Object {
        // Keep the generic message.
      }
      throw AxApiException(
          detail.isEmpty
              ? 'Could not remove the folder (${response.statusCode})'
              : detail,
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    return body is Map ? (body['spaces'] as num?)?.toInt() ?? 0 : 0;
  }

  AxUserWorkflowConfiguration _configurationResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Workflow configuration failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body) as Map;
    return AxUserWorkflowConfiguration.fromJson(
        Map<String, dynamic>.from(body['configuration'] as Map));
  }

  String _workflowDefaultResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Default workflow selection failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode);
    }
    return (jsonDecode(response.body) as Map)['defaultWorkflowId'] as String;
  }

  @override
  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async {
    final uri = Uri.parse('$baseUrl/spaces').replace(
      queryParameters: includeArchived ? {'archived': 'true'} : null,
    );
    final body = await _getJson(uri);
    final list = body['spaces'];
    return (list as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxSpace.fromJson(Map<String, dynamic>.from(item))
            .copyWith(threads: const []))
        .toList();
  }

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async {
    final body = await _getJson(Uri.parse('$baseUrl/workflows/catalog'),
        conditional: true);
    return (body['workflows'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            AxBuiltinWorkflow.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }
}
