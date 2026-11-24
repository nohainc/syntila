import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/workers/worker_member_models_section.dart';
import 'package:syntila_protocol/syntila_protocol.dart';

class _Source implements AxWorkerManagementSource {
  _Source(this.stored, {this.failSave = false});

  AxWorkerMemberModelAccess stored;
  bool failSave;
  final saves = <AxWorkerMemberModelAccess>[];

  @override
  Future<AxWorkerMemberModelAccess> loadWorkerMemberModelAccess(
          String workerId) async =>
      stored;

  @override
  Future<AxWorkerMemberModelAccess> saveWorkerMemberModelAccess(
      String workerId, AxWorkerMemberModelAccess access) async {
    if (failSave) throw Exception('network error');
    saves.add(access);
    return stored = access;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _modelOptions = {
  'schemaVersion': 1,
  'models': {
    'supported': true,
    'discovery': 'static',
    'options': [
      {
        'id': 'm1',
        'name': 'Model One',
        'effort': {
          'supported': true,
          'values': ['low', 'high'],
        },
      },
      {
        'id': 'm2',
        'name': 'Model Two',
        'effort': {
          'supported': true,
          'values': ['low', 'high'],
        },
      },
    ],
  },
  'effort': {
    'supported': true,
    'values': ['low', 'high'],
  },
};

WorkerInstance _worker() => const WorkerInstance(
      id: 'wrk-1',
      actorId: 'actor-worker-wrk-1',
      workerTypeId: 'chatgpt',
      workerTypeName: 'ChatGPT',
      name: 'My Worker',
      description: '',
      enabled: true,
      online: true,
      paired: true,
      ready: true,
      readinessKnown: true,
      executionOptions: _modelOptions,
      createdAt: '2026-11-22T00:00:00Z',
      updatedAt: '2026-11-22T00:00:00Z',
    );

Future<void> _pump(
    WidgetTester tester, AxWorkerManagementSource? source) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: WorkerMemberModelsSection(worker: _worker(), management: source),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  const saveKey = ValueKey('worker-member-models-save');

  testWidgets('is hidden without management support', (tester) async {
    await _pump(tester, null);
    expect(find.text('Models for members'), findsNothing);
  });

  testWidgets('starts with nothing ticked, then saves what the owner ticks',
      (tester) async {
    final source = _Source(const AxWorkerMemberModelAccess());
    await _pump(tester, source);

    Checkbox box(String key) =>
        tester.widget<Checkbox>(find.byKey(ValueKey(key)));
    expect(box('worker-member-models-model-m1').value, isFalse);
    expect(box('worker-member-models-model-m2').value, isFalse);
    // Efforts only appear once their model is ticked.
    expect(find.byKey(const ValueKey('worker-member-models-effort-m1-low')),
        findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(saveKey)).onPressed, isNull);

    await tester
        .tap(find.byKey(const ValueKey('worker-member-models-model-m1')));
    await tester.pumpAndSettle();
    expect(box('worker-member-models-effort-m1-low').value, isFalse);
    await tester
        .tap(find.byKey(const ValueKey('worker-member-models-effort-m1-low')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(saveKey));
    await tester.pumpAndSettle();

    expect(source.saves.single.allowedModels, ['m1']);
    expect(source.saves.single.allowedEfforts, {
      'm1': ['low']
    });
    expect(box('worker-member-models-effort-m1-low').value, isTrue);
    expect(tester.widget<FilledButton>(find.byKey(saveKey)).onPressed, isNull);
  });

  testWidgets('shows the failure and offers Retry', (tester) async {
    final source = _Source(const AxWorkerMemberModelAccess(), failSave: true);
    await _pump(tester, source);
    await tester
        .tap(find.byKey(const ValueKey('worker-member-models-model-m1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(saveKey));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not save member models'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
