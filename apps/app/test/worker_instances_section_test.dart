import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syntila_app/src/features/workspace/worker_instances_section.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/sync/ax_session_catalogs.dart';
import 'package:syntila_protocol/syntila_protocol.dart';

void main() {
  test('pairing code addresses the configured backend and selected Worker',
      () async {
    final api = AxApiClient(
        baseUrl: 'https://auth.example/api',
        backendBaseUrl: 'https://backend.example/api',
        client: MockClient((request) async {
          if (request.url.path == '/api/backend-token') {
            return http.Response('{}', 401);
          }
          expect(request.method, 'POST');
          expect(request.url.path, '/api/workers/worker-1/pairing');
          return http.Response(
              jsonEncode({
                'challenge': {
                  'challengeId': 'challenge',
                  'secret': 'secret',
                  'workerId': 'worker-1'
                }
              }),
              201);
        }));
    final code = await api.pairWorkerInstance('worker-1');
    expect(code, startsWith('syntila-pair:v1:'));
    final payload = code.substring('syntila-pair:v1:'.length);
    expect(
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload)))),
        {
          's': 'https://backend.example',
          'w': 'worker-1',
          'c': 'challenge',
          'k': 'secret'
        });
  });
  testWidgets('only loads and shows Workers when the identity flag is enabled',
      (tester) async {
    final source = _IdentitySource(false);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: WorkerInstancesSection(catalogs: AxSessionCatalogs(source)),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Workers'), findsNothing);
    expect(source.loads, 0);

    final enabled = _IdentitySource(true);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: WorkerInstancesSection(
          key: const ValueKey('enabled'), catalogs: AxSessionCatalogs(enabled)),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Workers'), findsOneWidget);
    expect(find.text('No Workers yet.'), findsOneWidget);
    expect(enabled.loads, 1);
  });

  testWidgets('distinguishes same-name Workers and unknown readiness',
      (tester) async {
    WorkerInstance worker(String id, bool known) => WorkerInstance(
          id: id,
          actorId: 'actor-$id',
          workerTypeId: 'type',
          workerTypeName: 'Type',
          name: 'Writer',
          description: id == 'worker-abcdefgh' ? 'Laptop' : '',
          enabled: true,
          online: true,
          ready: false,
          readinessKnown: known,
          createdAt: '2026-01-01',
          updatedAt: '2026-01-01',
        );
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WorkerInstancesList(
      workers: [
        worker('worker-abcdefgh', false),
        worker('worker-ijklmnop', true)
      ],
      error: null,
      onRefresh: () async => null,
    ))));
    expect(find.text('Writer'), findsNWidgets(2));
    expect(
        find.textContaining(
            'Laptop · Enabled · Online · Readiness unknown · abcdefgh'),
        findsOneWidget);
    expect(find.textContaining('Not ready · ijklmnop'), findsOneWidget);
  });

  testWidgets('adds a Worker from the server Type list', (tester) async {
    final source = _ManagementSource();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WorkerInstancesList(
                workers: const [],
                error: null,
                onRefresh: () async => null,
                management: source))));
    await tester.tap(find.text('Add Worker'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'My Worker');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(source.created, [('type', 'My Worker')]);
  });

  testWidgets('renames, disables and confirms removal by Worker ID',
      (tester) async {
    final source = _ManagementSource();
    const worker = WorkerInstance(
        id: 'worker-12345678',
        actorId: 'actor',
        workerTypeId: 'type',
        workerTypeName: 'Type',
        name: 'Writer',
        description: '',
        enabled: true,
        online: false,
        ready: false,
        createdAt: 'now',
        updatedAt: 'now');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WorkerInstancesList(
                workers: [worker],
                error: null,
                onRefresh: () async => null,
                management: source))));
    await tester.tap(find.byTooltip('Manage Writer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Renamed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(source.updates.single.$1, 'worker-12345678');
    expect(source.updates.single.$2, {'name': 'Renamed'});
    await tester.tap(find.byTooltip('Manage Writer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disable'));
    await tester.pumpAndSettle();
    expect(source.updates.last.$1, 'worker-12345678');
    expect(source.updates.last.$2, {'enabled': false});
    await tester.tap(find.byTooltip('Manage Writer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(source.removed, isEmpty);
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    expect(source.removed, ['worker-12345678']);
  });
}

class _ManagementSource implements AxWorkerManagementSource {
  final updates = <(String, Map<String, Object?>)>[];
  final removed = <String>[];
  final created = <(String, String)>[];
  @override
  Future<List<({String id, String name})>> loadWorkerTypes() async =>
      [(id: 'type', name: 'Type')];
  @override
  Future<void> createWorkerInstance(String typeId, String name) async =>
      created.add((typeId, name));
  @override
  Future<String> pairWorkerInstance(String id) async => 'pairing-code';
  @override
  Future<void> revokeWorkerCredential(String id) async {}
  @override
  Future<void> updateWorkerInstance(
          String id, Map<String, Object?> changes) async =>
      updates.add((id, changes));
  @override
  Future<void> removeWorkerInstance(String id) async => removed.add(id);
}

class _IdentitySource implements AxDataSource, AxWorkerIdentityFeatureSource {
  _IdentitySource(this.enabled);
  final bool enabled;
  int loads = 0;
  @override
  Future<bool> workerIdentityEnabled() async => enabled;
  @override
  Future<List<WorkerInstance>> loadWorkerInstances() async {
    loads++;
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
