import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/ax_stores.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'ax_fixture_data.dart';

AxSpace space(String id, String name) =>
    AxSpace.fromJson({'id': id, 'name': name});
AxThread stream(String id, String name) =>
    AxThread.fromJson({'id': id, 'spaceId': 'P', 'name': name});

class CollaborationSource extends AxFixtureDataSource {
  final creates = <Completer<AxSpace>>[];
  final spaceEdits = <Completer<AxSpace>>[];
  final streamCreates = <Completer<AxThread>>[];
  final streamEdits = <Completer<AxThread>>[];
  final deletes = <Completer<void>>[];
  final acceptInvites = <Completer<void>>[];
  final declineInvites = <Completer<void>>[];
  @override
  Future<void> acceptSpaceInvitation({required String invitationId}) {
    final response = Completer<void>();
    acceptInvites.add(response);
    return response.future;
  }

  @override
  Future<void> declineSpaceInvitation({required String invitationId}) {
    final response = Completer<void>();
    declineInvites.add(response);
    return response.future;
  }

  @override
  Future<AxSpace> createSpace(
      {required String name, String? description, String? instructions}) {
    final response = Completer<AxSpace>();
    creates.add(response);
    return response.future;
  }

  @override
  Future<AxSpace> updateSpace(
      {required String spaceId,
      String? name,
      String? description,
      String? instructions,
      Map<String, dynamic>? settings}) {
    final response = Completer<AxSpace>();
    spaceEdits.add(response);
    return response.future;
  }

  @override
  Future<AxThread> createThread(
      {required String spaceId, required String name, String? idempotencyKey}) {
    final response = Completer<AxThread>();
    streamCreates.add(response);
    return response.future;
  }

  @override
  Future<AxThread> updateThread(
      {required String threadId,
      String? name,
      String? status,
      Map<String, dynamic>? workConfig,
      Map<String, dynamic>? metadata}) {
    final response = Completer<AxThread>();
    streamEdits.add(response);
    return response.future;
  }

  @override
  Future<void> deleteThread({required String threadId}) {
    final response = Completer<void>();
    deletes.add(response);
    return response.future;
  }

  @override
  Future<String?> clearThreadWorkHistory({required String threadId}) async =>
      DateTime.now().toUtc().toIso8601String();
}

