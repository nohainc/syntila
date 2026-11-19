import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/features/workspace/worker_instances_section.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/sync/ax_session_catalogs.dart';
import 'package:syntila_protocol/syntila_protocol.dart';

void main() {
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
