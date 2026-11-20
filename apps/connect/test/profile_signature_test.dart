import 'dart:convert';
import 'dart:io';

import 'package:syntila_connect/syntila_connect.dart';
import 'package:test/test.dart';
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';

void main() {
  test('admits only a signed snapshot matching the assignment pin', () async {
    final key = await generateAgentKey();
    final path =
        '${Directory.current.parent.parent.path}/packages/tool-profile/test/fixtures/fixture-cli.v1.json';
    final profile =
        jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
    final bytes = utf8.encode(canonicalJson(profile));
    final digest = profileDigest(bytes);
    final proof = jsonEncode({
      'version': 1,
      'keyId': 'key',
      'signature': await signMessage(key, 'syntila-worker-profile-v1\n$digest'),
    });
    final snapshot = {
      'workerTypeId': 'fixture-worker',
      'schemaVersion': 1,
      'profile': profile,
      'revision': 2,
      'digest': digest,
    };
    final dir = await Directory.systemTemp.createTemp('profile-snapshot-');
    addTearDown(() => dir.delete(recursive: true));
    final cache = ProfileCache(
      dir,
      SignedProfileVerifier({'key': key.publicKeyText}),
    );
    expect(
      await cache.putSnapshot(
        snapshot,
        workerTypeId: 'fixture-worker',
        revision: 2,
        digest: digest,
        signature: proof,
      ),
      digest,
    );
    await expectLater(
      cache.putSnapshot(
        snapshot,
        workerTypeId: 'fixture-worker',
        revision: 1,
        digest: digest,
        signature: proof,
      ),
      throwsA(isA<ProfileRejectedException>()),
    );
    await expectLater(
      cache.putSnapshot(
        snapshot,
        workerTypeId: 'fixture-worker',
        revision: 2,
        digest: digest,
        signature: '{}',
      ),
      throwsA(isA<ProfileRejectedException>()),
    );
    await expectLater(
      cache.putSnapshot(
        snapshot,
        workerTypeId: 'other',
        revision: 2,
        digest: digest,
        signature: proof,
      ),
      throwsFormatException,
    );
  });
  test(
    'build trust roots reject malformed or partially invalid sets',
    () async {
      final key = await generateAgentKey();
      expect(
        parseProfileTrustRoots(jsonEncode({'release': key.publicKeyText})),
        {'release': key.publicKeyText},
      );
      expect(parseProfileTrustRoots('{'), isEmpty);
      expect(
        parseProfileTrustRoots(
          jsonEncode({'release': key.publicKeyText, 'bad': 'x'}),
        ),
        isEmpty,
      );
      expect(
        parseProfileTrustRoots(jsonEncode({'bad key': key.publicKeyText})),
        isEmpty,
      );
    },
  );
  test('only a trusted signature for these exact bytes is accepted', () async {
    final key = await generateAgentKey();
    final other = await generateAgentKey();
    final bytes = utf8.encode('{"profile":"example"}');
    final proof = jsonEncode({
      'version': 1,
      'keyId': 'publisher-1',
      'signature': await signMessage(
        key,
        'syntila-worker-profile-v1\n${profileDigest(bytes)}',
      ),
    });
    final verifier = SignedProfileVerifier({'publisher-1': key.publicKeyText});
    expect(await verifier.verify(bytes, proof), isTrue);
    expect(await verifier.verify(utf8.encode('modified'), proof), isFalse);
    expect(
      await SignedProfileVerifier({
        'publisher-1': other.publicKeyText,
      }).verify(bytes, proof),
      isFalse,
    );
    expect(await SignedProfileVerifier({}).verify(bytes, proof), isFalse);
    expect(await verifier.verify(bytes, null), isFalse);
    expect(await verifier.verify(bytes, '{'), isFalse);
    expect(
      await verifier.verify(
        bytes,
        jsonEncode({'version': 1, 'keyId': 'publisher-1', 'signature': 'x'}),
      ),
      isFalse,
    );
    expect(
      await verifier.verify(
        bytes,
        jsonEncode({
          'version': 1,
          'keyId': 'publisher-1',
          'signature': 'x',
          'extra': true,
        }),
      ),
      isFalse,
    );
  });

  test(
    'a cached Profile stops resolving when its signing key is no longer trusted',
    () async {
      final key = await generateAgentKey();
      final bytes = utf8.encode('profile');
      final proof = jsonEncode({
        'version': 1,
        'keyId': 'key',
        'signature': await signMessage(
          key,
          'syntila-worker-profile-v1\n${profileDigest(bytes)}',
        ),
      });
      final dir = await Directory.systemTemp.createTemp('profile-trust-');
      addTearDown(() => dir.delete(recursive: true));
      final digest = await ProfileCache(
        dir,
        SignedProfileVerifier({'key': key.publicKeyText}),
      ).put(bytes, signature: proof, revision: 1);
      expect(
        await ProfileCache(
          dir,
          SignedProfileVerifier({'key': key.publicKeyText}),
        ).read(digest),
        bytes,
      );
      expect(
        await ProfileCache(dir, SignedProfileVerifier({})).read(digest),
        isNull,
      );
    },
  );
}
