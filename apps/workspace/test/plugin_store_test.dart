import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:syntila_workspace/plugin_store.dart';
import 'package:test/test.dart';

/// Produced by the TypeScript `pluginManifestDigest` over a manifest with
/// non-ASCII text, quotes, a newline and a tab, in a different key order.
const _vectorDigest =
    "1bb61d4147ad05e39110b86209fdb9f54dce582f6ffb0d92bbc913a928d49a8d";
final _vectorManifest = jsonDecode(
        r'''{"schemaVersion": 1, "pluginId": "acme-reviewer", "version": "1.4.2", "displayName": "Acme Reviewer \u2014 \u00fcn\u00efcode \u2713", "description": "Reviews \"code\".\nSecond line with a tab\t.", "author": {"name": "Acme", "contact": "plugins@acme.example"}, "protocol": {"min": "1.0", "max": "1.0"}, "artifacts": {"linux-x64": {"command": "bin/reviewer", "args": ["--syntila", "--flag=a/b"], "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "size": 1024}}, "capabilities": {"progress": true, "readOnly": "never"}, "access": {"workRoot": "write", "network": {"mode": "declared", "hosts": ["api.acme.example"]}, "subprocess": false, "env": ["ACME_ENDPOINT"]}}''')
    as Map<String, Object?>;

late Directory temp;
late PluginStore store;

String sha(List<int> bytes) => sha256.convert(bytes).toString();

/// Writes a package directory with a script artifact and returns its path.
String writePackage({
  String id = 'acme-reviewer',
  String version = '1.4.2',
  String body = '#!/bin/sh\necho hi\n',
  void Function(Map<String, Object?> manifest)? edit,
  bool withArtifact = true,
  String name = 'pkg',
}) {
  final dir = Directory('${temp.path}/$name-$id-$version')
    ..createSync(recursive: true);
  final bytes = utf8.encode(body);
  if (withArtifact) {
    File('${dir.path}/bin/run').createSync(recursive: true);
    File('${dir.path}/bin/run').writeAsBytesSync(bytes);
  }
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
        'sha256': sha(bytes),
        'size': bytes.length,
      },
    },
    'capabilities': <String, Object?>{},
    'access': {
      'workRoot': 'write',
      'network': {'mode': 'none'},
      'subprocess': false,
      'env': <String>[],
    },
  };
  edit?.call(manifest);
  File('${dir.path}/plugin.json').writeAsStringSync(jsonEncode(manifest));
  return dir.path;
}

Future<void> expectCode(Future<Object?> future, String code) => expectLater(
      future,
      throwsA(
          isA<PluginServiceException>().having((e) => e.code, 'code', code)),
    );

