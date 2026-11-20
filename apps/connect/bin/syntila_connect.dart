import 'dart:io';

import 'package:syntila_connect/syntila_connect.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await WorkerCli().run(arguments);
}
