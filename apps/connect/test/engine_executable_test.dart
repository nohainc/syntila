import 'dart:io';

import 'package:syntila_connect/src/engine_executable.dart';
import 'package:test/test.dart';

void main() {
  for (final os in ['windows', 'linux', 'macos']) {
    test('resolves only the Worker Engine beside Connect on $os', () async {
      final directory = await Directory.systemTemp.createTemp(
        'connect-engine-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = '${directory.path}/syntila-connect';
      final name = os == 'windows' ? 'syntila-worker.exe' : 'syntila-worker';
      final oldDirectory = await Directory('${directory.path}/engine').create();
      await File('${oldDirectory.path}/$name').create();
      expect(resolveWorkerEngineExecutable(executable, os), isNull);
      final worker = await File('${directory.path}/$name').create();
      expect(resolveWorkerEngineExecutable(executable, os), worker.path);
      await worker.delete();
      expect(resolveWorkerEngineExecutable(executable, os), isNull);
    });
  }
}
