part of '../ax_data.dart';

mixin _ReadModelApi on _AxApiClientCore {
  @override
  Future<AxSnapshot> loadBootstrapState(
      {String? spaceId, String? workspaceId}) async {
    final results = await Future.wait<Object>([
      loadSpaces(),
      loadWorkspaces(),
      loadSession(),
    ]);
    final spaces = results[0] as List<AxSpace>;
    final workspaces = results[1] as List<AxWorkspace>;
    final session = results[2] as AxSession;
    return AxSnapshot(
      workspaceId: workspaceId,
      viewer: session.viewer,
      spaces: spaces,
      workspaces: workspaces,
      tasks: const [],
      findings: const [],
      events: const [],
      artifacts: const [],
    );
  }

  @override
  Future<void> controlRun(String runId, String command) async {
    final response = await client
        .post(Uri.parse('$baseUrl/runs/$runId/$command'), headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Run control failed (${response.statusCode})');
    }
  }

  @override
  Future<void> respondToRunPrompt(String runId, String response) async {
    final result = await client.post(
      Uri.parse('$baseUrl/runs/$runId/events'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'type': 'run-approval',
        'payload': {'response': response},
      }),
    );
    if (result.statusCode < 200 || result.statusCode >= 300) {
      throw AxApiException('Run response failed',
          statusCode: result.statusCode);
    }
  }
}
