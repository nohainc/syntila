import 'dart:io';

import 'package:syntila_plugin_sdk/syntila_plugin_sdk.dart';

/// `dart run syntila_plugin_sdk:pack <package-directory>`
///
/// Fills the SHA-256 and size of each artifact in plugin.json from the files,
/// validates the manifest and prints its digest, the identity Syntila pins.
void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr
        .writeln('usage: dart run syntila_plugin_sdk:pack <package-directory>');
    exitCode = 64;
    return;
  }
  try {
    final result = packPluginDirectory(arguments.single);
    stdout.writeln(
      'Packed ${result.manifest.pluginId} ${result.manifest.version}',
    );
    stdout.writeln('manifest digest: ${result.digest}');
    for (final entry in result.manifest.artifacts.entries) {
      stdout.writeln(
          '  ${entry.key}: ${entry.value.sha256} (${entry.value.size} bytes)');
    }
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 65;
  }
}
