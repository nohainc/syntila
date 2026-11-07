import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Writes a minimal plugin package directory (a script artifact plus
/// plugin.json) and returns its path. The platform key is `linux-x64`, so the
/// tests pair it with a store whose platform is overridden.
String writePluginPackage(
  Directory temp, {
  String id = 'acme-reviewer',
  String version = '1.4.2',
  String body = '#!/bin/sh\necho hi\n',
  String workRoot = 'write',
  String name = 'pkg',
  void Function(Map<String, Object?> manifest)? edit,
}) {
  final dir = Directory('${temp.path}/$name-$id-$version')
    ..createSync(recursive: true);
  final bytes = utf8.encode(body);
  File('${dir.path}/bin/run')
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  final manifest = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'mcp',
    'pluginId': id,
    'version': version,
    'displayName': 'Acme',
    'description': 'x',
    'author': {'name': 'Acme'},
    'protocol': {'min': '1.0', 'max': '1.0'},
    'artifacts': {
      'linux-x64': {
        'command': 'bin/run',
        'args': <String>[],
        'sha256': sha256.convert(bytes).toString(),
        'size': bytes.length,
      },
    },
    'capabilities': <String, Object?>{},
    'access': {
      'workRoot': workRoot,
      'network': {'mode': 'none'},
      'subprocess': false,
      'env': <String>[],
    },
  };
  edit?.call(manifest);
  File('${dir.path}/plugin.json').writeAsStringSync(jsonEncode(manifest));
  return dir.path;
}
