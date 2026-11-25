import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_stores.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'ax_fixture_data.dart';
import 'ax_fixture_snapshot.dart';

class _BootstrapSource extends AxFixtureDataSource {
  const _BootstrapSource();

  @override
  Future<AxSnapshot> loadBootstrapState({String? spaceId}) async {
    final base = axFixtureSnapshot();
    return AxSnapshot(
      viewer: const AxViewer(
          id: 'user-1', displayName: 'User One', email: 'user@example.test'),
      spaces: base.spaces,
      tasks: base.tasks,
      findings: base.findings,
      events: base.events,
      artifacts: base.artifacts,
      run: base.run,
      activeRunId: base.activeRunId,
    );
  }
}

void main() {
  group('AxStore Phase 23 facade removal and projection isolation', () {
    test(
        'loadBootstrapState initializes independent stores and strips nested threads',
        () async {
      final source = const _BootstrapSource();
      final store = AxStore(source);
      addTearDown(store.dispose);

      final bootstrap = await store.loadBootstrapState(
        spaceId: 'space-auth',
      );

      expect(bootstrap.spaces, isNotEmpty);
      for (final space in bootstrap.spaces) {
        expect(space.threads, isEmpty,
            reason: 'Bootstrap snapshot spaces must discard nested threads');
      }

      expect(store.spaces.items, isNotEmpty);
      for (final space in store.spaces.items) {
        expect(space.threads, isEmpty,
            reason: 'SpaceStore items must discard nested threads');
      }
      expect(store.auth.viewer?.id, 'user-1');
    });

    test('AxStore.execution returns immutable collections', () {
      final source = const AxFixtureDataSource();
      final store = AxStore(source);
      addTearDown(store.dispose);

      final snapshot = axFixtureSnapshot();
      store.replaceExecution(snapshot);

      final exec = store.execution;
      expect(exec.run, isNotNull);
      expect(exec.spaces, isEmpty,
          reason: 'Legacy execution projection excludes spaces');

      // Check unmodifiable list guarantees
      if (exec.tasks.isNotEmpty) {
        expect(() => (exec.tasks as dynamic).add(exec.tasks.first),
            throwsA(isA<UnsupportedError>()));
      }
      if (exec.findings.isNotEmpty) {
        expect(() => (exec.findings as dynamic).add(exec.findings.first),
            throwsA(isA<UnsupportedError>()));
      }
      if (exec.events.isNotEmpty) {
        expect(() => (exec.events as dynamic).add(exec.events.first),
            throwsA(isA<UnsupportedError>()));
      }
      if (exec.artifacts.isNotEmpty) {
        expect(() => (exec.artifacts as dynamic).add(exec.artifacts.first),
            throwsA(isA<UnsupportedError>()));
      }
      if (exec.candidateOutputs.isNotEmpty) {
        expect(
            () => (exec.candidateOutputs as dynamic)
                .add(exec.candidateOutputs.first),
            throwsA(isA<UnsupportedError>()));
      }
    });

    test(
        'replaceExecution notifies executionChanges without touching queries or session',
        () {
      final source = const AxFixtureDataSource();
      final store = AxStore(source);
      addTearDown(store.dispose);

      int executionSignals = 0;
      store.executionChanges.addListener(() {
        executionSignals++;
      });

      final snapshot = axFixtureSnapshot();
      store.replaceExecution(snapshot);

      expect(executionSignals, 1);
      expect(store.execution.run?.id, snapshot.run?.id);
      expect(store.spaces.items, isEmpty,
          reason: 'replaceExecution must not write space queries');
    });

    test(
        'collaboration mutations and query updates do not trigger executionChanges',
        () {
      final source = const AxFixtureDataSource();
      final store = AxStore(source);
      addTearDown(store.dispose);

      int executionSignals = 0;
      store.executionChanges.addListener(() {
        executionSignals++;
      });

      store.spaces.replace([
        const AxSpace(
          id: 'p1',
          name: 'P1',
          branch: 'main',
          lastActivity: 'now',
        ),
      ]);

      expect(executionSignals, 0,
          reason:
              'Query updates must not trigger execution projection signals');
      expect(store.spaces.items.length, 1);
    });

    test(
        'clearServerState resets queries, auth, security, and execution projection',
        () async {
      final source = const AxFixtureDataSource();
      final store = AxStore(source);
      addTearDown(store.dispose);

      await store.loadBootstrapState();
      expect(store.spaces.items, isNotEmpty);

      store.clearServerState();

      expect(store.spaces.items, isEmpty);
      expect(store.security.value, isNull);
      expect(store.execution.run, isNull);
      expect(store.execution.tasks, isEmpty);
      expect(store.execution.findings, isEmpty);
    });

    test('superseded or disposed bootstrap throws StateError', () async {
      final source = const AxFixtureDataSource();
      final store = AxStore(source);
      store.dispose();

      expect(() => store.loadBootstrapState(), throwsA(isA<StateError>()));
    });

    test(
        'store.acceptInvitation and declineInvitation execute through collaboration mutations',
        () async {
      final source = const AxFixtureDataSource();
      final store = AxStore(source);
      addTearDown(store.dispose);

      const invite = AxSpaceInvitation(
        id: 'inv-store-1',
        spaceId: 'proj-new-store',
        spaceName: 'New Store Space',
        email: 'user@example.com',
        role: 'member',
        status: 'pending',
        invitedByUserId: 'u-1',
        createdAt: '2026-10-07T12:00:00Z',
      );

      store.invitations.replace([invite]);
      expect(store.invitations.items.length, 1);
      expect(store.unreadNotifications.value, 1);

      await store.acceptInvitation(invite);

      expect(store.invitations.items, isEmpty);
      expect(store.unreadNotifications.value, 0);
      expect(store.spaces.items.any((p) => p.id == 'proj-new-store'), isTrue);
    });
  });
}
