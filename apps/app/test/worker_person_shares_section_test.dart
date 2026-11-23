import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/ax_people.dart';
import 'package:syntila_app/src/features/workspace/worker_person_shares_section.dart';
import 'package:syntila_protocol/syntila_protocol.dart';

class _Source implements AxWorkerPersonShareSource, AxPeopleDataSource {
  final shares = <String, AxWorkerPersonShare>{};

  List<AxWorkerPersonShare> get _list => shares.values.toList();

  @override
  Future<List<AxWorkerPersonShare>> loadWorkerPersonShares(
          String workerId) async =>
      _list;

  @override
  Future<List<AxWorkerPersonShare>> saveWorkerPersonShare(
      String workerId, AxWorkerPersonShare share) async {
    shares[share.userId] = AxWorkerPersonShare(
      userId: share.userId,
      displayName: 'Bob',
      email: 'bob@example.test',
      maxConcurrentRequests: share.maxConcurrentRequests,
      maxRunSecondsPerMonth: share.maxRunSecondsPerMonth,
    );
    return _list;
  }

  @override
  Future<List<AxWorkerPersonShare>> removeWorkerPersonShare(
      String workerId, String userId) async {
    shares.remove(userId);
    return _list;
  }

  @override
  Future<List<AxPerson>> loadPeople() async => [
        AxPerson(
          userId: 'bob',
          displayName: 'Bob',
          email: 'bob@example.test',
          establishedAt: '2026-01-01T00:00:00Z',
          sharedSpaceCount: 0,
        ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _worker = WorkerInstance(
  id: 'wrk-1',
  actorId: 'actor-worker-wrk-1',
  workerTypeId: 'gemini',
  workerTypeName: 'Gemini',
  name: 'Gemini',
  description: '',
  enabled: true,
  online: true,
  paired: true,
  ready: true,
  readinessKnown: true,
  createdAt: '2026-11-22T00:00:00Z',
  updatedAt: '2026-11-22T00:00:00Z',
);

void main() {
  testWidgets('the owner shares a Worker with a person, with limits, and stops',
      (tester) async {
    final source = _Source();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkerPersonSharesSection(
              worker: _worker, shares: source, people: source),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Not shared with anyone.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('worker-person-share-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('worker-person-share-person')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bob (bob@example.test)').last);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('worker-person-share-hours')), '2');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('worker-person-share-save')));
    await tester.pumpAndSettle();

    expect(source.shares['bob']?.maxConcurrentRequests, 1);
    expect(source.shares['bob']?.maxRunSecondsPerMonth, 7200);
    expect(find.text('1 at a time · 2 h a month'), findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey('worker-person-share-remove-bob')));
    await tester.pumpAndSettle();
    expect(source.shares, isEmpty);
    expect(find.text('Not shared with anyone.'), findsOneWidget);
  });
}
