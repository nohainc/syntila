import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'worker_session.dart';

/// The local session record is ahead of the canonical context Cloud sent for
/// this turn (for example after a Cloud database reset or a cancelled turn
/// whose revision Cloud never committed). Cloud is the source of truth, so the
/// engine quarantines the local record and rebuilds the session.
const staleSessionAheadOfCloudMessage =
    'Worker Session contains context newer than this turn';

/// Local logical-session mapping. Provider session IDs never cross Protocol 4.0.
class EngineSessionStore {
  const EngineSessionStore(this.directory);

  final Directory directory;

  static final _heldExecutionLocks = <String>{};

  /// Hold the native session scope for the entire provider invocation. OS locks
  /// release on process exit; persistent lock files are never deleted or treated
  /// as ownership evidence. The in-process set covers separate Engine instances.
  Future<EngineSessionLease> acquireExecution({
    required String sessionKey,
    required String workerTypeId,
    required String profileDefinitionId,
    required String providerToolIdentity,
  }) async {
    await directory.create(recursive: true);
    final root = await directory.resolveSymbolicLinks();
    final stateFile = _file(
      sessionKey,
      workerTypeId,
      profileDefinitionId,
      providerToolIdentity,
    );
    final locks = Directory('$root${Platform.pathSeparator}.session-locks');
    if (await FileSystemEntity.type(locks.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException(
        'Session lock directory cannot be a symbolic link',
      );
    }
    await locks.create();
    if (await locks.resolveSymbolicLinks() != locks.path) {
      throw const FormatException('Session lock directory escaped local state');
    }
    final name = stateFile.uri.pathSegments.last;
    final file = File('${locks.path}${Platform.pathSeparator}$name.lock');
    await _assertContained(file, allowMissing: true);
    if (!_heldExecutionLocks.add(file.path)) throw const EngineSessionBusy();
    RandomAccessFile? handle;
    try {
      handle = await file.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
      } on FileSystemException {
        throw const EngineSessionBusy();
      }
      return EngineSessionLease(
        handle,
        () => _heldExecutionLocks.remove(file.path),
      );
    } catch (_) {
      await handle?.close();
      _heldExecutionLocks.remove(file.path);
      rethrow;
    }
  }

  Future<String?> read({
    required String sessionKey,
    required String workerTypeId,
    required String profileDefinitionId,
    required String providerToolIdentity,
    required List<String> compatibleFormatIds,
    WorkerSessionContext? workerSession,
    bool modelSwitchSupported = true,
    String? requestedModelId,
    String? requestedEffort,
    bool effortChangesNativeModel = false,
    bool allowModelReconstruction = false,
    bool allowContextSynchronization = false,
    String? executionPolicy,
    bool executionPolicyBound = false,
    void Function(WorkerSession)? onSessionRead,
  }) async {
    final file = _file(
      sessionKey,
      workerTypeId,
      profileDefinitionId,
      providerToolIdentity,
    );
    if (!await file.exists()) return null;
    await _assertContained(file);
    if (await file.length() > 8192) {
      throw const FormatException('Engine session state exceeds its limit');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map ||
        !const {1, 2}.contains(decoded['version']) ||
        decoded['sessionKey'] != sessionKey ||
        decoded['workerTypeId'] != workerTypeId ||
        decoded['profileDefinitionId'] != profileDefinitionId ||
        decoded['providerToolIdentity'] != providerToolIdentity ||
        decoded['profileReleaseVersion'] is! int ||
        decoded['profileReleaseVersion'] < 1 ||
        decoded['sessionFormatId'] is! String ||
        !_validFormatId(decoded['sessionFormatId'] as String) ||
        decoded['sessionId'] is! String ||
        !_validSessionId(decoded['sessionId'] as String)) {
      throw const FormatException('Engine session state is invalid');
    }
    if (decoded['version'] == 2) {
      final raw = decoded['workerSession'];
      if (raw is! Map)
        throw const FormatException('Missing local Worker Session');
      final stored = WorkerSession.fromJson(Map<String, Object?>.from(raw));
      if (stored.nativeSessionId != decoded['sessionId'] ||
          stored.profileId != profileDefinitionId ||
          stored.profileVersion != decoded['profileReleaseVersion']) {
        throw const FormatException(
          'Local Worker Session attribution mismatch',
        );
      }
      if (workerSession == null ||
          stored.id != workerSession.id ||
          stored.conversationId != workerSession.conversationId ||
          stored.workerId != workerSession.workerId) {
        throw const FormatException(
          'Worker Session belongs to another Conversation or Worker',
        );
      }
      // Separate effort is per turn. Combined effort variants select a native
      // model and must respect the same model-switch contract.
      if (stored.synchronizedContextRevision >
          workerSession.baseContextRevision) {
        throw const FormatException(staleSessionAheadOfCloudMessage);
      }
      onSessionRead?.call(stored);
      if (stored.status == 'invalidated') return null;
      if (!modelSwitchSupported &&
          (stored.lastModelId != requestedModelId ||
              (effortChangesNativeModel &&
                  stored.lastEffort != requestedEffort))) {
        if (allowModelReconstruction) return null;
        throw const FormatException(
          'Profile does not support changing model within this Worker Session',
        );
      }
      if (stored.status != 'active' &&
          stored.synchronizedContextRevision ==
              workerSession.baseContextRevision &&
          allowContextSynchronization) {
        return null; // An inactive equal-revision record cannot certify resume.
      }
      if ((stored.status != 'active' ||
              stored.synchronizedContextRevision <
                  workerSession.baseContextRevision) &&
          !allowContextSynchronization) {
        throw const FormatException(
          'Worker Session requires context synchronization',
        );
      }
    }
    if (decoded['version'] == 1 &&
        workerSession?.bootstrap?.turnRevision != null) {
      // Old records cannot certify which canonical turns were consumed.
      return null;
    }
    if (decoded['version'] == 1 &&
        (workerSession?.baseContextRevision ?? 0) > 0) {
      throw const FormatException(
        'Worker Session context attribution is unavailable',
      );
    }
    if (decoded['version'] == 1 && !modelSwitchSupported) {
      throw const FormatException(
        'Worker Session model attribution is unavailable for this Profile',
      );
    }
    // Some providers fix the sandbox when a native session is created and
    // refuse to resume it under another one. For those Profiles a policy
    // change starts a fresh native session from the canonical bootstrap.
    if (executionPolicyBound && decoded['executionPolicy'] != executionPolicy) {
      if (allowModelReconstruction) return null;
      throw const FormatException(
        'Profile does not support changing the execution policy within this '
        'Worker Session',
      );
    }
    final storedFormat = decoded['sessionFormatId'] as String;
    if (!compatibleFormatIds.contains(storedFormat)) return null;
    return decoded['sessionId'] as String;
  }

