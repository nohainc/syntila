import 'dart:io';

import 'package:path/path.dart' as p;

/// Finds the `syntila` executable this GUI drives.
///
/// Order: `SYNTILA_CLI` (development override), the CLI bundled in the app
/// (`Contents/Resources/syntila/syntila` on macOS, next to its Worker
/// Engine), then well-known install
/// locations, then `syntila` on PATH. GUI apps do not inherit the login
/// shell's PATH, hence the explicit locations.
String locateSyntilaCli({
  Map<String, String>? environment,
  String? resolvedExecutable,
  bool Function(String path)? exists,
}) {
  final env = environment ?? Platform.environment;
  final isFile = exists ?? (String path) => File(path).existsSync();
  final override = env['SYNTILA_CLI'];
  if (override != null && override.isNotEmpty) return override;

  final executable = resolvedExecutable ?? Platform.resolvedExecutable;
  final home = env['HOME'] ?? '';
  final candidates = [
    // <App>.app/Contents/MacOS/<exe> → <App>.app/Contents/Resources/syntila
    p.join(p.dirname(p.dirname(executable)), 'Resources', 'syntila', 'syntila'),
    if (home.isNotEmpty) p.join(home, '.local', 'bin', 'syntila'),
    '/opt/homebrew/bin/syntila',
    '/usr/local/bin/syntila',
  ];
  for (final candidate in candidates) {
    if (isFile(candidate)) return candidate;
  }
  return 'syntila';
}
