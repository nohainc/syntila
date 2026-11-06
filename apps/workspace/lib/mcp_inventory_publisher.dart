import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'mcp_registry.dart';
import 'mcp_service.dart';

/// Builds the sanitized `mcp.inventory` payload with a monotonic revision.
///
/// The revision rises only when the sanitized content changes, and it is kept
/// on disk, so a restarted Service never reuses a revision for different
/// content and Cloud can ignore stale snapshots. The payload holds nothing the
/// Cloud contract forbids (see `McpInventorySchema`); it is information, never
/// authority, and the Workspace still re-checks everything before execution.
class McpInventoryPublisher {
  McpInventoryPublisher(this._service, this._stateFile);

  final McpService _service;
  final File _stateFile;

  /// The payload to publish now, or null when the registry cannot be read
  /// (publishing nothing is safer than publishing an empty list that would look
  /// like "all servers removed").
  Future<Map<String, Object?>?> snapshot() async {
    final List<Map<String, Object?>> servers;
    try {
      servers = _service.sanitizedInventory();
    } on McpRegistryUnreadable {
      return null;
    } on McpPolicyException {
      return null;
    }
    final digest = sha256.convert(utf8.encode(jsonEncode(servers))).toString();
    var revision = 0;
    String? lastDigest;
    try {
      final stored = jsonDecode(await _stateFile.readAsString());
      if (stored is Map && stored['revision'] is int) {
        revision = stored['revision'] as int;
        lastDigest = stored['digest'] as String?;
      }
    } on Object {
      // First run, or an unreadable file: start above any value we could have
      // used by falling back to a time-derived floor.
      revision = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      lastDigest = null;
    }
    if (digest != lastDigest) {
      revision += 1;
      await _stateFile.parent.create(recursive: true);
      final temp = File('${_stateFile.path}.tmp');
      await temp.writeAsString(
        jsonEncode({'revision': revision, 'digest': digest}),
        flush: true,
      );
      await temp.rename(_stateFile.path);
    }
    return {'schemaVersion': 1, 'revision': revision, 'servers': servers};
  }
}
