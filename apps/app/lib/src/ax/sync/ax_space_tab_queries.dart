import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_space_threads.dart';
import 'ax_sync_engine.dart';

/// Tab resources register and fetch only when a consumer observes/ensures them.
class AxSpaceTabQueries {
  AxSpaceTabQueries(this.source, {AxSyncEngine? engine})
      : engine = engine ?? AxSyncEngine();
  final AxDataSource source;
  final AxSyncEngine engine;
  static final _sources = Expando<AxSpaceTabQueries>();
  static AxSpaceTabQueries forSource(AxDataSource source) =>
      _sources[source] ??= AxSpaceTabQueries(source);
  late final threads = AxSpaceThreads(source, engine: engine);

  AxQuery<List<AxSpaceMember>> members(String id) => AxQuery(
      key: AxQueryKey(['space', id, 'members']),
      load: () async =>
          List.unmodifiable(await source.loadSpaceMembers(spaceId: id)));
  AxQuery<List<AxSpaceInvitation>> invitations(String id) => AxQuery(
      key: AxQueryKey(['space', id, 'invitations']),
      load: () async =>
          List.unmodifiable(await source.loadSpaceInvitations(spaceId: id)));
  AxQuery<List<AxAuditEntry>> audit(String id) => AxQuery(
      key: AxQueryKey(['space', id, 'audit']),
      load: () async =>
          List.unmodifiable(await source.loadSpaceAudit(spaceId: id)));

  Future<void> refreshMembers(String id,
      {bool includeMembers = true, bool includeInvitations = true}) async {
    final keys = {
      if (includeMembers) members(id).key,
      if (includeInvitations) invitations(id).key,
    };
    await engine.revalidateWhere(keys.contains);
    engine.invalidate(audit(id).key);
  }
}
