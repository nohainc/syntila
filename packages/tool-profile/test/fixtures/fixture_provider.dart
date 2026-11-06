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
  // and the file's permissions, then proves the file is readable. Repeated
  // `--allowedTools <name>` pairs are reported and set aside first.
  final allowedTools = <String>[];
  final mcpArguments = <String>[];
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i] == '--allowedTools' && i + 1 < arguments.length) {
      allowedTools.add(arguments[++i]);
    } else {
      mcpArguments.add(arguments[i]);
    }
  }
  if ((mcpArguments.length == 4 ||
          (mcpArguments.length == 5 &&
              mcpArguments[4] == '--strict-mcp-config')) &&
      mcpArguments.first == 'echo' &&
      mcpArguments[2] == '--mcp-config') {
    final text = File(mcpArguments[3]).readAsStringSync();
    final mode = File(mcpArguments[3]).statSync().mode & 0x1ff;
    stdout.writeln(
      'fixture echo: ${mcpArguments[1]} | mcp: $text'
      ' | file: ${mcpArguments[3]} | mode: ${mode.toRadixString(8)}'
      '${mcpArguments.length == 5 ? ' | strict' : ''}'
      ' | allowed: ${allowedTools.join(',')}',
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
