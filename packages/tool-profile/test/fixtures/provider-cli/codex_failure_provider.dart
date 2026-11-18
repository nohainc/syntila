import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--version')) {
    stdout.writeln('codex-cli 1.2.3');
    return;
  }
  await stdin.drain<void>();
  stdout.writeln(
    jsonEncode({'type': 'thread.started', 'thread_id': 'fixture'}),
  );
  stdout.writeln(
    jsonEncode({
      'type': 'turn.failed',
      'error': {'message': 'permission denied by sandbox'},
    }),
  );
}
