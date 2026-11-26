import 'dart:io';

import 'package:path/path.dart' as p;

/// Finds the Worker Engine alongside the running Connect CLI.
String? resolveWorkerEngineExecutable(
  String connectExecutable,
  String operatingSystem,
) {
  final name = operatingSystem == 'windows'
      ? 'syntila-worker.exe'
      : 'syntila-worker';
  final candidate = p.join(File(connectExecutable).parent.path, name);
  return File(candidate).existsSync() ? candidate : null;
}
