import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'external_worker_store.dart';

/// Executes inspection through the Engine, never by launching a Worker here.
class McpEngineInspection {
  McpEngineInspection(
      {required this.locateEngine,
      required this.workingDirectory,
      this.timeout = const Duration(seconds: 45)});
  final ({String executable, List<String> argumentsPrefix})? Function()
      locateEngine;
  final Directory workingDirectory;
  final Duration timeout;
  static const _inherited = {
    'PATH',
    'HOME',
    'LANG',
    'TMPDIR',
    'TEMP',
    'TMP',
    'SYSTEMROOT',
    'USERPROFILE',
    'APPDATA',
    'LOCALAPPDATA'
  };

  Future<List<Map<String, Object?>>> run(
      String serverId, Map<String, Object?> request) async {
    final engine = locateEngine();
    if (engine == null)
      throw const ExternalWorkerException(
          'mcp_probe_failed', 'The Worker Engine is not available.');
    await workingDirectory.create(recursive: true);
    final process = await Process.start(
        engine.executable, [...engine.argumentsPrefix, '--mcp-probe'],
        workingDirectory: workingDirectory.path,
        environment: {
          for (final e in Platform.environment.entries)
            if (_inherited.contains(e.key)) e.key: e.value
        },
        includeParentEnvironment: false);
    unawaited(process.stderr.drain<void>().catchError((_) {}));
    process.stdin.writeln(jsonEncode(request));
    await process.stdin.flush();
    await process.stdin.close();
    String line;
    try {
      line = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(timeout);
    } on Object {
      process.kill(ProcessSignal.sigkill);
      throw ExternalWorkerException('mcp_probe_failed',
          'The MCP server "$serverId" could not be inspected.');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      throw const ExternalWorkerException('mcp_probe_failed',
          'The Engine returned an unreadable probe result.');
    }
    if (decoded is! Map || decoded['ok'] != true) {
      throw ExternalWorkerException(
          decoded is Map ? '${decoded['code']}' : 'mcp_probe_failed',
          decoded is Map ? '${decoded['message']}' : 'Probe failed.');
    }
    if (decoded['tools'] is! List)
      throw const ExternalWorkerException(
          'mcp_probe_failed', 'The Engine returned invalid tools.');
    return [
      for (final tool in decoded['tools'] as List)
        Map<String, Object?>.from(tool as Map)
    ];
  }

  Future<List<Map<String, Object?>>> inspectWorker(
      InstalledExternalWorker plugin,
      {Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final access =
        Map<String, Object?>.from(plugin.manifest.raw['access'] as Map);
    final names = List<String>.from(access['env'] as List);
    final launch = McpServerLaunch(
        name: plugin.pluginId,
        command: plugin.executablePath,
        arguments: plugin.artifact.args,
        environment: {
          for (final name in names)
            if (env[name] != null) name: env[name]!
        });
    return run(plugin.pluginId, {
      'server': launch.toJson(),
      'commandSha256': plugin.artifactDigest,
      'workingDirectory': workingDirectory.path,
      'requireWorkerProfile': true
    });
  }
}

Map<String, String> inspectedToolPins(List<Map<String, Object?>> tools) =>
    ToolPins.fromTools(tools).hashes;

/// Only successful Syntila Worker inspections may be used for execution.
Map<String, String> workerToolPins(List<Map<String, Object?>> tools) {
  final names = tools.map((tool) => tool['name']).toList();
  if (names.any((name) => name is! String || name.isEmpty) ||
      names.toSet().length != names.length ||
      !names.contains('syntila.execute') ||
      !names.contains('syntila.probe')) {
    throw const ExternalWorkerException('plugin_conformance_required',
        'The Worker must advertise both required tools without duplicates.');
  }
  return inspectedToolPins(tools);
}
