import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

import 'plugin_store.dart';

/// The Local Worker Protocol 4.2 executor for an installed plugin. Everything
/// comes from the Service's own verified store; Cloud never supplies a path.
///
/// An MCP Worker (manifest `kind: "mcp"`) needs [toolPins], the consented tool
/// definition hashes; without them there is no executor to build.
WorkerExecutor workerExecutorFor(
  InstalledPlugin plugin,
  Directory dataDirectory, {
  Map<String, String>? toolPins,
}) {
  final mcp = plugin.manifest.isMcp;
  if (mcp && (toolPins == null || toolPins.isEmpty)) {
    throw StateError('An MCP Worker needs consented tool pins');
  }
  final access =
      Map<String, Object?>.from(plugin.manifest.raw['access'] as Map);
  return WorkerExecutor(
    pluginId: plugin.pluginId,
    version: plugin.version,
    manifestDigest: plugin.manifestDigest,
    artifactSha256: plugin.artifactDigest,
    executable: plugin.executablePath,
    dataDirectory: dataDirectory.path,
    arguments: plugin.artifact.args,
    environmentNames: List<String>.from(access['env'] as List),
    protocol: mcp ? 'mcp' : 'ndjson',
    toolPins: mcp ? toolPins! : const {},
  );
}

/// True for a Cloud-allocated plugin Worker Type ID (`plugin-` + 12 hex).
bool isPluginWorkerType(String workerTypeId) =>
    RegExp(r'^plugin-[0-9a-f]{12}$').hasMatch(workerTypeId);
