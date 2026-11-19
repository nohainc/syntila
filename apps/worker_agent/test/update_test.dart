import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_worker_agent/syntila_worker_agent.dart';
import 'package:test/test.dart';

Future<UpdateManifest> signed(
  AgentKey key,
  List<int> bytes, {
  String version = '0.2.0',
  String url = 'https://updates.example/w',
}) async {
  final unsigned = UpdateManifest(
    version: version,
    channel: 'stable',
    url: url,
    sha256: sha256.convert(bytes).toString(),
    signature: '',
  );
  return UpdateManifest(
    version: version,
    channel: 'stable',
    url: url,
    sha256: unsigned.sha256,
    signature: await signMessage(key, unsigned.signedText),
  );
}

void main() {
  final bytes = utf8.encode('binary');
  late AgentKey release;
  setUp(() async => release = await generateAgentKey());

  test('a correctly signed newer update is staged atomically', () async {
    final dir = await Directory.systemTemp.createTemp('syntila-update-');
    addTearDown(() => dir.delete(recursive: true));
    final manifest = await signed(release, bytes);
    final file = await UpdateVerifier([
      release.publicKeyText,
    ]).stage(manifest, bytes, dir, currentVersion: '0.1.0');
    expect(await file.readAsBytes(), bytes);
    expect(File('${file.path}.part').existsSync(), isFalse);
    expect(File('${dir.path}/pending-update.json').existsSync(), isTrue);
  });

  test('nothing is written when any check fails', () async {
    final dir = await Directory.systemTemp.createTemp('syntila-update-');
    addTearDown(() => dir.delete(recursive: true));
    final stranger = await generateAgentKey();
    final verifier = UpdateVerifier([release.publicKeyText]);
    Future<void> rejects(
      UpdateManifest m,
      List<int> data,
      String why, {
      String current = '0.1.0',
    }) async {
      await expectLater(
        verifier.stage(m, data, dir, currentVersion: current),
        throwsA(isA<UpdateRejectedException>()),
        reason: why,
      );
      expect(dir.listSync(), isEmpty, reason: why);
    }

    await rejects(
      await signed(stranger, bytes),
      bytes,
      'signed by an unknown key',
    );
    await rejects(
      await signed(release, bytes),
      utf8.encode('tampered'),
      'the download differs from its hash',
    );
    await rejects(
      await signed(release, bytes, version: '0.0.9'),
      bytes,
      'a downgrade',
    );
    await rejects(
      await signed(release, bytes, version: '0.1.0'),
      bytes,
      'the same version',
    );
    await rejects(
      await signed(release, bytes, url: 'http://updates.example/w'),
      bytes,
      'plain http',
    );
    final altered = await signed(release, bytes);
    await rejects(
      UpdateManifest(
        version: '9.9.9',
        channel: altered.channel,
        url: altered.url,
        sha256: altered.sha256,
        signature: altered.signature,
      ),
      bytes,
      'the signature covers the version',
    );
  });

  test('with no release key configured every update is refused', () async {
    await expectLater(
      UpdateVerifier(
        const [],
      ).verifyManifest(await signed(release, bytes), currentVersion: '0.1.0'),
      throwsA(isA<UpdateRejectedException>()),
    );
  });

  test('version ordering', () {
    expect(isNewerVersion('0.1.0', '0.1.1'), isTrue);
    expect(isNewerVersion('0.9.0', '0.10.0'), isTrue);
    expect(isNewerVersion('1.0.0', '0.99.0'), isFalse);
    expect(isNewerVersion('1.0.0', '1.0.0'), isFalse);
    expect(isNewerVersion('1.0.0', 'x.y'), isFalse);
  });
}
