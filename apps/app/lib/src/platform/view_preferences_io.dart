import 'dart:io';

import 'view_preferences.dart';

ViewPreferencesStore createViewPreferencesStore() {
  // Widget tests create many independent app shells and must not read or write
  // a developer machine's real preferences.
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    String? value;
    return ViewPreferencesStore(
      read: () => value,
      write: (next) => value = next,
    );
  }

  final file = File(_preferencesPath());
  return ViewPreferencesStore(
    read: () => file.existsSync() ? file.readAsStringSync() : null,
    write: (value) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(value, flush: true);
    },
  );
}

String _preferencesPath() {
  final separator = Platform.pathSeparator;
  if (Platform.isWindows) {
    final root = Platform.environment['APPDATA'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    return '$root${separator}Syntila${separator}view-preferences.json';
  }

  final home = Platform.environment['HOME'] ?? Directory.current.path;
  if (Platform.isMacOS) {
    return '$home${separator}Library${separator}Application Support'
        '${separator}Syntila${separator}view-preferences.json';
  }

  final root =
      Platform.environment['XDG_CONFIG_HOME'] ?? '$home$separator.config';
  return '$root${separator}syntila${separator}view-preferences.json';
}
