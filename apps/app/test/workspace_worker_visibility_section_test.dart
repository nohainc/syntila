import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/ax/sync/ax_worker_visibility_preferences.dart';
import 'package:syntila_app/src/features/workspace/workspaces_page.dart';

class VisibilitySource implements AxDataSource, AxWorkerVisibilityDataSource {
  final values = <String, AxWorkerVisibility>{};
  bool fail = false;
  int resets = 0;
  @override
  Future<AxWorkerVisibility> loadWorkerVisibility(String id) async =>
      values[id] ?? AxWorkerVisibility();
  @override
  Future<AxWorkerVisibility> saveWorkerVisibility(
      String id, AxWorkerVisibility value) async {
    if (fail) throw StateError('save failed');
    return values[id] = value;
  }

  @override
  Future<AxWorkerVisibility> resetWorkerVisibility(String id) async {
    resets++;
    return values[id] = AxWorkerVisibility();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const worker = AxWorker(
    id: 'w',
    workspaceId: 'one',
    workspaceName: 'One',
    workerTypeId: 'type',
    displayName: 'Test worker',
    status: 'offline',
    readinessState: 'offline',
    localConcurrencyLimit: 1,
    executionOptions: AxWorkerExecutionOptions(
        modelSelectionSupported: true,
        modelDiscovery: 'static',
        allowsCustomModel: false,
        allowedModelIds: ['m'],
        models: [
          AxWorkerModelOption(
              id: 'm',
              name: 'Model',
              effort: AxWorkerEffortOptions(
                  supported: true, values: ['low', 'high']))
        ],
        modelSwitchSupported: true,
        effort: AxWorkerEffortOptions(supported: false, values: [])));
void main() {
  testWidgets('collapsed editor saves, cancels, resets and reports errors',
      (tester) async {
    final source = VisibilitySource();
    final preferences =
        AxWorkerVisibilityPreferences(source, engine: AxSyncEngine());
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkspacesPage(workspaces: [
      AxWorkspace.fromJson({'id': 'one', 'name': 'One', 'role': 'owner'})
    ], workspaceWorkers: const [
      worker
    ], workerVisibilityPreferences: preferences)))));
    expect(find.text('My Workers'), findsOneWidget);
    expect(find.byKey(const ValueKey('visibility-worker-w')), findsNothing);
    await tester.tap(find.text('My Workers'));
    await tester.pumpAndSettle();
    final workerCheckbox = find.byKey(const ValueKey('visibility-worker-w'));
    await tester.ensureVisible(workerCheckbox);
    await tester.tap(workerCheckbox);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(source.values['one']!.hiddenWorkers, ['w']);
    await tester.ensureVisible(workerCheckbox);
    await tester.tap(workerCheckbox);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(workerCheckbox).value, isFalse);
    source.fail = true;
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('save failed'), findsOneWidget);
    source.fail = false;
    await tester.ensureVisible(find.text('Reset'));
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(source.resets, 1);
    expect(source.values['one']!.hiddenWorkers, isEmpty);
    await tester.ensureVisible(workerCheckbox);
    expect(tester.widget<Checkbox>(workerCheckbox).value, isTrue);
    final modelCheckbox = find.byKey(const ValueKey('visibility-model-m-w'));
    await tester.ensureVisible(modelCheckbox);
    expect(tester.widget<Checkbox>(modelCheckbox).value, isTrue);
    final effortCheckbox =
        find.byKey(const ValueKey('visibility-effort-m-low-w'));
    await tester.ensureVisible(effortCheckbox);
    expect(tester.widget<Checkbox>(effortCheckbox).value, isTrue);
    expect(find.byKey(const ValueKey('visibility-effort-m-high-w')),
        findsOneWidget);
  });
}
