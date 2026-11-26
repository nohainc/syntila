import 'dart:convert';
import 'dart:io';

import '../tool_profile_v1.dart';

/// Local metadata associated with a draft in Profile Lab.
class DraftProfileMetadata {
  const DraftProfileMetadata({
    required this.profileDefinitionId,
    required this.createdAt,
    required this.updatedAt,
    required this.lastPayloadDigest,
    this.author = 'developer',
    this.notes = '',
    this.provenance,
  });

  final String profileDefinitionId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String lastPayloadDigest;
  final String author;
  final String notes;
  final Map<String, Object?>? provenance;

  Map<String, Object?> toJson() => {
        'profileDefinitionId': profileDefinitionId,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'lastPayloadDigest': lastPayloadDigest,
        'author': author,
        'notes': notes,
        if (provenance != null) 'provenance': provenance,
      };

  factory DraftProfileMetadata.fromJson(Map<String, Object?> json) {
    return DraftProfileMetadata(
      profileDefinitionId: json['profileDefinitionId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      lastPayloadDigest: json['lastPayloadDigest'] as String,
      author: (json['author'] as String?) ?? 'developer',
      notes: (json['notes'] as String?) ?? '',
      provenance: json['provenance'] is Map
          ? Map<String, Object?>.from(json['provenance'] as Map)
          : null,
    );
  }
}

/// Profile Lab's local storage for unsigned draft Tool Profiles and test evidence.
///
/// Restrictive filesystem permissions (0700 for directories, 0600 for files) are
/// enforced on POSIX platforms. Drafts stored here are completely isolated from
/// Connect's verified published Profile storage and can never satisfy
/// [ToolProfileReleaseAdmission].
class DraftProfileStore {
  DraftProfileStore({required Directory draftsRoot}) : _draftsRoot = draftsRoot;

  final Directory _draftsRoot;

  Directory get draftsRoot => _draftsRoot;

  Directory _definitionDir(String profileDefinitionId) =>
      Directory('${_draftsRoot.path}/$profileDefinitionId');

  Directory _evidenceDir(String profileDefinitionId) =>
      Directory('${_definitionDir(profileDefinitionId).path}/evidence');

  Directory _recoveryDir(String profileDefinitionId) =>
      Directory('${_definitionDir(profileDefinitionId).path}/recovery');

  File _draftFile(String profileDefinitionId) =>
      File('${_definitionDir(profileDefinitionId).path}/draft.json');

  File _metadataFile(String profileDefinitionId) =>
      File('${_definitionDir(profileDefinitionId).path}/draft_metadata.json');

  Future<void> _enforcePermissions(FileSystemEntity entity,
      {bool isDirectory = false}) async {
    if (Platform.isMacOS || Platform.isLinux) {
      try {
        final mode = isDirectory ? '700' : '600';
        await Process.run('chmod', [mode, entity.path]);
      } catch (_) {
        // Best effort if chmod is restricted in sandbox
      }
    }
  }

  /// Lists all profile definition IDs currently having drafts in this store.
  Future<List<String>> listDraftDefinitionIds() async {
    if (!await _draftsRoot.exists()) return const [];
    final entries = await _draftsRoot.list().toList();
    final ids = <String>[];
    for (final entry in entries) {
      if (entry is Directory) {
        final draftJson = File('${entry.path}/draft.json');
        if (await draftJson.exists()) {
          ids.add(entry.uri.pathSegments.where((s) => s.isNotEmpty).last);
        }
      }
    }
    ids.sort();
    return ids;
  }

  /// Saves or updates a draft Profile.
  ///
  /// The [profileJson] is strictly validated against [EngineProfile.parse].
  /// Returns the corresponding [LocalDraftProfileCandidate], which is guaranteed
  /// to have `isPublished == false`.
  Future<LocalDraftProfileCandidate> saveDraft({
    required String profileDefinitionId,
    required Map<String, Object?> profileJson,
    String author = 'developer',
    String notes = '',
    Map<String, Object?>? provenance,
  }) async {
    // Strict schema and integrity validation
    final canonical = canonicalJson(profileJson);
    final profileBytes = utf8.encode(canonical);
    final parsed = EngineProfile.parse(profileBytes);

    if (parsed.definitionId != profileDefinitionId) {
      throw ArgumentError(
        'Profile payload profileDefinitionId "${parsed.definitionId}" does not match requested "$profileDefinitionId".',
      );
    }

    final candidate = LocalDraftProfileCandidate.fromProfileMap(profileJson);

    final dir = _definitionDir(profileDefinitionId);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      await _enforcePermissions(dir, isDirectory: true);
    }

    final now = DateTime.now().toUtc();
    final existingMeta = await loadDraftMetadata(profileDefinitionId);
    final metadata = DraftProfileMetadata(
      profileDefinitionId: profileDefinitionId,
      createdAt: existingMeta?.createdAt ?? now,
      updatedAt: now,
      lastPayloadDigest: candidate.payloadDigest,
      author: author,
      notes: notes.isNotEmpty ? notes : (existingMeta?.notes ?? ''),
      provenance: provenance ?? existingMeta?.provenance,
    );