  /// Invalidate only the native handle read by this execution. Retain local
  /// attribution for diagnostics; a concurrent replacement must never be erased.
  Future<bool> invalidate({
    required String sessionKey,
    required String workerTypeId,
    required String profileDefinitionId,
    required String providerToolIdentity,
    required String expectedNativeSessionId,
  }) async {
    final file = _file(
      sessionKey,
      workerTypeId,
      profileDefinitionId,
      providerToolIdentity,
    );
    if (!await file.exists()) return false;
    await _assertContained(file);
    if (await file.length() > 8192)
      throw const FormatException('Session state exceeds its limit');
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (decoded['sessionId'] != expectedNativeSessionId) return false;
    if (decoded['workerSession'] is Map) {
      (decoded['workerSession'] as Map)['status'] = 'invalidated';
      await file.writeAsString(jsonEncode(decoded));
    } else {
      await file.delete();
    }
    return true;
  }

  /// Moves a malformed local mapping aside so a canonical Conversation
  /// bootstrap can safely rebuild it. The native handle remains local and is
  /// never sent across a protocol boundary; keeping the quarantined file also
  /// gives local diagnostics a recoverable record instead of silently deleting
  /// state.
  Future<bool> quarantine({
    required String sessionKey,
    required String workerTypeId,
    required String profileDefinitionId,
    required String providerToolIdentity,
  }) async {
    final file = _file(
      sessionKey,
      workerTypeId,
      profileDefinitionId,
      providerToolIdentity,
    );
    if (!await file.exists()) return false;
    await _assertContained(file);
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final destination = File('${file.path}.recovery-$stamp');
    await _assertContained(destination, allowMissing: true);
    await file.rename(destination.path);
    return true;
  }

