import 'dart:convert';

import 'ax_thread_view_state.dart';
import 'ax_thread_view_state_store_base.dart';

/// Synchronous string storage such as the browser's `localStorage`.
abstract interface class AxKeyValueStorage {
  String? get(String key);

  /// May throw when storage is full or disabled.
  void set(String key, String value);
  void remove(String key);
  List<String> keys();
}

/// Thread view state in a [AxKeyValueStorage], one entry per part: the
/// device-local view (tab, pane, markers, choices) and each draft. An instance
/// writes only the parts it changed since it last read or wrote them, so
/// another tab's newer draft survives a save made for an unrelated change.
class KeyValueAxThreadViewStateStore implements AxThreadViewStateStore {
  KeyValueAxThreadViewStateStore(this._storage);

  static const _prefix = 'syntila-thread-view-v2:';

  /// Single-blob entries of earlier builds, which can hold large drafts.
  static const _legacyPrefix = 'syntila-thread-view-v1:';

  final AxKeyValueStorage _storage;

  /// The value this instance last read or wrote for a key (null: absent), so
  /// an unchanged part is not written over another tab's newer copy.
  final _seen = <String, String?>{};

  /// Parts the storage refused, so a reload in this page sees the newest
  /// values rather than an older stored copy. An empty value means removed.
  final _unsaved = <String, String>{};
  var _legacyPurged = false;

  String _base(String userId, String threadId) =>
      '$_prefix${Uri.encodeComponent(userId)}:${Uri.encodeComponent(threadId)}';

  String? _read(String key) {
    final unsaved = _unsaved[key];
    final value = unsaved ?? _readStorage(key);
    return value == null || value.isEmpty ? null : value;
  }

  String? _readStorage(String key) {
    try {
      return _storage.get(key);
    } catch (_) {
      return null;
    }
  }

  @override
  AxThreadViewState? loadSync({
    required String userId,
    required String threadId,
  }) {
    final base = _base(userId, threadId);
    final meta = _read('$base#meta');
    final chat = _read('$base#chat');
    final work = _read('$base#work');
    _seen['$base#meta'] = meta;
    _seen['$base#chat'] = chat;
    _seen['$base#work'] = work;
    if (meta == null && chat == null && work == null) return null;
    Map<String, dynamic> json = {};
    if (meta != null) {
      try {
        final decoded = jsonDecode(meta);
        if (decoded is Map) json = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    if (chat != null) json['chatDraft'] = chat;
    if (work != null) json['workDraft'] = work;
    return AxThreadViewState.fromJson(json);
  }

  @override
  Future<AxThreadViewState?> load({
    required String userId,
    required String threadId,
  }) async =>
      loadSync(userId: userId, threadId: threadId);

  @override
  Future<void> save({
    required String userId,
    required String threadId,
    required AxThreadViewState state,
  }) async {
    _purgeLegacy();
    final base = _base(userId, threadId);
    final json = state.toJson();
    final chat = json.remove('chatDraft') as String?;
    final work = json.remove('workDraft') as String?;
    _write('$base#meta', jsonEncode(json));
    _write('$base#chat', chat);
    _write('$base#work', work);
  }

  void _write(String key, String? value) {
    final normalized = value == null || value.isEmpty ? null : value;
    if (_seen.containsKey(key) && _seen[key] == normalized) return;
    try {
      if (normalized == null) {
        _storage.remove(key);
      } else {
        _storage.set(key, normalized);
      }
      _unsaved.remove(key);
    } catch (_) {
      // Storage can be disabled or full; keep the newest copy in memory.
      _unsaved[key] = normalized ?? '';
    }
    _seen[key] = normalized;
  }

  /// Entries of the single-blob format are never read again; drop them once so
  /// they stop using the browser's quota.
  void _purgeLegacy() {
    if (_legacyPurged) return;
    _legacyPurged = true;
    _removeWhere((key) => key.startsWith(_legacyPrefix));
  }

  void _removeWhere(bool Function(String key) test) {
    try {
      for (final key in _storage.keys().where(test).toList()) {
        _storage.remove(key);
      }
    } catch (_) {
      // Best effort; no server state is affected.
    }
  }

  @override
  Future<void> remove({
    required String userId,
    required String threadId,
  }) async {
    final base = _base(userId, threadId);
    for (final key in ['$base#meta', '$base#chat', '$base#work']) {
      _seen.remove(key);
      _unsaved.remove(key);
      try {
        _storage.remove(key);
      } catch (_) {}
    }
  }

  @override
  Future<void> clearUser(String userId) async {
    final userPrefix = '$_prefix${Uri.encodeComponent(userId)}:';
    _seen.removeWhere((key, _) => key.startsWith(userPrefix));
    _unsaved.removeWhere((key, _) => key.startsWith(userPrefix));
    _removeWhere((key) =>
        key.startsWith(userPrefix) ||
        key.startsWith('$_legacyPrefix${Uri.encodeComponent(userId)}:'));
  }

  @override
  void dispose() {}
}
