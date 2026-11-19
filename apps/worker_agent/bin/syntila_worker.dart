import 'dart:io';

import 'package:syntila_worker_agent/syntila_worker_agent.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await WorkerCli().run(arguments);
}
