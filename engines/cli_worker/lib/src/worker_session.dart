/// Worker-local provider execution state. Native IDs never cross a protocol.
class WorkerSession {
  const WorkerSession({
    required this.id,
    required this.conversationId,
    required this.workerId,
    required this.profileId,
    required this.profileVersion,
    required this.nativeSessionId,
    required this.synchronizedContextRevision,
    required this.status,
    required this.lastModelId,
    required this.lastEffort,
    required this.createdAt,
    required this.lastUsedAt,
    this.synchronizedHistorySequence = 0,
  });
  final int synchronizedHistorySequence;
  final String id;
  final String conversationId;
  final String workerId;
  final String profileId;
  final int profileVersion;
  final String nativeSessionId;
  final int synchronizedContextRevision;
  final String status;
  final String? lastModelId;
  final String? lastEffort;
  final String createdAt;
  final String lastUsedAt;
  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'conversationId': conversationId,
    'workerId': workerId,
    'profileId': profileId,
    'profileVersion': profileVersion,
    'nativeSessionId': nativeSessionId,
    'synchronizedContextRevision': synchronizedContextRevision,
    'synchronizedHistorySequence': synchronizedHistorySequence,
    'status': status,
    'lastModelId': lastModelId,
    'lastEffort': lastEffort,
    'createdAt': createdAt,
    'lastUsedAt': lastUsedAt,
  };
  factory WorkerSession.fromJson(Map<String, Object?> json) {
    if ((json['synchronizedHistorySequence'] != null &&
            (json['synchronizedHistorySequence'] is! int ||
                ((json['synchronizedHistorySequence'] as int) < 0 ||
                    (json['synchronizedHistorySequence'] as int) >
                        9007199254740991))) ||
        json['schemaVersion'] != 1 ||
        json['profileVersion'] is! int ||
        (json['profileVersion'] as int) < 1 ||
        json['synchronizedContextRevision'] is! int ||
        (json['synchronizedContextRevision'] as int) < 0 ||
        (json['synchronizedContextRevision'] as int) > 9007199254740991 ||
        (json['lastModelId'] != null && json['lastModelId'] is! String) ||
        (json['lastEffort'] != null && json['lastEffort'] is! String) ||
        !const {
          'active',
          'invalidated',
          'requires_synchronization',
        }.contains(json['status'])) {
      throw const FormatException('Invalid local Worker Session schema');
    }
    for (final key in [
      'id',
      'conversationId',
      'workerId',
      'profileId',
      'nativeSessionId',
      'createdAt',
      'lastUsedAt',
    ]) {
      if (json[key] is! String || (json[key] as String).isEmpty)
        throw const FormatException('Invalid local Worker Session identity');
    }
    return WorkerSession(
      synchronizedHistorySequence:
          json['synchronizedHistorySequence'] as int? ?? 0,
      id: json['id'] as String,
      conversationId: json['conversationId'] as String,
      workerId: json['workerId'] as String,
      profileId: json['profileId'] as String,
      profileVersion: json['profileVersion'] as int,
      nativeSessionId: json['nativeSessionId'] as String,
      synchronizedContextRevision: json['synchronizedContextRevision'] as int,
      status: json['status'] as String,
      lastModelId: json['lastModelId'] as String?,
      lastEffort: json['lastEffort'] as String?,
      createdAt: json['createdAt'] as String,
      lastUsedAt: json['lastUsedAt'] as String,
    );
  }
}
