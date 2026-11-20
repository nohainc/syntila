import 'dart:io';

import 'package:syntila_connect/syntila_connect.dart';
import 'package:test/test.dart';

void main() {
  test('a signature verifies only for the same key and text', () async {
    final key = await generateAgentKey();
    final other = await generateAgentKey();
    final text = actionMessage('session', 'wrk-1', 'nonce-1', 'abc');
    final signature = await signMessage(key, text);
    expect(signature, hasLength(86));
    expect(key.publicKeyText, hasLength(43));
    expect(await verifyMessage(key.publicKeyText, text, signature), isTrue);
    expect(await verifyMessage(other.publicKeyText, text, signature), isFalse);
    expect(
      await verifyMessage(key.publicKeyText, '$text!', signature),
      isFalse,
    );
    expect(await verifyMessage('not a key', text, signature), isFalse);
  });

  test('signed texts match the server byte for byte', () {
    expect(
      pairingMessage('c1', 'w1', 'PK'),
      'syntila-worker/v1\npair\nc1\nw1\nPK',
    );
    expect(
      actionMessage('session', 'w1', 'n1', 'N'),
      'syntila-worker/v1\nsession\nw1\nn1\nN\n',
    );
    expect(
      actionMessage('rotate', 'w1', 'n1', 'N', 'NEW'),
      'syntila-worker/v1\nrotate\nw1\nn1\nN\nNEW',
    );
  });

  test('a signature made for one purpose is not valid for another', () async {
    final key = await generateAgentKey();
    final session = await signMessage(
      key,
      actionMessage('session', 'w', 'n', 'x'),
    );
    expect(
      await verifyMessage(
        key.publicKeyText,
        actionMessage('rotate', 'w', 'n', 'x'),
        session,
      ),
      isFalse,
    );
  });

  test(
    'the key file is written atomically and is owner-only on POSIX',
    () async {
      final dir = await Directory.systemTemp.createTemp('syntila-key-');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileKeyStore(File('${dir.path}/identity/key.json'));
      final key = await generateAgentKey();
      await store.save(key);
      final loaded = await store.load();
      expect(loaded!.publicKeyText, key.publicKeyText);
      expect(loaded.privateKey, key.privateKey);
      expect(File('${dir.path}/identity/key.json.tmp').existsSync(), isFalse);
      if (!Platform.isWindows) {
        final mode =
            (await File('${dir.path}/identity/key.json').stat()).mode & 0x1ff;
        expect(mode, 384, reason: '0600');
        final directoryMode =
            (await Directory('${dir.path}/identity').stat()).mode & 0x1ff;
        expect(directoryMode, 448, reason: '0700');
      }
      await store.delete();
      expect(await store.load(), isNull);
    },
  );

  group('pairing code', () {
    PairingCode sample({String server = 'https://syntila.example'}) =>
        PairingCode(
          serverUrl: server,
          workerId: 'wrk-1',
          challengeId: 'wpc-1',
          secret: 's' * 20,
        );

    test('round-trips', () {
      final parsed = PairingCode.parse(sample().encode());
      expect(parsed.workerId, 'wrk-1');
      expect(parsed.challengeId, 'wpc-1');
      expect(parsed.secret, 's' * 20);
      expect(parsed.serverUrl, 'https://syntila.example');
    });

    test('refuses damaged, foreign and insecure codes', () {
      expect(() => PairingCode.parse('hello'), throwsFormatException);
      expect(
        () => PairingCode.parse('${PairingCode.prefix}%%%'),
        throwsFormatException,
      );
      expect(
        () => PairingCode.parse(
          sample(server: 'http://syntila.example').encode(),
        ),
        throwsFormatException,
        reason: 'a pairing secret never travels over plain http',
      );
      expect(
        PairingCode.parse(
          sample(server: 'http://127.0.0.1:8787').encode(),
        ).workerId,
        'wrk-1',
      );
    });
  });
}
