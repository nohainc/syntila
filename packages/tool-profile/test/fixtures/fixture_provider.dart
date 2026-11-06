import 'dart:io';

const version = '0.3.0';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--version') {
    stdout.writeln('fixture-provider $version');
    return;
  }
  if (arguments.length == 1 && arguments.single == 'probe') {
    stdout.writeln('ready');
    return;
  }
  if (arguments.length == 1 && arguments.single == 'usage') {
    stdout.writeln('fixture usage: 0 of 100 requests used');
    return;
  }
  if (arguments.length == 2 && arguments.first == 'echo') {
    if (arguments[1] == 'Reply with exactly the word OK. Do not use tools.') {
      stdout.writeln('OK');
      return;
    }
    stdout.writeln('fixture echo: ${arguments[1]}');
    return;
  }
  // `echo <prompt> --mcp-config <file>` reports the MCP servers it was given
  // and the file's permissions, then proves the file is readable.
  if ((arguments.length == 4 ||
          (arguments.length == 5 && arguments[4] == '--strict-mcp-config')) &&
      arguments.first == 'echo' &&
      arguments[2] == '--mcp-config') {
    final text = File(arguments[3]).readAsStringSync();
    final mode = File(arguments[3]).statSync().mode & 0x1ff;
    stdout.writeln(
      'fixture echo: ${arguments[1]} | mcp: $text'
      ' | file: ${arguments[3]} | mode: ${mode.toRadixString(8)}'
      '${arguments.length == 5 ? ' | strict' : ''}',
    );
    return;
  }
  // `echo <prompt> --add-dir <path>...` reports the folders it was given.
  if (arguments.length > 2 &&
      arguments.first == 'echo' &&
      arguments.length.isEven) {
    final directories = <String>[];
    for (var index = 2; index < arguments.length; index += 2) {
      if (arguments[index] != '--add-dir') break;
      directories.add(arguments[index + 1]);
    }
    if (directories.length == (arguments.length - 2) ~/ 2) {
      stdout.writeln(
        'fixture echo: ${arguments[1]} | dirs: ${directories.join(',')}',
      );
      return;
    }
  }
  if (arguments.length == 1 && arguments.single == 'hang') {
    await Future<void>.delayed(const Duration(seconds: 30));
    return;
  }
  if (arguments.length == 1 && arguments.single == 'flood') {
    for (var index = 0; index < 128; index++) {
      stdout.writeln('x' * 65536);
      await stdout.flush();
    }
    return;
  }
  if (arguments.length == 1 && arguments.single == 'stderr-flood') {
    for (var index = 0; index < 128; index++) {
      stderr.writeln('x' * 65536);
      await stderr.flush();
    }
    return;
  }
  stderr.writeln('unsupported fixture-provider command');
  exitCode = 2;
}
