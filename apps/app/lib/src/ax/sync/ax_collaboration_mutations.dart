import 'ax_idempotency.dart';
import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_space_details.dart';
import 'ax_space_threads.dart';
import 'ax_sync_engine.dart';

/// Shared collaboration writes. Widgets own form state and notifications only.
class AxCollaborationMutations {
  AxCollaborationMutations(this.source, {required this.engine});
  final AxDataSource source;
  final AxSyncEngine engine;
  final _attempts = AxMutationAttempts();
  void clear() => _attempts.clear();
  int _nextId = 0;
  late final details = AxSpaceDetails(source, engine: engine);
  late final threads = AxSpaceThreads(source, engine: engine);
  late final spaces = AxQuery<List<AxSpace>>(
      key: AxQueryKey(['spaces']),
      load: () async => List.unmodifiable(sortAxSpacesByLastUpdate(
          (await source.loadSpaces())
              .map((s) => s.copyWith(threads: const [])))));
  late final invitations = AxQuery<List<AxSpaceInvitation>>(
      key: AxQueryKey(['me', 'invitations']),
      load: source.loadCurrentUserInvitations);

  String _temporary(String kind) =>
      'local-$kind-${DateTime.now().microsecondsSinceEpoch}-${++_nextId}';
  List<T> _put<T>(List<T> values, T value, String Function(T) id) =>
      List.unmodifiable([
        for (final item in values)
          if (id(item) != id(value)) item,
        value,
      ]);
  List<T> _replace<T>(List<T> values, T value, String Function(T) id) =>
      List.unmodifiable(values.any((item) => id(item) == id(value))
          ? values.map((item) => id(item) == id(value) ? value : item)
          : [...values, value]);

  Future<AxSpace> createSpace(
      {required String name, String? description, String? instructions}) {
    final local = AxSpace(
        id: _temporary('space'),
        name: name,
        description: description ?? '',
        instructions: instructions ?? '',
        branch: 'main',
        lastActivity: 'now');
    return engine.mutations
        .run(AxMutationOperation<AxSpace, AxOptimisticUpdate<List<AxSpace>>>(
      optimisticUpdate: () => engine.optimisticUpdate(
          spaces, (state) => _put(state.data ?? [], local, (s) => s.id)),
      isCurrent: (change) => change.isCurrent(),
      execute: (_) async {
        final value = await source.createSpace(
            name: name, description: description, instructions: instructions);
        if (value.id.isEmpty || value.id.startsWith('local-')) {
          throw const AxApiException('Space response identity does not match');
        }
        return value.copyWith(threads: const []);
      },
      commit: (saved, change) {
        change.commit((state) => _put(
            (state.data ?? []).where((s) => s.id != local.id).toList(),
            saved,
            (s) => s.id));
        engine.update(details.query(saved.id), (_) => saved);
      },
      rollback: (_, __, change) => change.rollback(),
      invalidate: (saved, _) async {
        engine.invalidate(spaces.key);
      },
    ));
  }

  Future<AxSpace> editSpace(AxSpace original,
      {String? name,
      String? description,
      String? instructions,
      Map<String, dynamic>? settings}) {
    final query = details.query(original.id);
    AxSpace patch(AxSpace value) => value.copyWith(
        name: name,
        description: description,
        instructions: instructions,
        settings: settings == null ? null : {...value.settings, ...settings},
        archived: settings?['archived'] is bool
            ? settings!['archived'] as bool
            : null,
        threads: const []);
    return engine.mutations.run(AxMutationOperation<AxSpace,
        (AxOptimisticUpdate<AxSpace>, AxOptimisticUpdate<List<AxSpace>>)>(
      key: AxQueryKey(['mutation', 'space', original.id]),
      optimisticUpdate: () {
        final detailChange = engine.optimisticUpdate(
            query, (state) => patch(state.data ?? original));
        final listChange = engine.optimisticUpdate(spaces, (state) {
          final values = state.data ?? const <AxSpace>[];
          if (!detailChange.isCurrent()) return values;
          final latest =
              values.where((s) => s.id == original.id).firstOrNull ?? original;
          return _replace(values, patch(latest), (s) => s.id);
        });
        return (detailChange, listChange);
      },
      isCurrent: (changes) => changes.$1.isCurrent() && changes.$2.isCurrent(),
      cancel: (changes) {
        changes.$1.rollback();
        changes.$2.rollback();
      },
      execute: (_) async {
        final value = await source.updateSpace(
            spaceId: original.id,
            name: name,
            description: description,
            instructions: instructions,
            settings: settings);
        if (value.id != original.id) {
          throw const AxApiException('Space response identity does not match');
        }
        return value.copyWith(threads: const []);
      },
      commit: (saved, changes) {
        changes.$1.commit((_) => saved);
        // The edit response carries no per-user state (pin, indicators), so
        // keep what the list already has.
        changes.$2.commit((state) {
          final values = state.data ?? const <AxSpace>[];
          final current = values.where((s) => s.id == saved.id).firstOrNull;
          return _replace(
              values,
              current == null
                  ? saved
                  : saved.copyWith(
                      pinnedAt: current.pinnedAt,
                      pinPosition: current.pinPosition,
                      hasActiveWork: current.hasActiveWork,
                      hasUnread: current.hasUnread),
              (s) => s.id);
        });
      },
      rollback: (_, __, changes) {
        changes.$1.rollback();
        changes.$2.rollback();
      },
      invalidate: (_, __) async {
        engine.invalidate(AxQueryKey(['space', original.id, 'audit']));
      },
    ));
  }

