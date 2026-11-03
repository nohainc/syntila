import 'dart:convert';

import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:test/test.dart';

/// A fresh, deeply mutable manifest (JSON round trip gives dynamic maps).
Map<String, Object?> manifest() => jsonDecode(jsonEncode(_example))
    as Map<String, Object?>;

final _example = <String, Object?>{
      'schemaVersion': 1,
      'pluginId': 'acme-reviewer',
      'version': '1.4.2',
      'displayName': 'Acme Reviewer',
      'description': 'Reviews code.',
      'author': {'name': 'Acme'},
      'protocol': {'min': '1.0', 'max': '1.0'},
      'artifacts': {
        'linux-x64': {
          'command': 'bin/reviewer',
          'args': ['--syntila'],
          'sha256': 'a' * 64,
          'size': 1024,
        },
      },
      'capabilities': {'progress': true, 'readOnly': 'never'},
      'access': {
        'workRoot': 'write',
        'network': {
          'mode': 'declared',
          'hosts': ['api.acme.example'],
        },
        'subprocess': false,
        'env': ['ACME_ENDPOINT'],
      },
    };

void expectInvalid(Map<String, Object?> value, String path) {
  final result = validatePluginManifest(value);
  expect(result.isValid, isFalse);
  expect(result.issues.map((i) => i.path), contains(path));
}

void main() {
  test('accepts the documented example', () {
    final result = validatePluginManifest(manifest());
    expect(result.issues, isEmpty);
    expect(result.manifest?.pluginId, 'acme-reviewer');
    expect(result.manifest?.artifacts['linux-x64']?.size, 1024);
  });

  test('rejects non-objects and unknown keys at every level', () {
    expect(validatePluginManifest('x').isValid, isFalse);
    expectInvalid({...manifest(), 'accesss': {}}, 'accesss');
    final m = manifest();
    (m['access'] as Map<String, Object?>)['filesystem'] = 'all';
    expectInvalid(m, 'access.filesystem');
  });

  test('rejects unsafe artifact commands and bad digests and sizes', () {
    for (final command in ['../evil', '/bin/sh', r'C:\x.exe', 'bin//x']) {
      final m = manifest();
      ((m['artifacts'] as Map)['linux-x64'] as Map)['command'] = command;
      expectInvalid(m, 'artifacts.linux-x64.command');
    }
    final badSha = manifest();
    ((badSha['artifacts'] as Map)['linux-x64'] as Map)['sha256'] = 'A' * 64;
    expectInvalid(badSha, 'artifacts.linux-x64.sha256');
    final badSize = manifest();
    ((badSize['artifacts'] as Map)['linux-x64'] as Map)['size'] = 0;
    expectInvalid(badSize, 'artifacts.linux-x64.size');
    expectInvalid({...manifest(), 'artifacts': <String, Object?>{}}, 'artifacts');
    final unknown = manifest();
    (unknown['artifacts'] as Map)['plan9-mips'] = {};
    expectInvalid(unknown, 'artifacts.plan9-mips');
  });

  test('rejects reserved env names, bad versions and inverted ranges', () {
    final env = manifest();
    (env['access'] as Map<String, Object?>)['env'] = ['SYNTILA_TOKEN'];
    expectInvalid(env, 'access.env');
    expectInvalid({...manifest(), 'version': '1.4'}, 'version');
    expectInvalid({...manifest(), 'pluginId': 'Acme'}, 'pluginId');
    expectInvalid(
        {...manifest(), 'protocol': {'min': '1.2', 'max': '1.1'}}, 'protocol');
    expectInvalid(
        {...manifest(), 'protocol': {'min': '2.0', 'max': '2.0'}},
        'protocol.min');
  });

  test('requires hosts for a declared network and https homepages', () {
    final m = manifest();
    ((m['access'] as Map)['network'] as Map)['hosts'] = <String>[];
    expectInvalid(m, 'access.network.hosts');
    expectInvalid({...manifest(), 'homepage': 'http://x.example'}, 'homepage');
  });

  test('negotiates the highest overlapping protocol or none', () {
    final ok = validatePluginManifest(manifest()).manifest!;
    expect(negotiatePluginProtocol(ok), '1.0');
    final m = manifest();
    m['protocol'] = {'min': '1.3', 'max': '1.5'};
    final future = validatePluginManifest(m).manifest!;
    expect(negotiatePluginProtocol(future), isNull);
  });
}
