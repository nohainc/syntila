import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'dart:convert';

void main() {
  test('authenticated transport reads, replaces and resets typed preferences',
      () async {
    final configuration = AxUserWorkflowConfiguration(workflowId: 'chat');
    final methods = <String>[];
    final api = AxApiClient(
        baseUrl: 'https://cloud.test/api',
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer session');
          methods.add(request.method);
          if (request.method == 'GET') {
            return http.Response(
                jsonEncode({
                  'schemaVersion': 1,
                  'defaultWorkflowId': 'chat',
                  'configurations': [configuration.toJson()]
                }),
                200);
          }
          expect(request.url.path, '/api/user/workflow-configurations/chat');
          if (request.method == 'PUT') {
            expect(jsonDecode(request.body), configuration.toJson());
          }
          return http.Response(
              jsonEncode({'configuration': configuration.toJson()}), 200);
        }))
      ..sessionToken = 'session';
    expect((await api.loadWorkflowConfigurations()).single.workflowId, 'chat');
    expect(
        (await api.saveWorkflowConfiguration(configuration)).enabled, isTrue);
    expect((await api.resetWorkflowConfiguration('chat')).defaults.toJson(),
        isEmpty);
    expect(methods, ['GET', 'PUT', 'DELETE']);
  });
  test('Auto is omitted and step choices inherit defaults without copying them',
      () {
    final configuration = AxUserWorkflowConfiguration(
        workflowId: 'plan_implement',
        defaults: const AxWorkflowSelection(worker: 'offline', model: 'm'),
        stepOverrides: {'verify': const AxWorkflowSelection(effort: 'high')});
    final restored =
        AxUserWorkflowConfiguration.fromJson(configuration.toJson());
    expect(restored.selectionFor('verify').worker, 'offline');
    expect(restored.selectionFor('verify').effort, 'high');
    expect(restored.stepOverrides['verify']!.toJson(), {'effort': 'high'});
    expect(const AxWorkflowSelection().toJson(), isEmpty);
    expect(() => restored.stepOverrides.clear(), throwsUnsupportedError);
  });
}
