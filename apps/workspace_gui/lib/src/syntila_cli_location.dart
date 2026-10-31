import 'dart:io';

import 'package:path/path.dart' as p;

/// Finds the `syntila` executable this GUI drives.
///
/// Releases ship the GUI and the CLI in one folder, so either can run on its
/// own:
///
/// ```text
/// syntila/
///   syntila                       CLI + service
///   assets/engines/syntila-agent  Worker Engine
///   Syntila Workspace.app         macOS GUI
///   gui/syntila-workspace-gui     Linux GUI (Flutter bundle)
/// ```
///
/// Order: `SYNTILA_CLI` (development override), the sibling `syntila` in
/// that folder, a CLI embedded in the app by development builds
/// (`Contents/Resources/syntila/syntila`), well-known install locations, then
/// `syntila` on PATH. GUI apps do not inherit the login shell's PATH, hence
/// the explicit locations.
String locateSyntilaCli({
  Map<String, String>? environment,
  String? resolvedExecutable,
  bool? isMacOS,
  bool Function(String path)? exists,
}) {
  final env = environment ?? Platform.environment;
  final isFile = exists ?? (String path) => File(path).existsSync();
  final override = env['SYNTILA_CLI'];
  if (override != null && override.isNotEmpty) return override;

  final executable = resolvedExecutable ?? Platform.resolvedExecutable;
  final macOS = isMacOS ?? Platform.isMacOS;
  final home = env['HOME'] ?? '';
  final exeDir = p.dirname(executable);
  final candidates = [
    if (macOS) ...[
      // <folder>/Syntila Workspace.app/Contents/MacOS/<exe> → <folder>/syntila
      p.join(p.dirname(p.dirname(p.dirname(exeDir))), 'syntila'),
      // Development builds embed the CLI in Contents/Resources/syntila.
      p.join(p.dirname(exeDir), 'Resources', 'syntila', 'syntila'),
    ] else
      // <folder>/gui/syntila-workspace-gui → <folder>/syntila
      p.join(p.dirname(exeDir), 'syntila'),
    if (home.isNotEmpty) p.join(home, '.local', 'bin', 'syntila'),
    if (macOS) '/opt/homebrew/bin/syntila',
    '/usr/local/bin/syntila',
    if (!macOS) '/usr/bin/syntila',
  ];
  for (final candidate in candidates) {
    if (isFile(candidate)) return candidate;
  }
  return 'syntila';
}
