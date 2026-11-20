import 'dart:convert';
import 'dart:io';

/// Per-Thread fencing tokens (ADR-040). A stateful assignment carries the
/// fencing token of the Thread lease its Worker holds. The Agent remembers the
/// highest token it has accepted for each Thread and refuses a lower one, so a
/// superseded lease holder can never write after a newer one has started.
class ThreadFence {
  ThreadFence(this.file);

  final File file;
  static final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$');

  Future<Map<String, int>> _read() async {
    if (!await file.exists()) return {};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is int)
            e.key as String: e.value as int,
      };
    } on FormatException {
      // An unreadable file must not lower the fence: refuse everything.
      throw const FormatException('thread fence file is unreadable');
    }
  }

  /// Accepts [token] for [threadId] when it is not lower than the highest seen,
  /// and records it. Returns false for a stale token.
  Future<bool> admit(String threadId, int token) async {
    if (!_safeId.hasMatch(threadId) || token < 1) return false;
    final seen = await _read();
    final highest = seen[threadId] ?? 0;
    if (token < highest) return false;
    if (token > highest) {
      seen[threadId] = token;
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(seen), flush: true);
      await temp.rename(file.path);
    }
    return true;
  }
}
