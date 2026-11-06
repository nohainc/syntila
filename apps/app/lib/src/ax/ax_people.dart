import 'ax_models.dart';

class AxPeopleSpace {
  const AxPeopleSpace(
      {required this.id,
      required this.name,
      this.permissions = const AxSpacePermissions(),
      this.canInvite = false});
  final String id;
  final String name;
  final AxSpacePermissions permissions;
  final bool canInvite;
  factory AxPeopleSpace.fromJson(Map<String, dynamic> json) => AxPeopleSpace(
        id: json['id'] as String,
        name: json['name'] as String,
        permissions: json['permissions'] is Map
            ? AxSpacePermissions.fromJson(json['permissions'] as Map)
            : const AxSpacePermissions(),
        canInvite: json['canInvite'] == true,
      );
}

class AxPerson {
  const AxPerson({
    required this.userId,
    required this.displayName,
    required this.email,
    this.avatarUrl,
    required this.establishedAt,
    required this.sharedSpaceCount,
    this.sharedSpaces = const [],
    this.invitableSpaces = const [],
    this.pendingInvitationSpaceIds = const [],
    this.connectionStatus = 'collaborator',
    this.directSpaceId,
    this.generalThreadId,
    this.invitationId,
  });

  final String userId;
  final String displayName;
  final String email;
  final String? avatarUrl;
  final String establishedAt;
  final int sharedSpaceCount;
  final List<AxPeopleSpace> sharedSpaces;
  final List<AxPeopleSpace> invitableSpaces;
  final List<String> pendingInvitationSpaceIds;
  final String connectionStatus;
  final String? directSpaceId;
  final String? generalThreadId;
  final String? invitationId;

  factory AxPerson.fromJson(Map<String, dynamic> json) => AxPerson(
        userId: json['userId'] as String,
        displayName: json['displayName'] as String,
        email: json['email'] as String,
        avatarUrl: json['avatarUrl'] as String?,
        establishedAt: json['establishedAt'] as String,
        sharedSpaceCount: (json['sharedSpaceCount'] as num).toInt(),
        sharedSpaces: _spaces(json['sharedSpaces']),
        invitableSpaces: _spaces(json['invitableSpaces']),
        pendingInvitationSpaceIds: List.unmodifiable(
            (json['pendingInvitationSpaceIds'] as List? ?? []).cast<String>()),
        connectionStatus: json['connectionStatus'] as String? ?? 'collaborator',
        directSpaceId: json['directSpaceId'] as String?,
        generalThreadId: json['generalThreadId'] as String?,
        invitationId: json['invitationId'] as String?,
      );

  static List<AxPeopleSpace> _spaces(Object? value) =>
      List.unmodifiable((value as List? ?? []).map((row) =>
          AxPeopleSpace.fromJson(Map<String, dynamic>.from(row as Map))));
}

abstract interface class AxPeopleDataSource {
  Future<List<AxPerson>> loadPeople();
  Future<void> invitePersonToSpace({
    required String spaceId,
    required String userId,
    required String role,
    required AxSpacePermissions permissions,
  });
  Future<void> sendPersonInvitation({String? email, String? userId});
  Future<void> acceptPersonInvitation(String invitationId);
  Future<void> declinePersonInvitation(String invitationId);
  Future<void> cancelPersonInvitation(String invitationId);
  Future<void> disconnectPersonConnection(String userId);
  Future<void> blockPerson(String userId);
  Future<void> unblockPerson(String userId);
}
