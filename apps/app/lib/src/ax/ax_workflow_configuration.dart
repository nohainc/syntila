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
  Future<List<AxUserWorkflowConfiguration>> loadWorkflowConfigurations(
      {String? workspaceId});
  Future<AxUserWorkflowConfiguration> saveWorkflowConfiguration(
      AxUserWorkflowConfiguration configuration,
      {String? workspaceId});
  Future<AxUserWorkflowConfiguration> resetWorkflowConfiguration(
      String workflowId,
      {String? workspaceId});
}

/// Scope-level default workflow selection. This is deliberately separate from
/// execution fields so changing a workflow's Worker/model/effort does not
/// change which workflow a new request starts with.
abstract interface class AxWorkflowDefaultDataSource {
  Future<String> loadWorkflowDefault({String? workspaceId});
  Future<String> saveWorkflowDefault(String workflowId, {String? workspaceId});
  Future<String> loadSpaceWorkflowDefault(String spaceId);
}

abstract interface class AxSpaceWorkflowConfigurationDataSource {
  Future<List<AxUserWorkflowConfiguration>> loadSpaceWorkflowConfigurations(
      String spaceId);
}

class AxWorkflowWorkspace {
  const AxWorkflowWorkspace({required this.id, required this.name});
  final String id;
  final String name;
  factory AxWorkflowWorkspace.fromJson(Map<String, dynamic> json) =>
      AxWorkflowWorkspace(
          id: json['id'] as String, name: json['name'] as String);
}

class AxWorkflowWorkspaceSettings {
  const AxWorkflowWorkspaceSettings(
      {this.workspaceId, this.inherited = false, this.workspaces = const []});
  final String? workspaceId;
  final bool inherited;
  final List<AxWorkflowWorkspace> workspaces;
  factory AxWorkflowWorkspaceSettings.fromJson(Map<String, dynamic> json) =>
      AxWorkflowWorkspaceSettings(
          workspaceId: json['workspaceId'] as String?,
          inherited: json['inherited'] == true,
          workspaces: (json['workspaces'] as List)
              .map((v) => AxWorkflowWorkspace.fromJson(
                  Map<String, dynamic>.from(v as Map)))
              .toList());
}

abstract interface class AxWorkflowWorkspaceDataSource {
  Future<AxWorkflowWorkspaceSettings> loadWorkflowWorkspace({String? spaceId});
  Future<AxWorkflowWorkspaceSettings> selectWorkflowWorkspace(
      {String? spaceId, String? workspaceId});
}

/// An owner-managed folder outside Work Root, published by the Space's
/// Workspace. Cloud only knows its name and access status, never its path.
class AxAdditionalFolder {
  const AxAdditionalFolder({
    required this.id,
    required this.displayName,
    required this.status,
    this.attached = false,
  });
  final String id;
  final String displayName;

  /// `available`, `read_only`, `denied`, or `missing`.
  final String status;
  final bool attached;

  bool get accessible => status == 'available' || status == 'read_only';

  factory AxAdditionalFolder.fromJson(Map<String, dynamic> json) =>
      AxAdditionalFolder(
        id: json['id'] as String,
        displayName: json['displayName'] as String,
        status: json['status'] as String? ?? 'missing',
        attached: json['attached'] == true,
      );
}

/// Additional folders for one Space. Only the owner of both the Space and
/// its Workspace is [eligible]; everyone else receives no folders.
class AxSpaceAdditionalFolders {
  const AxSpaceAdditionalFolders({
    required this.eligible,
    this.reason,
    this.workspaceId,
    this.folders = const [],
  });
  final bool eligible;
  final String? reason;
  final String? workspaceId;
  final List<AxAdditionalFolder> folders;

  Iterable<AxAdditionalFolder> get attached =>
      folders.where((folder) => folder.attached);

  factory AxSpaceAdditionalFolders.fromJson(Map<String, dynamic> json) =>
      AxSpaceAdditionalFolders(
        eligible: json['eligible'] == true,
        reason: json['reason'] as String?,
        workspaceId: json['workspaceId'] as String?,
        folders: [
          for (final value in (json['folders'] as List? ?? const []))
            AxAdditionalFolder.fromJson(
                Map<String, dynamic>.from(value as Map)),
        ],
      );
}

abstract interface class AxSpaceAdditionalFolderDataSource {
  Future<AxSpaceAdditionalFolders> loadSpaceAdditionalFolders(String spaceId);
  Future<AxSpaceAdditionalFolders> saveSpaceAdditionalFolders(
      String spaceId, List<String> folderIds);
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
