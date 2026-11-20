import 'dart:convert';
import 'dart:io';

class AgentConfig {
  const AgentConfig({
    this.maxConcurrent = 1,
    this.autoStart = false,
    this.logLevel = 'info',
  });

  final int maxConcurrent;

  /// Opt-in: start the Agent at login/boot through the OS service manager.
  final bool autoStart;
  final String logLevel;

  static const keys = ['maxConcurrent', 'autoStart', 'logLevel'];

  Map<String, Object?> toJson() => {
    'maxConcurrent': maxConcurrent,
    'autoStart': autoStart,
    'logLevel': logLevel,
  };

  /// Returns a copy with [key] set from [value] text, or throws a
  /// [FormatException] that names what is wrong.
  AgentConfig set(String key, String value) {
    switch (key) {
      case 'maxConcurrent':
        final parsed = int.tryParse(value);
        if (parsed == null || parsed < 1 || parsed > 16) {
          throw const FormatException('maxConcurrent must be 1 to 16');
        }
        return _copy(maxConcurrent: parsed);
      case 'autoStart':
        return _copy(autoStart: _bool(value));
      case 'logLevel':
        if (!const {'error', 'warn', 'info', 'debug'}.contains(value)) {
          throw const FormatException(
            'logLevel must be error, warn, info or debug',
          );
        }
        return _copy(logLevel: value);
      default:
        throw FormatException('unknown setting $key');
    }
  }

  static bool _bool(String value) {
    if (value == 'true') return true;
    if (value == 'false') return false;
    throw const FormatException('the value must be true or false');
  }

  AgentConfig _copy({int? maxConcurrent, bool? autoStart, String? logLevel}) =>
      AgentConfig(
        maxConcurrent: maxConcurrent ?? this.maxConcurrent,
        autoStart: autoStart ?? this.autoStart,
        logLevel: logLevel ?? this.logLevel,
      );

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
