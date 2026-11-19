import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_agent/syntila_worker_agent.dart';
import 'package:test/test.dart';

void main() {
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
