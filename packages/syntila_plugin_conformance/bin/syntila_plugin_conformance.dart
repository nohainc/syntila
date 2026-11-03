import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_plugin_conformance/syntila_plugin_conformance.dart';
import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';

/// `dart run syntila_plugin_conformance -- <package-directory>`
///
/// Author tooling: runs the protocol conformance suite against a plugin
/// package directory (the one containing plugin.json). It spawns the plugin
/// directly, applies no Engine limits or isolation, and registers nothing.
Future<void> main(List<String> arguments) async {
  final json = arguments.contains('--json');
  final positional = arguments.where((a) => !a.startsWith('--')).toList();
  if (positional.length != 1) {
    stderr.writeln('usage: syntila_plugin_conformance [--json] <package-dir>');
    exitCode = 64;
    return;
  }
  final directory = Directory(positional.single);
  final manifestFile = File('${directory.path}/plugin.json');
  if (!manifestFile.existsSync()) {
    stderr.writeln('plugin.json was not found in ${directory.path}');
    exitCode = 66;
    return;
  }
  final validation = validatePluginManifest(
    jsonDecode(manifestFile.readAsStringSync()),
  );
  final manifest = validation.manifest;
  if (manifest == null) {
    stderr.writeln('plugin.json is invalid:');
    for (final issue in validation.issues) {
      stderr.writeln('  $issue');
    }
    exitCode = 65;
    return;
  }
  final platform = currentPluginPlatform();
  final artifact = manifest.artifacts[platform] ?? manifest.artifacts['any'];
  if (artifact == null) {
    stderr.writeln('No artifact for this platform ($platform).');
    exitCode = 65;
    return;
  }
  final executable = File('${directory.path}/${artifact.command}');
  final digest = sha256.convert(executable.readAsBytesSync()).toString();
  if (digest != artifact.sha256) {
    stderr.writeln('The artifact does not match the digest in plugin.json.');
    exitCode = 65;
    return;
  }
  final capabilities = Map<String, Object?>.from(
    manifest.raw['capabilities'] as Map,
  );
  final runner = ConformanceRunner(
    launcher: DirectProcessLauncher(
      executable: executable.absolute.path,
      arguments: artifact.args,
    ),
    expectedPluginId: manifest.pluginId,
    expectedVersion: manifest.version,
    declaresResume: capabilities['sessionResume'] == true,
    declaredCapabilities: capabilities,
  );
  final report = await runner.run(
    onCase: json
        ? null
        : (c) => stdout.writeln(
              '${c.status.name.padRight(7)} ${c.id}'
              '${c.detail == null ? '' : '  - ${c.detail}'}',
            ),
  );
  if (json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
  } else {
    stdout.writeln('\n${report.passed ? 'PASSED' : 'FAILED'}');
    stdout.writeln(conformanceDisclaimer);
  }
  exitCode = report.passed ? 0 : 1;
}
