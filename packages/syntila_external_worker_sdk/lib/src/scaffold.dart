import 'dart:convert';
import 'dart:io';

import 'package:syntila_external_worker_protocol/syntila_external_worker_protocol.dart';

/// Creates a local Dart author project for a Syntila MCP Worker (`kind: "mcp"`,
/// served over stdio by [runMcpWorker]). Existing files are never overwritten.
void initializeExternalWorkerDirectory(String directory, String id,
    {required String sdkPath, bool mcp = true}) {
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
    'kind': 'mcp',
    'pluginId': id,
    'version': '1.0.0',
    'displayName': id,
    'description': 'A custom MCP Worker.',
    'author': {'name': 'Plugin author'},
    'protocol': {'min': '1.0', 'max': '1.0'},
    'artifacts': {
      currentExternalWorkerPlatform(): {
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
  syntila_external_worker_sdk:
    path: ${jsonEncode(Directory(sdkPath).absolute.path)}
''');
  File('${root.path}/bin/main.dart')
    ..createSync(recursive: true)
    ..writeAsStringSync(
        '''import 'package:syntila_external_worker_sdk/syntila_external_worker_sdk.dart';

class MyWorker extends ExternalWorker {
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

Future<void> main() => runMcpWorker(MyWorker());
''');
  File('${root.path}/plugin.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(manifest)}\n');
  File('${root.path}/README.md').writeAsStringSync('''# $id

From this directory:

```sh
dart pub get
dart compile exe bin/main.dart -o $command
dart run syntila_external_worker_sdk:pack .
```

The generated hash and size are placeholders until the executable is built and
packed. Review plugin.json access declarations before distributing this package.
This project uses a local SDK path; publication is not available yet.
''');
}
