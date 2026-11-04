import 'dart:async';
import 'dart:io';

Future<void> main() async {
  if (!Platform.isWindows) exit(77);
  final system =
      Platform.environment['SystemRoot'] ??
      Platform.environment['SYSTEMROOT'] ??
      r'C:\Windows';
  final children = <Process>[];
  var refused = false;
  try {
    for (var i = 0; i < 70; i++) {
      try {
        final child = await Process.start('$system/System32/ping.exe', [
          '-n',
          '30',
          '127.0.0.1',
        ]);
        children.add(child);
        unawaited(child.stdout.drain<void>());
        unawaited(child.stderr.drain<void>());
      } on ProcessException {
        refused = true;
        break;
      }
    }
    if (!refused) exitCode = 71;
    stdout.writeln(children.length);
  } finally {
    for (final child in children) {
      child.kill();
    }
    await Future.wait(children.map((p) => p.exitCode));
  }
}
