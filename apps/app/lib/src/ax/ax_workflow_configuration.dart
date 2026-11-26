/// A Worker is explicit; null Worker means unresolved or inherited for a step.
/// Null model/effort values represent Auto and are omitted from the wire payload.
class AxWorkflowSelection {
  const AxWorkflowSelection(
      {this.worker,
      this.model,
      this.effort,
      this.catalogRevision,
      this.mcpTools});
  final String? worker, model, effort, catalogRevision;

  /// Null inherits; an empty list explicitly selects no servers.
  final List<String>? mcpTools;
  factory AxWorkflowSelection.fromJson(Map<String, dynamic> json) =>
      AxWorkflowSelection(
          worker: json['worker'] as String?,
          model: json['model'] as String?,
          effort: json['effort'] as String?,
          catalogRevision: json['catalogRevision'] as String?,
          mcpTools: (json['mcpTools'] as List?)?.cast<String>().toList());
  Map<String, dynamic> toJson() => {
        if (worker != null) 'worker': worker,
        if (model != null) 'model': model,
        if (effort != null) 'effort': effort,
        if (catalogRevision != null) 'catalogRevision': catalogRevision,
        if (mcpTools != null) 'mcpTools': List<String>.of(mcpTools!),
      };
  AxWorkflowSelection withMcpTools(List<String>? tools) => AxWorkflowSelection(
        worker: worker,
        model: model,
        effort: effort,
        catalogRevision: catalogRevision,
        mcpTools: tools == null ? null : List.unmodifiable(tools),
      );
  AxWorkflowSelection overlay(AxWorkflowSelection override) =>
      AxWorkflowSelection(
          worker: override.worker ?? worker,
          model: override.model ?? model,
          effort: override.effort ?? effort,
          mcpTools: override.mcpTools ?? mcpTools,
          catalogRevision: override.worker != null && override.worker != worker
              ? override.catalogRevision
              : override.catalogRevision ?? catalogRevision);
}

class AxUserWorkflowConfiguration {
  AxUserWorkflowConfiguration({
    required this.workflowId,
    this.enabled = true,
    this.defaults = const AxWorkflowSelection(),
    Map<String, AxWorkflowSelection> stepOverrides = const {},
    this.researcherCount,
  }) : stepOverrides = Map.unmodifiable(stepOverrides);
  final String workflowId;

  /// Research only (configuration schema 2): independent researchers to run.
  /// Overrides are then keyed by step instance (`research-1`, `synthesis`).
  final int? researcherCount;
  final bool enabled;
  final AxWorkflowSelection defaults;
  final Map<String, AxWorkflowSelection> stepOverrides;
  factory AxUserWorkflowConfiguration.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version != 1 && !(version == 2 && json['workflowId'] == 'research')) {
      throw const FormatException('Unsupported workflow configuration version');
    }
    return AxUserWorkflowConfiguration(
      workflowId: json['workflowId'] as String,
      enabled: json['enabled'] as bool,
      researcherCount:
          version == 2 ? (json['researcherCount'] as num?)?.toInt() ?? 2 : null,
      defaults: AxWorkflowSelection.fromJson(
          Map<String, dynamic>.from(json['defaults'] as Map)),
      stepOverrides: (json['stepOverrides'] as Map).map((key, value) =>
          MapEntry(
              key as String,
              AxWorkflowSelection.fromJson(
                  Map<String, dynamic>.from(value as Map)))),
    );
  }
  AxWorkflowSelection selectionFor(String stepId) =>
      defaults.overlay(stepOverrides[stepId] ?? const AxWorkflowSelection());
  Map<String, dynamic> toJson() => {
        'schemaVersion': researcherCount != null ? 2 : 1,
        'workflowId': workflowId,
        'enabled': enabled,
        if (researcherCount != null) 'researcherCount': researcherCount,
        'defaults': defaults.toJson(),
        'stepOverrides': {
          for (final entry in stepOverrides.entries)
            if (entry.value.toJson().isNotEmpty)
              entry.key: entry.value.toJson(),
        },
      };
}

abstract interface class AxWorkflowConfigurationDataSource {
  Future<List<AxUserWorkflowConfiguration>> loadWorkflowConfigurations();
  Future<AxUserWorkflowConfiguration> saveWorkflowConfiguration(
      AxUserWorkflowConfiguration configuration);
  Future<AxUserWorkflowConfiguration> resetWorkflowConfiguration(
      String workflowId);
}

/// Scope-level default workflow selection. This is deliberately separate from
/// execution fields so changing a workflow's Worker/model/effort does not
/// change which workflow a new request starts with.
abstract interface class AxWorkflowDefaultDataSource {
  Future<String> loadWorkflowDefault();
  Future<String> saveWorkflowDefault(String workflowId);
  Future<String> loadSpaceWorkflowDefault(String spaceId);
}

abstract interface class AxSpaceWorkflowConfigurationDataSource {
  Future<List<AxUserWorkflowConfiguration>> loadSpaceWorkflowConfigurations(
      String spaceId);
}

/// A folder a Connect installation allows, with the computer it is on. Only the
/// folder's own name travels, never its path.
class AxDeviceFolder {
  const AxDeviceFolder({
    required this.deviceId,
    required this.deviceName,
    required this.folderId,
    required this.displayName,
    required this.writable,
    required this.online,
  });

  final String deviceId;
  final String deviceName;
  final String folderId;
  final String displayName;
  final bool writable;

  /// A Worker on this computer is connected now.
  final bool online;

  factory AxDeviceFolder.fromJson(Map<String, dynamic> json) => AxDeviceFolder(
        deviceId: json['deviceId'] as String,
        deviceName: json['deviceName'] as String,
        folderId: json['folderId'] as String,
        displayName: json['displayName'] as String,
        writable: json['mode'] == 'write',
        online: json['online'] == true,
      );
}

/// The folder a Space works in. Only the Space owner can see or change it.
class AxSpaceFolder {
  const AxSpaceFolder({required this.eligible, this.folder});

  final bool eligible;
  final AxDeviceFolder? folder;

  factory AxSpaceFolder.fromJson(Map<String, dynamic> json) => AxSpaceFolder(
        eligible: json['eligible'] != false,
        folder: json['folder'] is Map
            ? AxDeviceFolder.fromJson(
                Map<String, dynamic>.from(json['folder'] as Map))
            : null,
      );
}

abstract interface class AxSpaceFolderDataSource {
  Future<List<AxDeviceFolder>> loadDeviceFolders();
  Future<AxSpaceFolder> loadSpaceFolder(String spaceId);
  Future<AxSpaceFolder> setSpaceFolder(String spaceId,
      {required String deviceId, required String folderId});
  Future<void> clearSpaceFolder(String spaceId);

  /// Forgets a computer's folder (or all of the computer's folders when
  /// [folderId] is null) in the owner's list. Returns how many Spaces use it.
  /// With [dryRun] nothing is removed, so the person can be warned first.
  Future<int> removeDeviceFolders(String deviceId,
      {String? folderId, bool dryRun = false});
}