void main() {
  setUp(() {
    temp = Directory.systemTemp.createTempSync('plugin-store-test');
    store = PluginStore(
      root: Directory('${temp.path}/state/Plugins'),
      forbiddenRoots: ['${temp.path}/state'],
      platform: 'linux-x64',
    );
  });
  tearDown(() {
    Process.runSync('chmod', ['-R', 'u+w', temp.path]);
    temp.deleteSync(recursive: true);
  });

  test('the manifest digest equals the TypeScript digest', () {
    expect(pluginManifestDigest(_vectorManifest), _vectorDigest);
  });

  test('imports a package directory into an immutable digest-addressed path',
      () async {
    final installed = await store.import(writePackage());
    expect(installed.pluginId, 'acme-reviewer');
    expect(installed.manifestDigest, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(installed.directory.path, endsWith(installed.manifestDigest));
    expect(installed.origin.kind, 'local_path');
    expect(installed.origin.locator, isNot(contains(temp.path)));
    expect(File(installed.executablePath).existsSync(), isTrue);
    expect(
      () => File(installed.executablePath).writeAsStringSync('tampered'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('re-importing an identical package is idempotent', () async {
    final first = await store.import(writePackage());
    final second = await store.import(writePackage(name: 'again'));
    expect(second.directory.path, first.directory.path);
  });

  test('the same version with different contents is a conflict', () async {
    await store.import(writePackage());
    await expectCode(
      store
          .import(writePackage(name: 'other', body: '#!/bin/sh\necho other\n')),
      'plugin_version_conflict',
    );
  });

  test('rejects an invalid manifest with its issues', () async {
    final path = writePackage(edit: (m) => m['unexpected'] = true);
    await expectLater(
      store.import(path),
      throwsA(
        isA<PluginServiceException>()
            .having((e) => e.code, 'code', 'plugin_manifest_invalid')
            .having((e) => e.details, 'details',
                contains('unexpected: unknown key')),
      ),
    );
  });

  test('rejects a missing manifest, a missing artifact and a wrong hash',
      () async {
    final noManifest = Directory('${temp.path}/empty')..createSync();
    await expectCode(store.import(noManifest.path), 'plugin_manifest_invalid');
    await expectCode(
      store.import(writePackage(name: 'noart', withArtifact: false)),
      'plugin_package_invalid',
    );
    final bad = writePackage(name: 'bad');
    File('$bad/bin/run').writeAsStringSync('changed after hashing');
    await expectCode(store.import(bad), 'plugin_digest_mismatch');
  });

  test('rejects a platform the plugin has no build for', () async {
    final other = PluginStore(
      root: store.root,
      forbiddenRoots: store.forbiddenRoots,
      platform: 'windows-x64',
    );
    await expectCode(
        other.import(writePackage()), 'plugin_platform_unsupported');
  });

  test('rejects symbolic links inside a package', () async {
    final path = writePackage();
    Link('$path/link').createSync('/etc');
    await expectCode(store.import(path), 'plugin_package_invalid');
  });

  test('refuses locations that overlap the state directory or its parents',
      () async {
    final inside = Directory('${store.root.path}/staging/sneaky')
      ..createSync(recursive: true);
    await expectCode(store.import(inside.path), 'plugin_path_not_allowed');
    await expectCode(
        store.import('${temp.path}/state'), 'plugin_path_not_allowed');
    await expectCode(store.import(temp.path), 'plugin_path_not_allowed');
  });

  test('zip entries cannot escape the package', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('../evil', utf8.encode('x')))
      ..addFile(ArchiveFile.bytes('plugin.json', utf8.encode('{}')));
    final zip = File('${temp.path}/evil.zip')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    // Whether the archive library sanitizes the name or the store rejects it,
    // the import must fail and nothing may land outside the staging area.
    await expectLater(
      store.import(zip.path),
      throwsA(isA<PluginServiceException>()),
    );
    expect(File('${temp.path}/evil').existsSync(), isFalse);
    expect(File('${temp.path}/state/evil').existsSync(), isFalse);
    expect(File('${store.root.path}/evil').existsSync(), isFalse);
    final garbage = File('${temp.path}/garbage.zip')
      ..writeAsStringSync('not a zip');
    await expectCode(store.import(garbage.path), 'plugin_package_invalid');
  });

  test('load re-verifies the bytes and detects tampering', () async {
    final installed = await store.import(writePackage());
    final again = await store.load(
      installed.pluginId,
      installed.version,
      installed.manifestDigest,
    );
    expect(again.artifactDigest, installed.artifactDigest);
    Process.runSync('chmod', ['-R', 'u+w', installed.directory.path]);
    File(installed.executablePath).writeAsStringSync('swapped');
    await expectCode(
      store.load(
          installed.pluginId, installed.version, installed.manifestDigest),
      'plugin_digest_mismatch',
    );
    await expectCode(
      store.load('acme-reviewer', '9.9.9', installed.manifestDigest),
      'plugin_not_found',
    );
  });

  test('export produces a credential-free bundle that re-imports identically',
      () async {
    final installed = await store.import(writePackage());
    store.dataDirectory('acme-reviewer');
    File('${store.root.path}/data/acme-reviewer/secret.txt')
        .writeAsStringSync('API_KEY=hunter2');
    final out = '${temp.path}/acme.syntila-plugin';
    await store.export(installed, out);
    final names = ZipDecoder()
        .decodeBytes(File(out).readAsBytesSync())
        .where((f) => f.isFile)
        .map((f) => f.name)
        .toSet();
    expect(names, containsAll(['bundle.json', 'plugin.json', 'bin/run']));
    expect(
        names.any((n) => n.contains('secret') || n.contains('data/')), isFalse);
    final other = PluginStore(
      root: Directory('${temp.path}/other/Plugins'),
      forbiddenRoots: ['${temp.path}/other'],
      platform: 'linux-x64',
    );
    final reimported = await other.import(out);
    expect(reimported.manifestDigest, installed.manifestDigest);
    expect(reimported.origin.kind, 'export_bundle');
  });

  test('refuses to export into the state directory', () async {
    final installed = await store.import(writePackage());
    await expectCode(
      store.export(installed, '${store.root.path}/leak.zip'),
      'plugin_path_not_allowed',
    );
  });

  group('signatures', () {
    Future<String> signedPackage({bool corrupt = false}) async {
      final path = writePackage(name: corrupt ? 'badsig' : 'sig');
      final manifest = jsonDecode(File('$path/plugin.json').readAsStringSync())
          as Map<String, Object?>;
      final digest = pluginManifestDigest(manifest);
      final algorithm = Ed25519();
      final pair = await algorithm.newKeyPair();
      final publicKey = (await pair.extractPublicKey()).bytes;
      final signature = await algorithm.sign(
        utf8.encode(corrupt ? 'something else' : digest),
        keyPair: pair,
      );
      File('$path/plugin.sig').writeAsStringSync(jsonEncode({
        'alg': 'ed25519',
        'keyId': 'author-1',
        'publicKey': base64Encode(publicKey),
        'signature': base64Encode(signature.bytes),
      }));
      return path;
    }

    test('records a verified signer fingerprint', () async {
      final installed = await store.import(await signedPackage());
      expect(installed.signer?.verified, isTrue);
      expect(installed.signer?.fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('rejects a signature that does not verify', () async {
      await expectCode(
        store.import(await signedPackage(corrupt: true)),
        'plugin_signature_invalid',
      );
    });

    test('an unsigned package has no signer', () async {
      expect((await store.import(writePackage())).signer, isNull);
    });
  });

  test('removeVersion and removePlugin clean up read-only trees', () async {
    final installed = await store.import(writePackage());
    store.dataDirectory('acme-reviewer');
    await store.removeVersion('acme-reviewer', installed.version);
    expect(installed.directory.existsSync(), isFalse);
    await store.removePlugin('acme-reviewer');
    expect(Directory('${store.root.path}/data/acme-reviewer').existsSync(),
        isFalse);
  });
}
