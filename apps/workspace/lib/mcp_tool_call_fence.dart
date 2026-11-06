import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'durable_sync.dart';

/// Persistent local at-most-once dispatch fence. Keys must identify a logical
/// workflow step across attempts, not an assignment or attempt. Markers are
/// never removed automatically, including when the eventual outcome is known.
/// This is not a distributed fence: Cloud must bind all attempts for a key to
/// the same Workspace and enforce its own durable dispatch policy.
///
/// Durability: [claim] returns true only after the marker's contents and the
/// directory entries that name it have been synced to stable storage (see
/// `durable_sync.dart`), because the caller sends the request right after. If
/// any step fails the marker stays and the error propagates, so the caller
/// reports an unknown outcome and never dispatches.
///
/// Outcomes: [recordOutcome] keeps the first terminal outcome beside the
/// marker so a restarted Service can show what happened instead of a bare
/// "claimed". A marker without a readable outcome means the result is
/// uncertain; it is never a licence to call again.
class McpToolCallFence {
  McpToolCallFence(this.directory, {DurablePathSync? sync})
      : _sync = sync ?? syncPathDurably;

  final Directory directory;
  final DurablePathSync _sync;

  /// Returns false if this key has already been claimed. An empty or partial
  /// marker is a claim too: a crash can occur immediately after creation.
  Future<bool> claim(String key) async {
    if (key.isEmpty || key.length > 1024) {
      throw const FormatException('Invalid MCP dispatch key');
    }
    await directory.create(recursive: true);
    final name = sha256.convert(utf8.encode(key)).toString();
    final marker = File('${directory.path}/$name');
    try {
      await marker.create(exclusive: true);
    } on FileSystemException {
      if (await FileSystemEntity.type(marker.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return false;
      }
      rethrow;
    }
    // Flush an explicit marker. Failure never removes it; the caller must
    // treat the outcome as unknown rather than retrying the call.
    await marker.writeAsString('claimed\n', flush: true);
    await _sync(marker.path, directory: false);
    await _sync(directory.path, directory: true);
    await _sync(directory.parent.path, directory: true);
    return true;
  }

  File _outcomeFile(String key) => File(
      '${directory.path}/${sha256.convert(utf8.encode(key))}.outcome.json');

  /// Records [state] and [code] (and a bounded [result]) for a claimed key.
  /// The first outcome wins; later calls return false and change nothing.
  Future<bool> recordOutcome(
    String key, {
    required String state,
    required String code,
    Map<String, Object?>? result,
  }) async {
    final file = _outcomeFile(key);
    try {
      await file.create(exclusive: true);
    } on FileSystemException {
      if (await file.exists()) return false;
      rethrow;
    }
    await file.writeAsString(
      jsonEncode({
        'state': state,
        'code': code,
        'recordedAt': DateTime.now().toUtc().toIso8601String(),
        if (result != null) 'result': result,
      }),
      flush: true,
    );
    await _sync(file.path, directory: false);
    await _sync(directory.path, directory: true);
    return true;
  }

  /// The recorded outcome, or null when none is readable.
  Future<Map<String, Object?>?> recordedOutcome(String key) async {
    final file = _outcomeFile(key);
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map ||
          !const {'completed', 'toolError', 'rejected', 'unknown'}
              .contains(decoded['state']) ||
          decoded['code'] is! String) {
        return null;
      }
      return Map<String, Object?>.from(decoded);
    } on Object {
      return null;
    }
  }

  /// Whether [key] was ever claimed, without claiming it.
  Future<bool> wasClaimed(String key) async =>
      await FileSystemEntity.type(
        '${directory.path}/${sha256.convert(utf8.encode(key))}',
        followLinks: false,
      ) !=
      FileSystemEntityType.notFound;
}
