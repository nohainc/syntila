import 'dart:io';
import 'dart:isolate';

import 'package:syntila_plugin_sdk/syntila_plugin_sdk.dart';

Future<void> main(List<String> arguments) async {
  final mcp = arguments.contains('--mcp');
  final positional = arguments.where((a) => a != '--mcp').toList();
  if (positional.length != 2 || arguments.length - positional.length > 1) {
    stderr.writeln(
        'usage: dart run syntila_plugin_sdk:init [--mcp] <directory> <plugin-id>');
    exitCode = 64;
    return;
  }
  try {
    final library = await Isolate.resolvePackageUri(
        Uri.parse('package:syntila_plugin_sdk/syntila_plugin_sdk.dart'));
    if (library == null) throw const FormatException('SDK path unavailable');
    initializePluginDirectory(positional[0], positional[1],
        sdkPath: File.fromUri(library).parent.parent.path, mcp: mcp);
    stdout.writeln(
        'Created ${positional[1]} in ${positional[0]}. See README.md to build and pack.');
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 65;
  } on FileSystemException catch (error) {
    stderr.writeln(error.message);
    exitCode = 74;
  }
}
