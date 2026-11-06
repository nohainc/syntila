import '../ax_data.dart';
import 'ax_sync_engine.dart';

/// One session query shared by People and invitation consumers. No polling or navigation reload.
class AxPeople {
  AxPeople(this.source, {required this.engine});
  final AxDataSource source;
  final AxSyncEngine engine;
  static final key = AxQueryKey(['people']);
  late final query = AxQuery<List<AxPerson>>(
      key: key,
      staleTime: const Duration(minutes: 45),
      load: () async =>
          List.unmodifiable(await (source as AxPeopleDataSource).loadPeople()));
  Future<List<AxPerson>> ensure() =>
      engine.ensure(query, policy: AxCachePolicy.cacheFirst);
  Future<List<AxPerson>> refresh() => engine.refresh(query);
  void clear() => engine.remove(key);

  Future<void> sendInvitation({String? email, String? userId}) async {
    await (source as AxPeopleDataSource)
        .sendPersonInvitation(email: email, userId: userId);
    await refresh();
  }

  Future<void> acceptInvitation(String invitationId) async {
    await (source as AxPeopleDataSource).acceptPersonInvitation(invitationId);
    await refresh();
  }

  Future<void> declineInvitation(String invitationId) async {
    await (source as AxPeopleDataSource).declinePersonInvitation(invitationId);
    await refresh();
  }

  Future<void> cancelInvitation(String invitationId) async {
    await (source as AxPeopleDataSource).cancelPersonInvitation(invitationId);
    await refresh();
  }

  Future<void> disconnect(String userId) async {
    await (source as AxPeopleDataSource).disconnectPersonConnection(userId);
    await refresh();
  }

  Future<void> block(String userId) async {
    await (source as AxPeopleDataSource).blockPerson(userId);
    await refresh();
  }

  Future<void> unblock(String userId) async {
    await (source as AxPeopleDataSource).unblockPerson(userId);
    await refresh();
  }
}