  Future<void> deleteSpace(AxSpace original) async {
    await source.deleteSpace(spaceId: original.id);
    engine.remove(details.query(original.id).key, prefix: true);
    await engine.refresh(spaces);
  }

  Future<AxThread> createThread(
      {required String spaceId,
      String? title,
      String? name,
      String? idempotencyKey}) {
    final effectiveTitle = title ?? name ?? '';
    final query = threads.query(spaceId);
    final input = {'title': effectiveTitle};
    final scope = 'space:$spaceId:create-thread';
    final key = idempotencyKey ?? _attempts.keyFor(scope, input);
    final local = AxThread.fromJson({
      'id': _temporary('thread'),
      'spaceId': spaceId,
      'title': effectiveTitle,
      'name': effectiveTitle,
      'status': 'active'
    });
    return engine.mutations
        .run(AxMutationOperation<AxThread, AxOptimisticUpdate<List<AxThread>>>(
      key: AxQueryKey(['mutation', 'thread-create', key]),
      optimisticUpdate: () => engine.optimisticUpdate(
          query, (state) => _put(state.data ?? [], local, (t) => t.id)),
      isCurrent: (change) => change.isCurrent(),
      execute: (_) async {
        final value = await source.createThread(
            spaceId: spaceId, name: effectiveTitle, idempotencyKey: key);
        if (value.id.isEmpty ||
            value.id.startsWith('local-') ||
            value.spaceId != spaceId) {
          throw const AxApiException('Thread response identity does not match');
        }
        return value;
      },
      commit: (saved, change) {
        _attempts.complete(scope, input, key);
        change.commit((state) => _put(
            (state.data ?? []).where((t) => t.id != local.id).toList(),
            saved,
            (t) => t.id));
      },
      rollback: (_, __, change) => change.rollback(),
      invalidate: (_, __) async {
        engine.invalidate(AxQueryKey(['space', spaceId, 'audit']));
      },
    ));
  }

  Future<AxThread> editThread(AxThread original,
      {String? title,
      String? name,
      String? status,
      Map<String, dynamic>? workConfig,
      Map<String, dynamic>? viewState}) {
    final effectiveTitle = title ?? name;
    final query = threads.query(original.spaceId);
    AxThread patch(AxThread value) => value.copyWith(
        title: effectiveTitle,
        status: status,
        workConfig: workConfig,
        viewState: viewState);
    return engine.mutations
        .run(AxMutationOperation<AxThread, AxOptimisticUpdate<List<AxThread>>>(
      key: AxQueryKey(['mutation', 'thread', original.id]),
      optimisticUpdate: () => engine.optimisticUpdate(
          query,
          (state) => _replace(
              state.data ?? [],
              patch((state.data ?? [])
                      .where((t) => t.id == original.id)
                      .firstOrNull ??
                  original),
              (t) => t.id)),
      isCurrent: (change) => change.isCurrent(),
      execute: (_) async {
        final value = await source.updateThread(
            threadId: original.id,
            name: effectiveTitle,
            status: status,
            workConfig: workConfig,
            metadata: viewState == null ? null : {'viewState': viewState});
        if (value.id != original.id || value.spaceId != original.spaceId) {
          throw const AxApiException('Thread response identity does not match');
        }
        return value;
      },
      commit: (saved, change) => change.commit((state) {
        final values = state.data ?? const <AxThread>[];
        final current = values.where((t) => t.id == saved.id).firstOrNull;
        // Edit responses omit per-user pins and unread indicators.
        return _replace(
            values,
            current == null
                ? saved
                : saved.copyWith(
                    pinnedAt: current.pinnedAt,
                    pinPosition: current.pinPosition,
                    hasUnread: current.hasUnread),
            (t) => t.id);
      }),
      rollback: (_, __, change) => change.rollback(),
      invalidate: (_, __) async {
        engine.invalidate(AxQueryKey(['space', original.spaceId, 'audit']));
      },
    ));
  }

