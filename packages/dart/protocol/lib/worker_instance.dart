/// A Worker Instance (ADR-032): a named, owner-scoped Worker independent of
/// any Workspace. `enabled` is configured; `online` and `ready` are observed.
class WorkerInstance {
  const WorkerInstance({
    required this.id,
    required this.actorId,
    required this.workerTypeId,
    required this.workerTypeName,
    required this.name,
    required this.description,
    required this.enabled,
    required this.online,
    required this.ready,
    required this.createdAt,
    required this.updatedAt,
    this.defaultModel,
    this.revokedAt,
  });

  factory WorkerInstance.fromJson(Map<String, Object?> json) => WorkerInstance(
        id: json['id']! as String,
        actorId: json['actorId']! as String,
        workerTypeId: json['workerTypeId']! as String,
        workerTypeName: json['workerTypeName']! as String,
        name: json['name']! as String,
        description: (json['description'] as String?) ?? '',
        enabled: json['enabled']! as bool,
        online: json['online']! as bool,
        ready: json['ready']! as bool,
        defaultModel: json['defaultModel'] as String?,
        createdAt: json['createdAt']! as String,
        updatedAt: json['updatedAt']! as String,
        revokedAt: json['revokedAt'] as String?,
      );

  final String id;
  final String actorId;
  final String workerTypeId;
  final String workerTypeName;
  final String name;
  final String description;
  final bool enabled;
  final bool online;
  final bool ready;
  final String? defaultModel;
  final String createdAt;
  final String updatedAt;
  final String? revokedAt;

  bool get isRevoked => revokedAt != null;

  Map<String, Object?> toJson() => {
        'id': id,
        'actorId': actorId,
        'workerTypeId': workerTypeId,
        'workerTypeName': workerTypeName,
        'name': name,
        'description': description,
        'enabled': enabled,
        'online': online,
        'ready': ready,
        'defaultModel': defaultModel,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'revokedAt': revokedAt,
      };
}

List<WorkerInstance> parseWorkerInstances(Object? body) {
  final list = body is Map ? body['workers'] : null;
  if (list is! List) return const [];
  return [
    for (final item in list)
      if (item is Map) WorkerInstance.fromJson(item.cast<String, Object?>()),
  ];
}