void main() {
  late CollaborationSource source;
  late AxStore store;
  setUp(() {
    source = CollaborationSource();
    store = AxStore(source);
    store.spaces.replace([space('P', 'Original'), space('Q', 'Other')]);
    store.syncEngine
        .update(store.spaceDetails.query('P'), (_) => store.spaces.items.first);
    store.syncEngine.update(store.spaceThreads.query('P'),
        (_) => [stream('A', 'Alpha'), stream('B', 'Beta')]);
  });

  test(
      'Space create publishes immediately, replaces temporary ID, and records details',
      () async {
    final write = store.collaboration.createSpace(name: 'New');
    final temporary = store.spaces.items.last;
    expect(temporary.name, 'New');
    expect(temporary.id, startsWith('local-space-'));
    source.creates.single.complete(space('new', 'Normalized'));
    expect((await write).id, 'new');
    expect(store.spaces.items.map((p) => p.id), ['P', 'Q', 'new']);
    expect(store.spaceDetails.peek('new')?.name, 'Normalized');
  });

  test('one failed Space create cannot remove another confirmed create',
      () async {
    final first = store.collaboration.createSpace(name: 'Failed');
    final check = expectLater(first, throwsStateError);
    final second = store.collaboration.createSpace(name: 'Saved');
    source.creates[1].complete(space('new', 'Saved'));
    await second;
    source.creates[0].completeError(StateError('denied'));
    await check;
    expect(
        store.spaces.items.map((p) => p.name), ['Original', 'Other', 'Saved']);
  });

  test(
      'Space edit updates list and detail optimistically and reconciles server fields',
      () async {
    final write = store.collaboration.editSpace(store.spaces.items.first,
        name: 'Optimistic', instructions: 'New instructions');
    expect(store.spaces.items.first.name, 'Optimistic');
    expect(store.spaceDetails.peek('P')?.instructions, 'New instructions');
    source.spaceEdits.single.complete(space('P', 'Normalized')
        .copyWith(instructions: 'Normalized instructions'));
    await write;
    expect(store.spaces.items.first.name, 'Normalized');
    expect(
        store.spaceDetails.peek('P')?.instructions, 'Normalized instructions');
  });

  test('Space edit response keeps the pin and indicators already in the list',
      () async {
    store.spaces.replace([
      store.spaces.items.first.copyWith(
          pinnedAt: '2026-10-01T00:00:00Z', pinPosition: -3, hasUnread: true),
      ...store.spaces.items.skip(1),
    ]);
    final write = store.collaboration.editSpace(store.spaces.items.first,
        settings: {'sidebarExpanded': false});
    // The edit response carries no per-user state.
    source.spaceEdits.single.complete(space('P', 'Original'));
    await write;
    expect(store.spaces.items.first.isPinned, isTrue);
    expect(store.spaces.items.first.pinPosition, -3);
    expect(store.spaces.items.first.hasUnread, isTrue);
  });

  test(
      'failed Space edit restores latest realtime base and preserves other Space edits',
      () async {
    final original = store.spaces.items.first;
    final write = store.collaboration.editSpace(original, name: 'Pending');
    final check = expectLater(write, throwsStateError);
    final latest =
        original.copyWith(name: 'Remote', description: 'Remote description');
    store.syncEngine.update(store.spaceDetails.query('P'), (_) => latest);
    store.spaces.replace([latest, space('Q', 'Remote Q')]);
    expect(store.spaceDetails.peek('P')?.name, 'Pending');
    expect(store.spaceDetails.peek('P')?.description, 'Remote description');
    expect(store.spaces.items.first.description, 'Remote description');
    source.spaceEdits.single.completeError(StateError('denied'));
    await check;
    expect(store.spaceDetails.peek('P')?.name, 'Remote');
    expect(store.spaces.items.map((p) => p.name), ['Remote', 'Remote Q']);
  });

  test('second write to the same Space is rejected before issuing HTTP',
      () async {
    final original = store.spaces.items.first;
    final first = store.collaboration.editSpace(original, name: 'First');
    await expectLater(
        store.collaboration.editSpace(original, name: 'Duplicate'),
        throwsStateError);
    expect(source.spaceEdits.length, 1);
    source.spaceEdits.single.complete(original.copyWith(name: 'First'));
    await first;
  });

  test('Thread create failure retains another create and collection ordering',
      () async {
    final first =
        store.collaboration.createThread(spaceId: 'P', name: 'Failed');
    final check = expectLater(first, throwsStateError);
    final second =
        store.collaboration.createThread(spaceId: 'P', name: 'Saved');
    expect(store.spaceThreads.peek('P').map((w) => w.name),
        ['Alpha', 'Beta', 'Failed', 'Saved']);
    source.streamCreates[1].complete(stream('C', 'Saved'));
    await second;
    source.streamCreates[0].completeError(StateError('denied'));
    await check;
    expect(store.spaceThreads.peek('P').map((w) => w.id), ['A', 'B', 'C']);
  });

  test('Thread view state edits preserve pins and manual order', () async {
    final threads = store.spaceThreads.peek('P');
    store.syncEngine.update(
        store.spaceThreads.query('P'),
        (_) => [
              threads[0]
                  .copyWith(pinnedAt: '2026-10-01T00:00:00Z', pinPosition: -3),
              threads[1]
                  .copyWith(pinnedAt: '2026-10-02T00:00:00Z', pinPosition: -2),
            ]);
    for (final id in ['A', 'B', 'A']) {
      final current =
          store.spaceThreads.peek('P').firstWhere((t) => t.id == id);
      final write = store.collaboration
          .editThread(current, viewState: {'selected': true});
      source.streamEdits.last.complete(stream(id, current.name));
      await write;
      expect(applyAxThreadPins(store.spaceThreads.peek('P')).map((t) => t.id),
          ['A', 'B']);
    }
    expect(store.spaceThreads.peek('P').first.pinPosition, -3);
  });

  test('Thread edits preserve position and unrelated realtime entities',
      () async {
    final original = store.spaceThreads.peek('P').first;
    final write = store.collaboration.editThread(original, name: 'Pending');
    store.syncEngine.update(
        store.spaceThreads.query('P'),
        (_) => [
              original,
              stream('B', 'Remote Beta'),
              stream('C', 'Remote Gamma')
            ]);
    expect(store.spaceThreads.peek('P').map((w) => w.name),
        ['Pending', 'Remote Beta', 'Remote Gamma']);
    source.streamEdits.single.complete(original.copyWith(name: 'Normalized'));
    await write;
    expect(store.spaceThreads.peek('P').map((w) => w.name),
        ['Normalized', 'Remote Beta', 'Remote Gamma']);
  });

  test('failed Thread delete restores only the removed entity from latest base',
      () async {
    final original = store.spaceThreads.peek('P').first;
    final write = store.collaboration.deleteThread(original);
    final check = expectLater(write, throwsStateError);
    expect(store.spaceThreads.peek('P').map((w) => w.id), ['B']);
    store.syncEngine.update(store.spaceThreads.query('P'),
        (_) => [original, stream('B', 'Remote Beta')]);
    source.deletes.single.completeError(StateError('denied'));
    await check;
    expect(store.spaceThreads.peek('P').map((w) => w.name),
        ['Alpha', 'Remote Beta']);
  });

  test('confirmed Thread delete removes its dependent queries', () async {
    final key = AxQueryKey(['thread', 'A', 'discussion']);
    final dependent = AxQuery<int>(key: key, load: () async => 1);
    store.syncEngine.update(dependent, (_) => 1);
    final write =
        store.collaboration.deleteThread(store.spaceThreads.peek('P').first);
    source.deletes.single.complete();
    await write;
    expect(store.syncEngine.peek(dependent).hasData, isFalse);
    expect(store.spaceThreads.peek('P').map((w) => w.id), ['B']);
  });

  test(
      'wrong response identity rolls back rather than corrupting another Space',
      () async {
    final write = store.collaboration
        .editThread(store.spaceThreads.peek('P').first, name: 'Pending');
    final check = expectLater(write, throwsA(isA<Exception>()));
    source.streamEdits.single.complete(
        AxThread.fromJson({'id': 'A', 'spaceId': 'Q', 'name': 'Wrong'}));
    await check;
    expect(store.spaceThreads.peek('P').first.name, 'Alpha');
  });

  test(
      'session clear fences Space and Thread writes and releases temporary rows',
      () async {
    final spaceWrite = store.collaboration.createSpace(name: 'Pending');
    final streamWrite =
        store.collaboration.createThread(spaceId: 'P', name: 'Pending');
    final checks = Future.wait([
      expectLater(spaceWrite, throwsA(isA<AxMutationSuperseded>())),
      expectLater(streamWrite, throwsA(isA<AxMutationSuperseded>())),
    ]);
    store.clearServerState();
    source.creates.single.complete(space('late', 'Late'));
    source.streamCreates.single.complete(stream('late', 'Late'));
    await checks;
    expect(store.spaces.items, isEmpty);
    expect(store.spaceThreads.peek('P'), isEmpty);
    expect(store.spaceDetails.peek('late'), isNull);
  });

  test(
      'Space removal cancels the remaining list overlay without resurrecting a deleted Space',
      () async {
    final write = store.collaboration
        .editSpace(store.spaces.items.first, name: 'Pending');
    final check = expectLater(write, throwsA(isA<AxMutationSuperseded>()));
    store.syncEngine.remove(store.spaceDetails.query('P').key);
    store.spaces.replace([space('Q', 'Other')]);
    expect(store.spaces.items.map((p) => p.id), ['Q']);
    source.spaceEdits.single.complete(space('P', 'Late'));
    await check;
    expect(store.spaces.items.map((p) => p.id), ['Q']);
  });

  test(
      'acceptInvitation removes invitation immediately, adds space optimistically, and confirms on server completion',
      () async {
    final invite = AxSpaceInvitation(
      id: 'inv-1',
      spaceId: 'proj-new',
      spaceName: 'Alpha Space',
      email: 'user@example.com',
      role: 'member',
      status: 'pending',
      invitedByUserId: 'u-1',
      createdAt: DateTime.now().toIso8601String(),
    );
    store.invitations.replace([invite]);
    expect(store.invitations.items.map((i) => i.id), ['inv-1']);
    expect(store.spaces.items.map((p) => p.id), ['P', 'Q']);

    final write = store.collaboration.acceptInvitation(invite);

    // Optimistic state
    expect(store.invitations.items, isEmpty);
    expect(store.spaces.items.map((p) => p.id), ['P', 'Q', 'proj-new']);
    expect(store.spaces.items.last.name, 'Alpha Space');

    // Complete server write
    source.acceptInvites.single.complete();
    await write;

    expect(store.invitations.items, isEmpty);
    expect(store.spaces.items.map((p) => p.id), ['P', 'Q', 'proj-new']);
  });

  test(
      'failed acceptInvitation rolls back removed invitation and optimistic space',
      () async {
    final invite = AxSpaceInvitation(
      id: 'inv-1',
      spaceId: 'proj-new',
      spaceName: 'Alpha Space',
      email: 'user@example.com',
      role: 'member',
      status: 'pending',
      invitedByUserId: 'u-1',
      createdAt: DateTime.now().toIso8601String(),
    );
    store.invitations.replace([invite]);

    final write = store.collaboration.acceptInvitation(invite);
    final check = expectLater(write, throwsA(isA<StateError>()));

    expect(store.invitations.items, isEmpty);
    expect(store.spaces.items.map((p) => p.id), ['P', 'Q', 'proj-new']);

    source.acceptInvites.single.completeError(StateError('expired'));
    await check;

    // Rolled back
    expect(store.invitations.items.map((i) => i.id), ['inv-1']);
    expect(store.spaces.items.map((p) => p.id), ['P', 'Q']);
  });

  test(
      'declineInvitation removes invitation immediately and confirms on server completion',
      () async {
    final invite = AxSpaceInvitation(
      id: 'inv-1',
      spaceId: 'proj-new',
      spaceName: 'Alpha Space',
      email: 'user@example.com',
      role: 'member',
      status: 'pending',
      invitedByUserId: 'u-1',
      createdAt: DateTime.now().toIso8601String(),
    );
    store.invitations.replace([invite]);

    final write = store.collaboration.declineInvitation(invite);
    expect(store.invitations.items, isEmpty);

    source.declineInvites.single.complete();
    await write;

    expect(store.invitations.items, isEmpty);
  });

  test('failed declineInvitation rolls back removed invitation', () async {
    final invite = AxSpaceInvitation(
      id: 'inv-1',
      spaceId: 'proj-new',
      spaceName: 'Alpha Space',
      email: 'user@example.com',
      role: 'member',
      status: 'pending',
      invitedByUserId: 'u-1',
      createdAt: DateTime.now().toIso8601String(),
    );
    store.invitations.replace([invite]);

    final write = store.collaboration.declineInvitation(invite);
    final check = expectLater(write, throwsA(isA<StateError>()));

    expect(store.invitations.items, isEmpty);

    source.declineInvites.single.completeError(StateError('forbidden'));
    await check;

    expect(store.invitations.items.map((i) => i.id), ['inv-1']);
  });
}
