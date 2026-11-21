import 'dart:convert';
import 'dart:io';

class AgentConfig {
  const AgentConfig({this.logLevel = 'info'});

  final String logLevel;

  static const keys = ['logLevel'];
  static const logLevels = ['error', 'warn', 'info', 'debug'];

  Map<String, Object?> toJson() => {'logLevel': logLevel};

  /// Returns a copy with [key] set from [value] text, or throws a
  /// [FormatException] that names what is wrong.
  AgentConfig set(String key, String value) {
    switch (key) {
      case 'logLevel':
        if (!logLevels.contains(value)) {
          throw const FormatException(
            'logLevel must be error, warn, info or debug',
          );
        }
        return AgentConfig(logLevel: value);
      default:
        throw FormatException('unknown setting $key');
    }
  }

  static Future<AgentConfig> load(File file) async {
    if (!await file.exists()) return const AgentConfig();
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return const AgentConfig();
    var config = const AgentConfig();
    for (final key in keys) {
      final value = decoded[key];
      if (value == null) continue;
      try {
        config = config.set(key, '$value');
      } on FormatException {
        // A bad stored value falls back to the default for that key.
      }
    }
    return config;
  }

  Future<void> save(File file) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(toJson()), flush: true);
    await temp.rename(file.path);
  }
}
