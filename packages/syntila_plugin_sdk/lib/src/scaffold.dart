import 'dart:convert';
import 'dart:io';

import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';

/// Creates a local Dart author project. Existing files are never overwritten.
void initializePluginDirectory(String directory, String id,
    {required String sdkPath}) {
  if (!RegExp(r'^[a-z][a-z0-9]*(-[a-z0-9]+)*$').hasMatch(id) ||
      id.length > 48) {
    throw const FormatException(
        'plugin id must be lowercase kebab-case, at most 48 characters');
  }
  final root = Directory(directory);
  if (root.existsSync() && root.listSync().isNotEmpty) {
    throw const FormatException('destination must be empty');
  }
  final command = Platform.isWindows ? 'bin/plugin.exe' : 'bin/plugin';
  final manifest = <String, Object?>{
    'schemaVersion': 1,
    'pluginId': id,
    'version': '1.0.0',
    'displayName': id,
    'description': 'A custom Worker plugin.',
    'author': {'name': 'Plugin author'},
    'protocol': {'min': '1.0', 'max': '1.0'},
    'artifacts': {
      currentPluginPlatform(): {
        'command': command,
        'args': <String>[],
        'sha256': '0' * 64,
        'size': 1,
      },
    },
    'capabilities': {'progress': true},
    'access': {
      'workRoot': 'write',
      'network': {'mode': 'none'},
      'subprocess': false,
      'env': <String>[],
    },
  };
  root.createSync(recursive: true);
  File('${root.path}/pubspec.yaml')
      .writeAsStringSync('''name: ${id.replaceAll('-', '_')}
publish_to: none
version: 1.0.0
environment:
  sdk: ">=3.5.0 <4.0.0"
dependencies:
  syntila_plugin_sdk:
    path: ${jsonEncode(Directory(sdkPath).absolute.path)}
''');
  File('${root.path}/bin/main.dart')
    ..createSync(recursive: true)
    ..writeAsStringSync(
        '''import 'package:syntila_plugin_sdk/syntila_plugin_sdk.dart';

class MyPlugin extends PluginWorker {
  @override
  String get id => '$id';
  @override
  String get version => '1.0.0';
  @override
  Future<WorkResult> execute(WorkRequest request, WorkContext context) async {
    context.progress('Working');
    return WorkResult(request.prompt);
  }
}

Future<void> main() => runPlugin(MyPlugin());
''');
  File('${root.path}/plugin.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(manifest)}\n');
  File('${root.path}/README.md').writeAsStringSync('''# $id

From this directory:

```sh
dart pub get
dart compile exe bin/main.dart -o $command
dart run syntila_plugin_sdk:pack .
```

The generated hash and size are placeholders until the executable is built and
packed. Review plugin.json access declarations before distributing this package.
This project uses a local SDK path; publication is not available yet.
''');
}
