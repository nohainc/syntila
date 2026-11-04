import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:syntila_workspace/plugin_signer_trust.dart';
import 'package:syntila_workspace/plugin_store.dart';
import 'package:syntila_workspace/workspace_manager_ipc.dart';
import 'package:syntila_workspace/workspace_manager_plugins.dart';
import 'package:test/test.dart';

import 'support/plugin_fakes.dart';
import 'support/plugin_package.dart';

void main() {
  late Directory root;
  late TestPluginService harness;
  setUp(() {
    root = Directory.systemTemp.createTempSync('signer-trust');
    harness = TestPluginService(root);
  });
  tearDown(() {
    Process.runSync('chmod', ['-R', 'u+w', root.path]);
    root.deleteSync(recursive: true);
  });

  Future<String> signed({String version = '1.4.2', SimpleKeyPair? key}) async {
    final path = writePluginPackage(root, version: version, name: 'v$version');
    final manifest = jsonDecode(File('$path/plugin.json').readAsStringSync())
        as Map<String, Object?>;
    final pair = key ?? await Ed25519().newKeyPair();
    final signature = await Ed25519()
        .sign(utf8.encode(pluginManifestDigest(manifest)), keyPair: pair);
    File('$path/plugin.sig').writeAsStringSync(jsonEncode({
      'alg': 'ed25519',
      'keyId': 'author-1',
      'publicKey': base64Encode((await pair.extractPublicKey()).bytes),
      'signature': base64Encode(signature.bytes),
    }));
    return path;
  }

  test('fingerprint consent is persistent, revocable and does not approve work',
      () async {
    final service = harness.service;
    await service.import(await signed());
    final consent = await service.trustSigner('acme-reviewer');
    expect(consent['consentRequired'], isTrue);
    expect((await service.signers())['signers'], isEmpty);
    expect(jsonEncode(consent), isNot(contains(root.path)));
    expect(
        (await service.trustSigner('acme-reviewer',
            acceptHash: '0' * 64))['consentRequired'],
        isTrue);
    final accepted = await service.trustSigner('acme-reviewer',
        acceptHash: consent['documentHash'] as String);
    final fingerprint = accepted['fingerprint'] as String;
    expect(
        await PluginSignerTrust(service.signerTrust.file).contains(fingerprint),
        isTrue);
    expect((await service.show('acme-reviewer'))['selected'],
        containsPair('signerTrustedLocally', true));
    await expectLater(
        service.register('acme-reviewer'),
        throwsA(isA<PluginServiceException>()
            .having((e) => e.code, 'code', 'plugin_conformance_required')));
    await service.test('acme-reviewer');
    final registration = await service.register('acme-reviewer');
    expect(registration['consentRequired'], isTrue);
    final document = registration['document'] as Map;
    expect(document['signature'], containsPair('trustedLocally', true));
    expect(document['plugin'], containsPair('authorVerified', false));
    expect(document['plugin'], containsPair('signatureVerified', true));
    expect(
        harness.cloud.calls.where((c) => c.startsWith('register:')), isEmpty);
    // Recognition removal remains available after lapse and offline.
    harness.now = testStart.add(const Duration(days: 2));
    harness.cloud.online = false;
    expect((await service.untrustSigner(fingerprint))['removed'], isTrue);
    expect((await service.signers())['signers'], isEmpty);
  });

  test(
      'key rotation never inherits recognition and stale consent cannot pin it',
      () async {
    final service = harness.service;
    await service.import(await signed());
    final first = await service.trustSigner('acme-reviewer');
    await service.trustSigner('acme-reviewer',
        acceptHash: first['documentHash'] as String);
    await service.import(await signed(version: '1.5.0'));
    final second = await service.trustSigner('acme-reviewer',
        acceptHash: first['documentHash'] as String);
    expect(second['consentRequired'], isTrue);
    expect((await service.show('acme-reviewer'))['selected'],
        containsPair('signerTrustedLocally', false));
    expect((await service.signers())['signers'], hasLength(1));
  });

  test('trust refuses unsigned packages and forged registry signature claims',
      () async {
    final service = harness.service;
    await service.import(writePluginPackage(root));
    // Cached metadata cannot substitute for a valid on-disk signature.
    final registry =
        jsonDecode(await service.registry.file.readAsString()) as Map;
    (registry['plugins']['acme-reviewer']['versions']['1.4.2']
        as Map)['signer'] = {
      'fingerprint': 'a' * 64,
      'keyId': 'forged',
      'verified': true
    };
    await service.registry.file.writeAsString(jsonEncode(registry));
    await expectLater(
        service.trustSigner('acme-reviewer'),
        throwsA(isA<PluginServiceException>()
            .having((e) => e.code, 'code', 'plugin_signature_required')));
    expect((await service.signers())['signers'], isEmpty);
  });

  test('a tampered installed signature cannot be recognized', () async {
    final service = harness.service;
    await service.import(await signed());
    final record =
        (await service.registry.find('acme-reviewer'))!.versions['1.4.2']!;
    final signature = File(
        '${service.store.versionDirectory('acme-reviewer', '1.4.2', record.manifestDigest).path}/plugin.sig');
    await Process.run('chmod', ['u+w', signature.path]);
    await signature.writeAsString('{}');
    await expectLater(
        service.trustSigner('acme-reviewer'),
        throwsA(isA<PluginServiceException>()
            .having((e) => e.code, 'code', 'plugin_signature_invalid')));
    expect((await service.signers())['signers'], isEmpty);
  });

  test('same-key updates still need registration and enablement consent',
      () async {
    final service = harness.service;
    final key = await Ed25519().newKeyPair();
    await service.import(await signed(key: key));
    final trust = await service.trustSigner('acme-reviewer');
    await service.trustSigner('acme-reviewer',
        acceptHash: trust['documentHash'] as String);
    await service.test('acme-reviewer');
    final registration = await service.register('acme-reviewer');
    await service.register('acme-reviewer',
        acceptHash: registration['documentHash'] as String);
    final enablement = await service.enable('acme-reviewer');
    expect(enablement['consentRequired'], isTrue);
    await service.enable('acme-reviewer',
        acceptHash: enablement['documentHash'] as String);
    await service.import(await signed(version: '1.5.0', key: key));
    await service.test('acme-reviewer', version: '1.5.0');
    final update = await service.register('acme-reviewer', version: '1.5.0');
    expect(update['consentRequired'], isTrue);
    await service.register('acme-reviewer',
        version: '1.5.0', acceptHash: update['documentHash'] as String);
    final changed = await service.enable('acme-reviewer', version: '1.5.0');
    expect(changed['consentRequired'], isTrue);
    expect((changed['document'] as Map)['signature'],
        containsPair('trustedLocally', true));
    expect(
        (await service.registry.find('acme-reviewer'))!.pin!.version, '1.4.2');
    final fingerprint = ((trust['document'] as Map)['fingerprint']) as String;
    await service.untrustSigner(fingerprint);
    expect(
        (await service.registry.find('acme-reviewer'))!.pin!.version, '1.4.2');
  });

  test('corrupt signer state is preserved and never overwritten', () async {
    final store = harness.service.signerTrust;
    await store.file.parent.create(recursive: true);
    await store.file.writeAsString('{broken');
    await expectLater(
        store.pin('a' * 64, testStart),
        throwsA(isA<PluginServiceException>()
            .having((e) => e.code, 'code', 'plugin_signer_trust_invalid')));
    expect(await store.file.readAsString(), '{broken');
  });

  test('concurrent pins are serialized and IPC rejects malformed fingerprints',
      () async {
    final store = harness.service.signerTrust;
    await Future.wait(
        [store.pin('a' * 64, testStart), store.pin('b' * 64, testStart)]);
    expect(await store.all(), hasLength(2));
    final commands = WorkspacePluginCommands(harness.service, publish: (_) {});
    await expectLater(
        commands.handle('plugins.untrustSigner', {'fingerprint': '../x'}),
        throwsA(isA<WorkspaceManagerProtocolException>()
            .having((e) => e.code, 'code', 'invalid_request')));
    final listed = await commands.handle('plugins.signers', {}) as Map;
    expect(listed['signers'], hasLength(2));
  });
}
