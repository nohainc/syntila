import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_sync_engine.dart';

/// Focused Space details; list summaries never mark this query hydrated.
class AxSpaceDetails {
  AxSpaceDetails(this.source, {required this.engine});
  final AxDataSource source;
  final AxSyncEngine engine;

  AxQuery<AxSpace> query(String spaceId) => AxQuery(
        key: AxQueryKey(['space', spaceId]),
        load: () async => (await source.loadSpace(spaceId: spaceId))
            .copyWith(threads: const []),
      );

  AxSpace? peek(String spaceId) => engine.peek(query(spaceId)).data;
  Future<AxSpace> ensure(String spaceId) => engine.ensure(query(spaceId));

  /// Persist the caller's sidebar visibility; other sessions receive the
  /// server's user-scoped space event and refetch.
  Future<void> setHidden(String spaceId, bool hidden) =>
      source.setSpaceHidden(spaceId: spaceId, hidden: hidden);

  /// Record a successful server write, fencing any older detail reads.
  Future<AxSpace> record(AxSpace space) {
    final entity = space.copyWith(threads: const []);
    return engine.mutate(AxMutation(
      query: query(space.id),
      optimistic: (_) => entity,
      execute: () async => entity,
    ));
  }
}
