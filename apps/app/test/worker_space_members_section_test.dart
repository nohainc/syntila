import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/workspace/worker_space_members_section.dart';
import 'package:syntila_protocol/syntila_protocol.dart';

AxWorkerSpaceMemberAccess _member(String id, String name,
        {String role = 'collaborator',
        bool enabled = false,
        String mode = 'chat'}) =>
    AxWorkerSpaceMemberAccess(
        userId: id,
        displayName: name,
        email: '$id@example.test',
        role: role,
        enabled: enabled,
        mode: mode);

class _Source implements AxWorkerManagementSource {
  final saves = <({String spaceId, List<AxWorkerSpaceMemberAccess> members})>[];
  List<AxWorkerSpaceMemberAccess> stored = [
    _member('owner', 'Owner', role: 'owner'),
    _member('ann', 'Ann'),
    _member('bob', 'Bob'),
  ];

  @override
  Future<AxWorkerSpaceAccess> loadWorkerSpaceAccess(
          String workerId, String spaceId) async =>
      AxWorkerSpaceAccess(
          workerId: workerId, spaceId: spaceId, members: stored);

  @override
  Future<AxWorkerSpaceAccess> saveWorkerSpaceAccess(String workerId,
      String spaceId, List<AxWorkerSpaceMemberAccess> members) async {
    saves.add((spaceId: spaceId, members: members));
    stored = [
      for (final m in stored)
        members.where((s) => s.userId == m.userId).firstOrNull ??
            m.copyWith(enabled: false)
    ];
    return AxWorkerSpaceAccess(
        workerId: workerId, spaceId: spaceId, members: stored);
  }

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

const _space =
    AxSpace(id: 'sp-1', name: 'Syntila Work', branch: '', lastActivity: '');

void main() {
  testWidgets('the owner shares a Worker with a Space member and saves it',
      (tester) async {
    final source = _Source();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkerSpaceMembersSection(
            worker: _worker,
            management: source,
            spaces: const [_space],
            currentUserId: 'owner',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The owner never needs access and is not listed.
    expect(find.text('Owner'), findsNothing);
    expect(find.text('Ann'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('worker-space-member-ann')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('worker-space-member-mode-ann')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Work').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('worker-space-members-save')));
    await tester.pumpAndSettle();

    expect(source.saves, hasLength(1));
    expect(source.saves.single.spaceId, 'sp-1');
    expect(source.saves.single.members.map((m) => (m.userId, m.mode)),
        [('ann', 'work')]);
    final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('worker-space-members-save')));
    expect(save.onPressed, isNull);
  });

  testWidgets('without a shared Space it says how to share', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WorkerSpaceMembersSection(
            worker: _worker, management: _Source(), spaces: const []),
      ),
    ));
    expect(find.textContaining('Invite people to a Space'), findsOneWidget);
  });
}
