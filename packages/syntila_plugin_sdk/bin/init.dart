import 'dart:io';
import 'dart:isolate';

import 'package:syntila_plugin_sdk/syntila_plugin_sdk.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
        'usage: dart run syntila_plugin_sdk:init <directory> <plugin-id>');
    exitCode = 64;
    return;
  }
  try {
    final library = await Isolate.resolvePackageUri(
        Uri.parse('package:syntila_plugin_sdk/syntila_plugin_sdk.dart'));
    if (library == null) throw const FormatException('SDK path unavailable');
    initializePluginDirectory(arguments[0], arguments[1],
        sdkPath: File.fromUri(library).parent.parent.path);
    stdout.writeln(
        'Created ${arguments[1]} in ${arguments[0]}. See README.md to build and pack.');
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 65;
  } on FileSystemException catch (error) {
    stderr.writeln(error.message);
    exitCode = 74;
  }
}
