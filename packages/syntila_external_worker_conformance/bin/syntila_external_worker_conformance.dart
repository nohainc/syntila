import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_external_worker_conformance/syntila_external_worker_conformance.dart';
import 'package:syntila_external_worker_protocol/syntila_external_worker_protocol.dart';

/// `dart run syntila_external_worker_conformance -- <package-directory>`
///
/// Author tooling: runs the protocol conformance suite against a plugin
/// package directory (the one containing plugin.json). It spawns the plugin
/// directly, applies no Engine limits or isolation, and registers nothing.
Future<void> main(List<String> arguments) async {
  final json = arguments.contains('--json');
  final positional = arguments.where((a) => !a.startsWith('--')).toList();
  if (positional.length != 1) {
    stderr.writeln(
        'usage: syntila_external_worker_conformance [--json] <package-dir>');
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
  final validation = validateExternalWorkerManifest(
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
  final platform = currentExternalWorkerPlatform();
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
  final launcher = DirectProcessLauncher(
    executable: executable.absolute.path,
    arguments: artifact.args,
  );
  void Function(ConformanceCase)? onCase = json
      ? null
      : (c) => stdout.writeln(
            '${c.status.name.padRight(7)} ${c.id}'
            '${c.detail == null ? '' : '  - ${c.detail}'}',
          );
  // Workers must speak the Syntila MCP Worker profile over stdio.
  final report =
      await McpConformanceRunner(launcher: launcher).run(onCase: onCase);
  if (json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
  } else {
    stdout.writeln('\n${report.passed ? 'PASSED' : 'FAILED'}');
    stdout.writeln(conformanceDisclaimer);
  }
  exitCode = report.passed ? 0 : 1;
}