    // Atomic file write for draft and metadata
    await _atomicWrite(_draftFile(profileDefinitionId), canonical);
    await _atomicWrite(
      _metadataFile(profileDefinitionId),
      canonicalJson(metadata.toJson()),
    );

    return candidate;
  }

  /// Loads a draft as [LocalDraftProfileCandidate], or returns null if not found.
  Future<LocalDraftProfileCandidate?> loadDraft(
      String profileDefinitionId) async {
    final file = _draftFile(profileDefinitionId);
    if (!await file.exists()) return null;
    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, Object?>;
    return LocalDraftProfileCandidate.fromProfileMap(json);
  }

  /// Saves an editor recovery buffer without validating or publishing it.
  ///
  /// Recovery buffers intentionally live outside [draft.json]. They may contain
  /// incomplete JSON and are never considered a draft, test result, or Cloud
  /// publication candidate until a developer explicitly restores and saves
  /// them.
  Future<void> saveRecoverySnapshot({
    required String profileDefinitionId,
    required String jsonText,
    int keep = 5,
  }) async {
    final dir = _recoveryDir(profileDefinitionId);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      await _enforcePermissions(dir, isDirectory: true);
    }
    final filename = '${DateTime.now().toUtc().microsecondsSinceEpoch}.json';
    final file = File('${dir.path}/$filename');
    await _atomicWrite(file, jsonText);

    final snapshots = (await dir.list().toList())
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final removeCount = snapshots.length - keep;
    for (var index = 0; index < removeCount; index++) {
      await snapshots[index].delete();
    }
  }

  /// Returns the newest recovery buffer, if one exists.
  Future<String?> loadLatestRecoverySnapshot(String profileDefinitionId) async {
    final dir = _recoveryDir(profileDefinitionId);
    if (!await dir.exists()) return null;
    final snapshots = (await dir.list().toList())
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    if (snapshots.isEmpty) return null;
    return snapshots.first.readAsString();
  }

  /// Loads metadata for a draft.
  Future<DraftProfileMetadata?> loadDraftMetadata(
      String profileDefinitionId) async {
    final file = _metadataFile(profileDefinitionId);
    if (!await file.exists()) return null;
    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, Object?>;
    return DraftProfileMetadata.fromJson(json);
  }

  /// Deletes a draft and all associated metadata and evidence.
  Future<bool> deleteDraft(String profileDefinitionId) async {
    final dir = _definitionDir(profileDefinitionId);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      return true;
    }
    return false;
  }

  /// Saves a test execution evidence record attached to (profileDefinitionId, payloadDigest).
  Future<void> saveEvidence({
    required String profileDefinitionId,
    required String payloadDigest,
    required Map<String, Object?> evidenceRecord,
  }) async {
    final evDir = _evidenceDir(profileDefinitionId);
    if (!await evDir.exists()) {
      await evDir.create(recursive: true);
      await _enforcePermissions(evDir, isDirectory: true);
    }

    final file = File('${evDir.path}/$payloadDigest.jsonl');
    final line = '${canonicalJson(evidenceRecord)}\n';
    await file.writeAsString(line, mode: FileMode.append, flush: true);
    await _enforcePermissions(file, isDirectory: false);
  }

  /// Loads all evidence records matching this exact payload digest.
  Future<List<Map<String, Object?>>> loadEvidence({
    required String profileDefinitionId,
    required String payloadDigest,
  }) async {
    final file =
        File('${_evidenceDir(profileDefinitionId).path}/$payloadDigest.jsonl');
    if (!await file.exists()) return const [];

    final lines = await file.readAsLines();
    final records = <Map<String, Object?>>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      records.add(jsonDecode(line) as Map<String, Object?>);
    }
    return records;
  }

  /// Clears stale evidence for a given profile definition (optionally retaining the current digest).
  Future<void> clearEvidence({
    required String profileDefinitionId,
    String? retainPayloadDigest,
  }) async {
    final evDir = _evidenceDir(profileDefinitionId);
    if (!await evDir.exists()) return;

    final files = await evDir.list().toList();
    for (final entity in files) {
      if (entity is File && entity.path.endsWith('.jsonl')) {
        final filename = entity.uri.pathSegments.last;
        final digest = filename.substring(0, filename.length - 6);
        if (retainPayloadDigest == null || digest != retainPayloadDigest) {
          await entity.delete();
        }
      }
    }
  }

  Future<void> _atomicWrite(File target, String content) async {
    final tempFile =
        File('${target.path}.tmp_${DateTime.now().microsecondsSinceEpoch}');
    await tempFile.writeAsString(content, flush: true);
    await _enforcePermissions(tempFile, isDirectory: false);
    await tempFile.rename(target.path);
    await _enforcePermissions(target, isDirectory: false);
  }
}
