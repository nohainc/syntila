import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

import 'plugin_store.dart';

/// The Local Worker Protocol 4.2 executor for an installed plugin. Everything
/// comes from the Service's own verified store; Cloud never supplies a path.
WorkerExecutor workerExecutorFor(
  InstalledPlugin plugin,
  Directory dataDirectory,
) {
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
  );
}
