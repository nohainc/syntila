import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Persistent local at-most-once dispatch fence. Keys must identify a logical
/// workflow step across attempts, not an assignment or attempt. Markers are
/// never removed automatically, including when the eventual outcome is known.
/// This is not a distributed fence: Cloud must bind all attempts for a key to
/// the same Workspace and enforce its own durable dispatch policy.
class McpToolCallFence {
  McpToolCallFence(this.directory);

  final Directory directory;

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
    return true;
  }
}
