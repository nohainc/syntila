import 'dart:io';

/// Minimal session persistence under the plugin's data directory, enough to
/// declare `sessionResume`. State is yours to define; keep secrets out.
class SessionStore {
  SessionStore(String dataDirectory) : _root = Directory(dataDirectory);

  final Directory _root;

  File _file(String key) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(key)) {
      throw ArgumentError.value(key, 'key', 'must be an opaque safe key');
    }
    return File('${_root.path}/sessions/$key');
  }

  bool exists(String key) => _file(key).existsSync();

  String? read(String key) {
    final file = _file(key);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  void write(String key, String state) {
    final file = _file(key);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(state, flush: true);
  }

  void delete(String key) {
    final file = _file(key);
    if (file.existsSync()) file.deleteSync();
  }
}
