import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';

import 'plugin_executor.dart';
import 'plugin_service.dart';
import 'plugin_store.dart';

/// Runs the conformance suite through the supervised plugin-mode Engine. The
/// Service never starts a plugin; the Engine does, under the same digest pin,
/// environment and process-tree rules as production runs.
class EnginePluginConformance implements PluginConformancePort {
  EnginePluginConformance({
    required this.supervisor,
    required this.store,
    required this.engineStateDirectory,
  });

  final CliWorkerEngineSupervisor supervisor;
  final PluginStore store;
  final Directory Function(String pluginId) engineStateDirectory;

  @override
  Future<Map<String, Object?>> run(
    InstalledPlugin plugin, {
    required String workerTypeId,
    required bool declaresResume,
    required Map<String, Object?> declaredCapabilities,
    void Function(String progress)? onProgress,
  }) async {
    try {
      final result = await supervisor.conformance(
        pluginExecutor: workerExecutorFor(
          plugin,
          store.dataDirectory(plugin.pluginId),
        ),
        pluginWorkerTypeId: workerTypeId,
        stateDirectory: engineStateDirectory(plugin.pluginId),
        declaresResume: declaresResume,
        declaredCapabilities: declaredCapabilities,
        onProgress: onProgress == null
            ? null
            : (progress) {
                final message = progress.message;
                if (message != null) onProgress(message);
              },
      );
      return {
        'suiteVersion': result.suiteVersion,
        'protocol': result.protocol,
        'passed': result.passed,
        'cases': [for (final c in result.cases) c.toJson()],
      };
    } on CliWorkerEngineProbeException catch (error) {
      final code =
          error.localDiagnostics?.contains('plugin_digest_mismatch') == true
              ? 'plugin_digest_mismatch'
              : 'plugin_conformance_failed';
      throw PluginServiceException(code, error.safeMessage);
    }
  }
}
