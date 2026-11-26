/// A Worker Instance (ADR-032): a named, owner-scoped Worker independent of
/// any Connect. `enabled` is configured; `online` and `ready` are observed.
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
    this.paired,
    required this.ready,
    this.readinessKnown = true,
    required this.createdAt,
    required this.updatedAt,
    this.defaultModel,
    this.executionOptions,
    this.hiddenModels = const [],
    this.hiddenEfforts = const {},
    this.modelsStatus,
    this.modelsReportedAt,
    this.deviceId,
    this.deviceName,
    this.providerToolName,
    this.providerToolVersion,
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
        paired: json['paired'] as bool?,
        ready: json['ready']! as bool,
        readinessKnown: (json['readinessKnown'] as bool?) ?? true,
        defaultModel: json['defaultModel'] as String?,
        modelsStatus: json['modelsStatus'] as String?,
        modelsReportedAt: json['modelsReportedAt'] as String?,
        executionOptions: json['executionOptions'] is Map
            ? Map<String, Object?>.from(json['executionOptions']! as Map)
            : null,
        hiddenModels: _parseHiddenModels(json['visibility']),
        hiddenEfforts: _parseHiddenEfforts(json['visibility']),
        deviceId: json['deviceId'] as String?,
        deviceName: json['deviceName'] as String?,
        providerToolName: json['providerToolName'] as String?,
        providerToolVersion: json['providerToolVersion'] as String?,
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
  final bool? paired;
  final bool ready;
  final bool readinessKnown;
  final String? defaultModel;

  /// Models and efforts this Worker offers (normalized options JSON), if known.
  final Map<String, Object?>? executionOptions;
  final List<String> hiddenModels;
  final Map<String, List<String>> hiddenEfforts;

  /// `ok`, or why models could not be captured at the Agent's last start.
  final String? modelsStatus;
  final String? modelsReportedAt;
  final String? deviceId;
  final String? deviceName;
  final String? providerToolName;
  final String? providerToolVersion;
  final String createdAt;
  final String updatedAt;
  final String? revokedAt;

  bool get isPaired => paired ?? online;
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
        if (paired != null) 'paired': paired,
        'ready': ready,
        'readinessKnown': readinessKnown,
        'defaultModel': defaultModel,
        if (executionOptions != null) 'executionOptions': executionOptions,
        if (hiddenModels.isNotEmpty || hiddenEfforts.isNotEmpty)
          'visibility': {
            'hiddenModels': hiddenModels,
            'hiddenEfforts': hiddenEfforts,
          },
        if (modelsStatus != null) 'modelsStatus': modelsStatus,
        if (modelsReportedAt != null) 'modelsReportedAt': modelsReportedAt,
        if (deviceId != null) 'deviceId': deviceId,
        if (deviceName != null) 'deviceName': deviceName,
        if (providerToolName != null) 'providerToolName': providerToolName,
        if (providerToolVersion != null)
          'providerToolVersion': providerToolVersion,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'revokedAt': revokedAt,
      };

  static List<String> _parseHiddenModels(Object? visibility) {
    if (visibility is! Map) return const [];
    final raw = visibility['hiddenModels'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is String) item
    ];
  }

  static Map<String, List<String>> _parseHiddenEfforts(Object? visibility) {
    if (visibility is! Map) return const {};
    final raw = visibility['hiddenEfforts'];
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        if (entry.key is String && entry.value is List)
          entry.key as String: [
            for (final eff in entry.value as List)
              if (eff is String) eff,
          ],
    };
  }
}

List<WorkerInstance> parseWorkerInstances(Object? body) {
  final list = body is Map ? body['workers'] : null;
  if (list is! List) return const [];
  return [
    for (final item in list)
      if (item is Map) WorkerInstance.fromJson(item.cast<String, Object?>()),
  ];
}
