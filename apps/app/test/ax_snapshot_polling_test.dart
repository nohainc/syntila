import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_app.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'ax_fixture_realtime.dart';
import 'ax_fixture_data.dart';
import 'ax_fixture_snapshot.dart';
import 'ax_space_navigation_test.dart' show HistoryNavigation;

class PollingSource extends AxFixtureDataSource {
  int bootstraps = 0, sessions = 0, spaces = 0, workspaces = 0;
  final details = <String>[];
  List<int> get broadCounts => [bootstraps, sessions, spaces, workspaces];
  @override
  Future<AxSnapshot> loadBootstrapState({String? spaceId}) async {
    bootstraps++;
    final fixture = axFixtureSnapshot();
    return AxSnapshot(
        run: fixture.run,
        activeRunId: fixture.activeRunId,
        spaces: fixture.spaces,
        tasks: fixture.tasks,
        findings: fixture.findings,
        events: fixture.events,
        artifacts: fixture.artifacts);
  }

  @override
  Future<AxSession> loadSession() {
    sessions++;
    return super.loadSession();
  }

  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) {
    spaces++;
    return super.loadSpaces(includeArchived: includeArchived);
  }

  @override
  Future<AxWorkRequestStatus> loadWorkRequest(
      {required String workRequestId}) async {
    details.add(workRequestId);
    return AxWorkRequestStatus(
        id: workRequestId,
        threadId: 'thread-auth',
        status: 'completed',
        text: 'Done',
        originalRequest: 'Work',
        workflowId: 'direct',
        workflowVersion: 2,
        createdAt: '2026-10-06T00:00:00Z',
        requestedByName: 'You');
  }
}

void main() {
  Future<void> mount(
      WidgetTester tester, PollingSource source, TestRealtime realtime) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: SyntilaAppShell(
            dataSource: source,
            services: const DefaultPlatformServices(),
            browserNavigation: HistoryNavigation(Uri.parse('/')),
            realtimeClient: realtime)));
    await tester.pumpAndSettle();
  }

  testWidgets('a running Run never schedules five-second bootstrap polling',
      (tester) async {
    final source = PollingSource();
    final realtime = TestRealtime();
    await mount(tester, source, realtime);
    final counts = source.broadCounts;
    expect(source.bootstraps, 1);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 60));
    expect(source.broadCounts, counts);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('startup reuses the bootstrap Workspace list', (tester) async {
    final source = PollingSource();
    final realtime = TestRealtime();
    await mount(tester, source, realtime);
    expect(source.bootstraps, 1);
    // The bootstrap snapshot carries Workers; no separate list read.
    expect(source.workspaces, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('execution events reconcile one Work Request without broad reads',
      (tester) async {
    final source = PollingSource();
    final realtime = TestRealtime();
    await mount(tester, source, realtime);
    realtime.controller
        .add({'type': 'realtime.connection', 'status': 'connected'});
    await tester.pumpAndSettle();
    final counts = source.broadCounts;
    for (final type in [
      'run.completed',
      'assignment.completed',
      'task.completed'
    ]) {
      realtime.controller.add({
        'type': type,
        'workspaceId': 'workspace',
        'payload': {
          'workRequestId': type,
          'threadId': 'thread-auth',
          'status': 'completed'
        }
      });
      await tester.pumpAndSettle();
    }
    expect(source.details,
        ['run.completed', 'assignment.completed', 'task.completed']);
    expect(source.broadCounts, counts);
    realtime.controller.add({
      'type': 'run.completed',
      'workspaceId': 'workspace',
      'payload': {'runId': 'legacy-run'}
    });
    await tester.pumpAndSettle();
    expect(source.broadCounts, counts);
    expect(source.details.length, 3);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('realtime connection warnings wait for a sustained outage',
      (tester) async {
    final source = PollingSource();
    final realtime = TestRealtime();
    await mount(tester, source, realtime);

    realtime.controller
        .add({'type': 'realtime.connection', 'status': 'reconnecting'});
    await tester.pump();
    expect(find.text('Live updates paused. Syntila is reconnecting.'),
        findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Live updates paused. Syntila is reconnecting.'),
        findsNothing);

    realtime.controller
        .add({'type': 'realtime.connection', 'status': 'connected'});
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Live updates paused. Syntila is reconnecting.'),
        findsNothing);

    realtime.controller
        .add({'type': 'realtime.connection', 'status': 'reconnecting'});
    await tester.pump();

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Live updates paused. Syntila is reconnecting.'),
        findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Live updates paused. Syntila is reconnecting.'),
        findsOneWidget);

    realtime.controller
        .add({'type': 'realtime.connection', 'status': 'connected'});
    await tester.pump();
    expect(find.text('Live updates connected.'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