  Future<void> write({
    required String sessionKey,
    required String workerTypeId,
    required String profileDefinitionId,
    required String providerToolIdentity,
    required int profileReleaseVersion,
    required String sessionFormatId,
    required String sessionId,
    WorkerSessionContext? workerSession,
    String? modelId,
    String? effort,
    int? synchronizedContextRevision,
    int? synchronizedHistorySequence,
    String? executionPolicy,
  }) async {
    if (!_validSessionId(sessionId) ||
        !_validFormatId(sessionFormatId) ||
        profileReleaseVersion < 1) {
      throw const FormatException('provider session identity is out of bounds');
    }
    await directory.create(recursive: true);
    final file = _file(
      sessionKey,
      workerTypeId,
      profileDefinitionId,
      providerToolIdentity,
    );
    await _assertContained(file, allowMissing: true);
    WorkerSession? session;
    if (workerSession != null) {
      final now = DateTime.now().toUtc().toIso8601String();
      WorkerSession? previous;
      if (await file.exists()) {
        if (await file.length() > 8192) {
          throw const FormatException('Engine session state exceeds its limit');
        }
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && decoded['workerSession'] is Map) {
          previous = WorkerSession.fromJson(
            Map<String, Object?>.from(decoded['workerSession'] as Map),
          );
          if (previous.id != workerSession.id ||
              previous.conversationId != workerSession.conversationId ||
              previous.workerId != workerSession.workerId) {
            throw const FormatException(
              'Worker Session scope cannot be rewritten',
            );
          }
        }
      }
      final consumedRevision =
          workerSession.bootstrap?.turnRevision ??
          workerSession.baseContextRevision;
      if (synchronizedContextRevision != null &&
          synchronizedContextRevision != consumedRevision) {
        throw const FormatException('Invalid bootstrap synchronized revision');
      }
      final synchronizedRevision =
          synchronizedContextRevision ??
          previous?.synchronizedContextRevision ??
          0;
      final historySequence =
          synchronizedHistorySequence ??
          previous?.synchronizedHistorySequence ??
          0;
      if (synchronizedRevision < 0 ||
          synchronizedRevision > 9007199254740991 ||
          historySequence < 0 ||
          historySequence > 9007199254740991 ||
          synchronizedRevision < (previous?.synchronizedContextRevision ?? 0) ||
          historySequence < (previous?.synchronizedHistorySequence ?? 0)) {
        throw const FormatException(
          'Worker Session synchronization cannot decrease or exceed its bounds',
        );
      }
      if (synchronizedHistorySequence != null &&
          workerSession.bootstrap != null &&
          synchronizedHistorySequence !=
              workerSession.bootstrap!.throughSequence) {
        throw const FormatException(
          'History watermark does not match consumed context',
        );
      }
      session = WorkerSession(
        synchronizedHistorySequence: historySequence,
        id: workerSession.id,
        conversationId: workerSession.conversationId,
        workerId: workerSession.workerId,
        profileId: profileDefinitionId,
        profileVersion: profileReleaseVersion,
        nativeSessionId: sessionId,
        synchronizedContextRevision: synchronizedRevision,
        status: synchronizedRevision < workerSession.baseContextRevision
            ? 'requires_synchronization'
            : 'active',
        lastModelId: modelId,
        lastEffort: effort,
        createdAt: previous?.createdAt ?? now,
        lastUsedAt: now,
      );
    }
    final temporary = File(
      '${file.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsString(
        jsonEncode({
          'version': workerSession == null ? 1 : 2,
          if (session != null) 'workerSession': session.toJson(),
          'sessionKey': sessionKey,
          'workerTypeId': workerTypeId,
          'profileDefinitionId': profileDefinitionId,
          'providerToolIdentity': providerToolIdentity,
          'profileReleaseVersion': profileReleaseVersion,
          'sessionFormatId': sessionFormatId,
          'sessionId': sessionId,
          if (executionPolicy != null) 'executionPolicy': executionPolicy,
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _assertContained(File file, {bool allowMissing = false}) async {
    final root = await directory.resolveSymbolicLinks();
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException(
        'Engine session state cannot be a symbolic link',
      );
    }
    if (allowMissing && !await file.exists()) return;
    final resolved = await file.resolveSymbolicLinks();
    if (!resolved.startsWith('$root${Platform.pathSeparator}')) {
      throw const FormatException('Engine session state escaped its directory');
    }
  }

  File _file(
    String sessionKey,
    String workerTypeId,
    String profileDefinitionId,
    String providerToolIdentity,
  ) {
    if (sessionKey.isEmpty ||
        sessionKey.length > 256 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sessionKey) ||
        !_validIdentity(workerTypeId) ||
        !_validIdentity(profileDefinitionId) ||
        providerToolIdentity.isEmpty ||
        providerToolIdentity.length > 128) {
      throw const FormatException('session scope has an invalid format');
    }
    final scopeDigest = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              workerTypeId,
              profileDefinitionId,
              providerToolIdentity,
              sessionKey,
            ]),
          ),
        )
        .toString();
    return File(
      '${directory.path}${Platform.pathSeparator}session-$scopeDigest.json',
    );
  }
}

class EngineSessionBusy implements Exception {
  const EngineSessionBusy();
}

class EngineSessionLease {
  EngineSessionLease(this._handle, this._released);
  final RandomAccessFile _handle;
  final void Function() _released;
  bool _closed = false;
  Future<void> release() async {
    if (_closed) return;
    _closed = true;
    try {
      await _handle.close();
    } finally {
      _released();
    }
  }
}

bool _validIdentity(String value) =>
    value.length <= 96 &&
    RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(value);

bool _validFormatId(String value) =>
    value.length <= 96 &&
    RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(value);

bool _validSessionId(String value) =>
    value.length <= 256 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
