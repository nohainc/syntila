import 'dart:convert';
import 'dart:io';

import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:syntila_workspace/plugin_store.dart' show pluginManifestDigest;
import 'package:test/test.dart';

/// Shared with Cloud (`apps/cloud/test/worker-plugins.test.ts`): both languages
/// must compute the same pin for the same manifest, including the `kind` key.
const _vectors = '../../docs/specifications/worker-plugin-vectors';

void main() {
  final manifest =
      jsonDecode(File('$_vectors/manifest-mcp.json').readAsStringSync())
          as Map<String, Object?>;
  final expected =
      File('$_vectors/manifest-mcp.sha256').readAsStringSync().trim();

  test('the MCP manifest digest equals the TypeScript digest', () {
    expect(pluginManifestDigest(manifest), expected);
  });

  test('kind is part of the canonical form', () {
    final plain = Map<String, Object?>.from(manifest)..remove('kind');
    // The long-standing NDJSON vector pinned by Cloud and the SDK tests.
    expect(
      pluginManifestDigest(plain),
      '1bb61d4147ad05e39110b86209fdb9f54dce582f6ffb0d92bbc913a928d49a8d',
    );
    expect(pluginManifestDigest(plain), isNot(expected));
  });

  test('the vector is a valid MCP manifest', () {
    final result = validatePluginManifest(manifest);
    expect(result.issues, isEmpty);
    expect(result.manifest!.isMcp, isTrue);
  });

  test('other kinds are rejected like Cloud rejects them', () {
    for (final kind in <Object?>['ndjson', 'MCP', '', 1, null, true]) {
      final result = validatePluginManifest({...manifest, 'kind': kind});
      expect(result.isValid, isFalse, reason: '$kind');
      expect(result.issues.map((i) => i.path), contains('kind'));
    }
  });
}