  Future<void> deleteThread(AxThread original) {
    final query = threads.query(original.spaceId);
    List<AxThread> remove(AxQueryState<List<AxThread>> state) =>
        List.unmodifiable((state.data ?? []).where((t) => t.id != original.id));
    return engine.mutations
        .run(AxMutationOperation<void, AxOptimisticUpdate<List<AxThread>>>(
      key: AxQueryKey(['mutation', 'thread', original.id]),
      optimisticUpdate: () => engine.optimisticUpdate(query, remove),
      isCurrent: (change) => change.isCurrent(),
      execute: (_) => source.deleteThread(threadId: original.id),
      commit: (_, change) {
        change.commit(remove);
        engine.remove(AxQueryKey(['thread', original.id]), prefix: true);
      },
      rollback: (_, __, change) => change.rollback(),
      invalidate: (_, __) async {
        engine.invalidate(AxQueryKey(['space', original.spaceId, 'audit']));
      },
    ));
  }

  Future<void> acceptInvitation(AxSpaceInvitation invite) {
    final inviteQuery = invitations;
    final spaceQuery = spaces;
    final spaceLocal = AxSpace(
      id: invite.spaceId,
      name: invite.spaceName.isNotEmpty ? invite.spaceName : 'Space',
      description: '',
      instructions: '',
      branch: 'main',
      lastActivity: 'now',
    );
    return engine.mutations.run(AxMutationOperation<
        void,
        (
          AxOptimisticUpdate<List<AxSpaceInvitation>>,
          AxOptimisticUpdate<List<AxSpace>>
        )>(
      key: AxQueryKey(['mutation', 'invitation', 'accept', invite.id]),
      optimisticUpdate: () {
        final inviteChange = engine.optimisticUpdate(inviteQuery, (state) {
          final items = state.data ?? const <AxSpaceInvitation>[];
          return List.unmodifiable(items.where((i) => i.id != invite.id));
        });
        final spaceChange = engine.optimisticUpdate(spaceQuery, (state) {
          final items = state.data ?? const <AxSpace>[];
          if (invite.spaceId.isEmpty ||
              items.any((s) => s.id == invite.spaceId)) {
            return items;
          }
          return _put(items, spaceLocal, (s) => s.id);
        });
        return (inviteChange, spaceChange);
      },
      isCurrent: (changes) => changes.$1.isCurrent() && changes.$2.isCurrent(),
      cancel: (changes) {
        changes.$1.rollback();
        changes.$2.rollback();
      },
      execute: (_) => source.acceptSpaceInvitation(invitationId: invite.id),
      commit: (_, changes) {
        changes.$1.commit((state) => List.unmodifiable(
            (state.data ?? const <AxSpaceInvitation>[])
                .where((i) => i.id != invite.id)));
        changes.$2.commit((state) {
          final items = state.data ?? const <AxSpace>[];
          if (invite.spaceId.isEmpty ||
              items.any((s) => s.id == invite.spaceId)) {
            return items;
          }
          return _put(items, spaceLocal, (s) => s.id);
        });
      },
      rollback: (_, __, changes) {
        changes.$1.rollback();
        changes.$2.rollback();
      },
      invalidate: (_, __) async {
        try {
          await engine.revalidateWhere((key) => key == AxQueryKey(['people']));
        } catch (_) {
          // A People read failure must not interrupt successful membership reconciliation.
        }
        engine.invalidate(inviteQuery.key);
        engine.invalidate(spaceQuery.key);
        if (invite.spaceId.isNotEmpty) {
          engine.invalidate(AxQueryKey(['space', invite.spaceId]),
              prefix: true);
        }
      },
    ));
  }

  Future<void> declineInvitation(AxSpaceInvitation invite) {
    final inviteQuery = invitations;
    return engine.mutations.run(
        AxMutationOperation<void, AxOptimisticUpdate<List<AxSpaceInvitation>>>(
      key: AxQueryKey(['mutation', 'invitation', 'decline', invite.id]),
      optimisticUpdate: () => engine.optimisticUpdate(inviteQuery, (state) {
        final items = state.data ?? const <AxSpaceInvitation>[];
        return List.unmodifiable(items.where((i) => i.id != invite.id));
      }),
      isCurrent: (change) => change.isCurrent(),
      execute: (_) => source.declineSpaceInvitation(invitationId: invite.id),
      commit: (_, change) {
        change.commit((state) => List.unmodifiable(
            (state.data ?? const <AxSpaceInvitation>[])
                .where((i) => i.id != invite.id)));
      },
      rollback: (_, __, change) => change.rollback(),
      invalidate: (_, __) async {
        engine.invalidate(inviteQuery.key);
      },
    ));
  }
}
