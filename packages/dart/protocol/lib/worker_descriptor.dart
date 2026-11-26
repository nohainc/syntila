/// Cloud-owned logical Worker metadata. Local readiness and installed Profile
/// state belong to Connect inventory and are intentionally absent.
class WorkerDescriptor {
  const WorkerDescriptor({
    required this.workerTypeId,
    required this.displayName,
    required this.description,
    required this.engineFamily,
    required this.profileDefinitionId,
    required this.providerToolName,
    required this.releaseStage,
    required this.visibilityState,
    required this.sortOrder,
  });

  final String workerTypeId;
  final String displayName;
  final String description;
  final String engineFamily;
  final String profileDefinitionId;
  final String providerToolName;
  final String releaseStage;
  final String visibilityState;
  final int sortOrder;

  factory WorkerDescriptor.fromJson(Map<String, Object?> json) {
    const fields = {
      'workerTypeId',
      'displayName',
      'description',
      'engineFamily',
      'profileDefinitionId',
      'providerToolName',
      'releaseStage',
      // V9 Cloud catalogs report Worker lifecycle separately from the
      // removed Profile release-channel concept.
      'lifecycleState',
      'visibilityState',
      'sortOrder',
      // The Cloud catalog shares this descriptor with Profile Lab and may
      // include current published-profile metadata. These fields are
      // informational for Connect and are intentionally not persisted in
      // the descriptor model.
      'currentRevision',
      'currentDigest',
      'currentUpdatedAt',
    };
    final workerTypeId = json['workerTypeId'];
    final displayName = json['displayName'];
    final description = json['description'];
    final engineFamily = json['engineFamily'];
    final profileDefinitionId = json['profileDefinitionId'];
    final providerToolName = json['providerToolName'];
    final releaseStage = json['releaseStage'];
    final lifecycleState = json['lifecycleState'];
    final visibilityState = json['visibilityState'];
    final sortOrder = json['sortOrder'];
    final currentRevision = json['currentRevision'];
    final currentDigest = json['currentDigest'];
    final currentUpdatedAt = json['currentUpdatedAt'];
    final normalizedReleaseStage = releaseStage ??
        (lifecycleState == 'active' || lifecycleState == 'retired'
            ? 'stable'
            : null);
    if (json.keys.any((key) => !fields.contains(key)) ||
        workerTypeId is! String ||
        !_identifier.hasMatch(workerTypeId) ||
        workerTypeId.length > 96 ||
        displayName is! String ||
        displayName.trim().isEmpty ||
        displayName.length > 128 ||
        description is! String ||
        description.length > 500 ||
        engineFamily != 'cli' ||
        profileDefinitionId is! String ||
        !_identifier.hasMatch(profileDefinitionId) ||
        profileDefinitionId.length > 96 ||
        providerToolName is! String ||
        providerToolName.trim().isEmpty ||
        providerToolName.length > 128 ||
        !const {'testing', 'beta', 'stable'}.contains(normalizedReleaseStage) ||
        (lifecycleState != null &&
            !const {'active', 'retired'}.contains(lifecycleState)) ||
        (currentRevision != null &&
            (currentRevision is! int || currentRevision < 1)) ||
        (currentDigest != null &&
            (currentDigest is! String ||
                !_sha256Digest.hasMatch(currentDigest))) ||
        (currentUpdatedAt != null &&
            (currentUpdatedAt is! String ||
                currentUpdatedAt.length > 64 ||
                DateTime.tryParse(currentUpdatedAt) == null)) ||
        !const {'hidden', 'visible'}.contains(visibilityState) ||
        sortOrder is! int ||
        sortOrder < 0 ||
        sortOrder > 10000) {
      throw const FormatException('Worker descriptor is invalid');
    }
    return WorkerDescriptor(
      workerTypeId: workerTypeId,
      displayName: displayName,
      description: description,
      engineFamily: engineFamily as String,
      profileDefinitionId: profileDefinitionId,
      providerToolName: providerToolName,
      releaseStage: normalizedReleaseStage as String,
      visibilityState: visibilityState as String,
      sortOrder: sortOrder,
    );
  }

  Map<String, Object?> toJson() => {
        'workerTypeId': workerTypeId,
        'displayName': displayName,
        'description': description,
        'engineFamily': engineFamily,
        'profileDefinitionId': profileDefinitionId,
        'providerToolName': providerToolName,
        'releaseStage': releaseStage,
        'visibilityState': visibilityState,
        'sortOrder': sortOrder,
      };
}

final _identifier = RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$');
final _sha256Digest = RegExp(r'^[0-9a-f]{64}$');
