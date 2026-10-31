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

  String _workflowWorkspaceUrl(String? spaceId) => spaceId == null
      ? '$baseUrl/user/workflow-workspace'
      : '$baseUrl/spaces/${Uri.encodeComponent(spaceId)}/workflow-workspace';
  Future<AxWorkflowWorkspaceSettings> loadWorkflowWorkspace(
          {String? spaceId}) async =>
      AxWorkflowWorkspaceSettings.fromJson(
          await _getJson(Uri.parse(_workflowWorkspaceUrl(spaceId))));
  Future<AxWorkflowWorkspaceSettings> selectWorkflowWorkspace(
      {String? spaceId, String? workspaceId, bool inherit = false}) async {
    final response = await client.put(Uri.parse(_workflowWorkspaceUrl(spaceId)),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode({
          'workspaceId': workspaceId,
          'inherit': inherit,
          'confirmReset': true
        }));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Workspace selection failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode);
    }
    return AxWorkflowWorkspaceSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(response.body) as Map));
  }

  String _additionalFoldersUrl(String spaceId) =>
      '$baseUrl/spaces/${Uri.encodeComponent(spaceId)}/additional-folders';

  Future<AxSpaceAdditionalFolders> loadSpaceAdditionalFolders(
          String spaceId) async =>
      AxSpaceAdditionalFolders.fromJson(
          await _getJson(Uri.parse(_additionalFoldersUrl(spaceId))));

  Future<AxSpaceAdditionalFolders> saveSpaceAdditionalFolders(
      String spaceId, List<String> folderIds) async {
    final response = await client.put(Uri.parse(_additionalFoldersUrl(spaceId)),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode({'folderIds': folderIds}));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Folder update failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode);
    }
    return AxSpaceAdditionalFolders.fromJson(
        Map<String, dynamic>.from(jsonDecode(response.body) as Map));
  }

  String _memberAccessUrl(String workspaceId) =>
      '$baseUrl/workspaces/${Uri.encodeComponent(workspaceId)}/member-access';

  Future<AxWorkspaceMemberAccess> loadWorkspaceMemberAccess(
          String workspaceId) async =>
      AxWorkspaceMemberAccess.fromJson(
          await _getJson(Uri.parse(_memberAccessUrl(workspaceId))));

  Future<AxWorkspaceMemberAccess> saveWorkspaceMemberAccess(
      String workspaceId, AxWorkspaceMemberAccess access) async {
    final response = await client.put(Uri.parse(_memberAccessUrl(workspaceId)),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode(access.toJson()));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Member access update failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode);
    }
    return AxWorkspaceMemberAccess.fromJson(
        Map<String, dynamic>.from(jsonDecode(response.body) as Map));
  }

  Uri _personAccessUri(String workspaceId, String userId) => Uri.parse(
      '${_memberAccessUrl(workspaceId)}/people/${Uri.encodeComponent(userId)}');

  AxPersonAccess _personAccessResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Person access failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode);
    }
    return AxPersonAccess.fromJson(
        Map<String, dynamic>.from(jsonDecode(response.body) as Map));
  }

  Future<AxPersonAccess> loadPersonAccess(
          String workspaceId, String userId) async =>
      AxPersonAccess.fromJson(
          await _getJson(_personAccessUri(workspaceId, userId)));

  Future<AxPersonAccess> savePersonAccess(String workspaceId, String userId,
          AxWorkspaceMemberAccess access) async =>
      _personAccessResponse(
          await client.put(_personAccessUri(workspaceId, userId),
              headers: _headers(contentType: 'application/json'),
              body: jsonEncode({
                if (access.mode != null) 'mode': access.mode,
                'workers': {
                  for (final entry in access.workers.entries)
                    entry.key: entry.value.toJson(),
                },
              })));

  Future<AxPersonAccess> resetPersonAccess(
          String workspaceId, String userId) async =>
      _personAccessResponse(await client
          .delete(_personAccessUri(workspaceId, userId), headers: _headers()));

  Future<void> _sharingSend(String method, String path,
      [Object? body, String? idempotencyKey]) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = {
      ..._headers(contentType: 'application/json'),
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    };
    Future<http.Response> send() => method == 'PUT'
        ? client.put(uri, headers: headers, body: jsonEncode(body))
        : client.post(uri,
            headers: headers, body: body == null ? null : jsonEncode(body));
    final response = await _retryOnceWithKey(idempotencyKey, send);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      Object? error;
      try {
        error = jsonDecode(response.body);
      } on FormatException {
        error = null;
      }
      if (error is Map && error['code'] is String && error['error'] is String) {
        throw AxApiException(error['error'] as String,
            statusCode: response.statusCode, code: error['code'] as String);
      }
      throw AxApiException(
          'Sharing request failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode);
    }
  }

  String _workspacePath(String workspaceId) =>
      '/workspaces/${Uri.encodeComponent(workspaceId)}';

  Future<List<AxPersonWithAccess>> loadPeopleWithAccess(
      String workspaceId) async {
    final body = await _getJson(
        Uri.parse('$baseUrl${_workspacePath(workspaceId)}/people-with-access'));
    return [
      for (final item in (body['people'] as List? ?? const []))
        AxPersonWithAccess.fromJson(Map<String, dynamic>.from(item as Map)),
    ];
  }

  Future<List<AxSharedWorkspaceInvitation>> loadSharedWorkspaceInvitations(
      String workspaceId) async {
    final body = await _getJson(
        Uri.parse('$baseUrl${_workspacePath(workspaceId)}/invitations'));
    return [
      for (final item in (body['invitations'] as List? ?? const []))
        AxSharedWorkspaceInvitation.fromJson(
            Map<String, dynamic>.from(item as Map)),
    ];
  }

  Future<void> createWorkspaceInvitation(String workspaceId, String email) =>
      _sharingSend('POST', '${_workspacePath(workspaceId)}/invitations',
          {'email': email}, newAxIdempotencyKey());

  Future<void> revokeWorkspaceInvitation(
          String workspaceId, String invitationId) =>
      _sharingSend('POST',
          '${_workspacePath(workspaceId)}/invitations/${Uri.encodeComponent(invitationId)}/revoke');

  Future<void> revokePersonGrant(String workspaceId, String userId) => _sharingSend(
      'POST',
      '${_workspacePath(workspaceId)}/person-grants/${Uri.encodeComponent(userId)}/revoke');

  Future<void> setPersonQuota(String workspaceId, String userId, int limit) =>
      _sharingSend(
          'PUT',
          '${_workspacePath(workspaceId)}/person-grants/${Uri.encodeComponent(userId)}/quota',
          {'maxConcurrentRequests': limit});

  Future<void> setPersonRunTimeLimit(
          String workspaceId, String userId, int? seconds) =>
      _sharingSend(
          'PUT',
          '${_workspacePath(workspaceId)}/person-grants/${Uri.encodeComponent(userId)}/quota',
          {'maxRunSecondsPerMonth': seconds});

  Future<List<AxMyWorkspaceInvitation>> loadMyWorkspaceInvitations() async {
    final body = await _getJson(Uri.parse('$baseUrl/workspace-invitations'));
    return [
      for (final item in (body['invitations'] as List? ?? const []))
        AxMyWorkspaceInvitation.fromJson(
            Map<String, dynamic>.from(item as Map)),
    ];
  }

  Future<void> acceptWorkspaceInvitation(String invitationId) => _sharingSend(
      'POST',
      '/workspace-invitations/${Uri.encodeComponent(invitationId)}/accept');

  Future<void> declineWorkspaceInvitation(String invitationId) => _sharingSend(
      'POST',
      '/workspace-invitations/${Uri.encodeComponent(invitationId)}/decline');

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
