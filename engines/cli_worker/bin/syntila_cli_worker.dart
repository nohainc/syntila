import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import '../lib/src/cli_worker_engine.dart';
import '../lib/src/mcp_probe.dart';
import '../lib/src/plugin_engine.dart';
import '../lib/src/plugin_process_limits.dart';

Future<void> main(List<String> arguments) async {
  setCurrentProcessName('syntila-agent');
  try {
    if (arguments.isNotEmpty && arguments.first == '--plugin-child') {
      await runLimitedPluginChild(arguments);
      return;
    }
    if (arguments.isNotEmpty && arguments.first == mcpProbeFlag) {
      await runMcpProbeMode();
      return;
    }
    initializeWindowsProcessJob();
    if (PluginEngineOptions.isPluginMode(arguments)) {
      await PluginEngine(options: PluginEngineOptions.parse(arguments)).run();
      return;
    }
    final options = EngineOptions.parse(arguments);
    await CliWorkerEngine(options: options).run();
  } on FormatException catch (error) {
    stderr.writeln('CLI Worker Engine configuration error: ${error.message}');
    exitCode = 64;
  } on Object catch (_) {
    stderr.writeln('CLI Worker Engine failed to start');
    exitCode = 70;
  }
}
