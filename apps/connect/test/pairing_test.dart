import 'dart:io';

import 'package:syntila_connect/syntila_connect.dart';
import 'package:test/test.dart';

import 'support/fake_cloud.dart';

void main() {
  late FakeCloud cloud;
  late Directory root;
  setUp(() async {
    cloud = await FakeCloud.start();
    root = await Directory.systemTemp.createTemp('syntila-pair-');
  });
  tearDown(() async {
    await cloud.close();
    await root.delete(recursive: true);
  });

  AgentPaths pathsFor(String name) =>
      AgentPaths(Directory('${root.path}/$name'));

  test(
    'install claims the Worker with a signed proof and stores only local identity and key',
    () async {
      final worker = cloud.createWorker();
      final paths = pathsFor('a');
      final identity = await installAgent(
        code: cloud.createPairing(worker.id),
        paths: paths,
        keyStore: FileKeyStore(paths.keyFile),
      );
      expect(identity.workerId, worker.id);
      expect(worker.publicKey, isNotNull);
      final key = await FileKeyStore(paths.keyFile).load();
      expect(key!.publicKeyText, worker.publicKey);
      expect(paths.pairingMarker.existsSync(), isFalse);
      final stored = await paths.identityFile.readAsString();
      expect(stored, isNot(contains('secret')));
      expect(stored, isNot(contains('privateKey')));
      // The Agent does not declare an owner or an actor.
      expect(stored, isNot(contains('actor')));
      expect(stored, isNot(contains('owner')));
    },
  );

  test(
    'a code from another account is refused while this computer has its Workers',
    () async {
      final mine = cloud.createWorker(owner: 'alice');
      final first = pathsFor('alice');
      final alice = await installAgent(
        code: cloud.createPairing(mine.id),
        paths: first,
        keyStore: FileKeyStore(first.keyFile),
      );
      // Same account: allowed.
      final second = cloud.createWorker(owner: 'alice');
      final again = pathsFor('alice-2');
      await installAgent(
        code: cloud.createPairing(second.id),
        paths: again,
        keyStore: FileKeyStore(again.keyFile),
        pairedWorkers: [alice],
      );
      // Another account: refused, naming the Worker to unpair; nothing kept.
      final theirs = cloud.createWorker(owner: 'bob');
      final bob = pathsFor('bob');
      await expectLater(
        installAgent(
          code: cloud.createPairing(theirs.id),
          paths: bob,
          keyStore: FileKeyStore(bob.keyFile),
          pairedWorkers: [alice],
        ),
        throwsA(
          isA<OtherAccountPairingRefusal>().having(
            (e) => e.toString(),
            'message',
            contains(mine.id),
          ),
        ),
      );
      expect(bob.identityFile.existsSync(), isFalse);
      expect(theirs.publicKey, isNull);
      // Once Alice's Workers are unpaired, Bob can pair.
      mine.publicKey = null;
      second.publicKey = null;
      await installAgent(
        code: cloud.createPairing(theirs.id),
        paths: bob,
        keyStore: FileKeyStore(bob.keyFile),
        pairedWorkers: [alice],
      );
      expect(theirs.publicKey, isNotNull);
    },
  );

  test(
    'a pairing code works once; replay, expiry and a wrong secret leave nothing behind',
    () async {
      final worker = cloud.createWorker();
      final code = cloud.createPairing(worker.id);
      final first = pathsFor('first');
      await installAgent(
        code: code,
        paths: first,
        keyStore: FileKeyStore(first.keyFile),
      );

      final replay = pathsFor('replay');
      await expectLater(
        installAgent(
          code: code,
          paths: replay,
          keyStore: FileKeyStore(replay.keyFile),
        ),
        throwsA(isA<ServerRefusal>().having((e) => e.status, 'status', 410)),
      );
      expect(replay.identityFile.existsSync(), isFalse);
      expect(replay.keyFile.existsSync(), isFalse);

      final other = cloud.createWorker();
      final expired = cloud.createPairing(
        other.id,
        ttl: const Duration(milliseconds: -1),
      );
      final late = pathsFor('late');
      await expectLater(
        installAgent(
          code: expired,
          paths: late,
          keyStore: FileKeyStore(late.keyFile),
        ),
        throwsA(isA<ServerRefusal>().having((e) => e.status, 'status', 410)),
      );
      expect(late.keyFile.existsSync(), isFalse);

      final good = cloud.createPairing(other.id);
      final wrong = PairingCode(
        serverUrl: good.serverUrl,
        workerId: good.workerId,
        challengeId: good.challengeId,
        secret: 'wrong-secret-0123456789',
      );
      final bad = pathsFor('bad');
      await expectLater(
        installAgent(
          code: wrong,
          paths: bad,
          keyStore: FileKeyStore(bad.keyFile),
        ),
        throwsA(isA<ServerRefusal>().having((e) => e.status, 'status', 403)),
      );
      expect(other.publicKey, isNull, reason: 'a refused claim pairs nothing');
      // The refused attempt left the challenge unused, so the real code still works.
      final retry = pathsFor('retry');
      await installAgent(
        code: good,
        paths: retry,
        keyStore: FileKeyStore(retry.keyFile),
      );
      expect(other.publicKey, isNotNull);
    },
  );

  test('a paired data directory cannot be paired again', () async {
    final worker = cloud.createWorker();
    final paths = pathsFor('a');
    await installAgent(
      code: cloud.createPairing(worker.id),
      paths: paths,
      keyStore: FileKeyStore(paths.keyFile),
    );
    await expectLater(
      installAgent(
        code: cloud.createPairing(worker.id),
        paths: paths,
        keyStore: FileKeyStore(paths.keyFile),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('an interrupted install is cleaned up and can be retried', () async {
    final worker = cloud.createWorker();
    final paths = pathsFor('a');
    await paths.ensure();
    await paths.pairingMarker.writeAsString('pending');
    await FileKeyStore(paths.keyFile).save(await generateAgentKey());
    await AgentIdentity(
      workerId: worker.id,
      serverUrl: cloud.url,
      pairedAt: DateTime.now(),
    ).save(paths.identityFile);
    await installAgent(
      code: cloud.createPairing(worker.id),
      paths: paths,
      keyStore: FileKeyStore(paths.keyFile),
    );
    expect(worker.publicKey, isNotNull);
    expect(paths.pairingMarker.existsSync(), isFalse);
  });

  group('rotate', () {
    Future<(AgentPaths, AgentIdentity, FakeWorker)> paired() async {
      final worker = cloud.createWorker();
      final paths = pathsFor('a');
      final identity = await installAgent(
        code: cloud.createPairing(worker.id),
        paths: paths,
        keyStore: FileKeyStore(paths.keyFile),
      );
      return (paths, identity, worker);
    }

    test('both keys sign and the new key replaces the old one', () async {
      final (paths, identity, worker) = await paired();
      final before = worker.publicKey;
      await rotateCredential(
        paths: paths,
        identity: identity,
        keyStore: FileKeyStore(paths.keyFile),
      );
      expect(worker.publicKey, isNot(before));
      expect(
        (await FileKeyStore(paths.keyFile).load())!.publicKeyText,
        worker.publicKey,
      );
      expect(paths.nextKeyFile.existsSync(), isFalse);
    });

    test('a refused rotation keeps the old key', () async {
      final (paths, identity, worker) = await paired();
      final before = worker.publicKey;
      cloud.offline = true;
      await expectLater(
        rotateCredential(
          paths: paths,
          identity: identity,
          keyStore: FileKeyStore(paths.keyFile),
        ),
        throwsA(isA<ServerRefusal>()),
      );
      cloud.offline = false;
      expect(worker.publicKey, before);
      expect((await FileKeyStore(paths.keyFile).load())!.publicKeyText, before);
    });

    test(
      'a rotation the server accepted but the Agent never finished is recovered',
      () async {
        final (paths, identity, worker) = await paired();
        final next = await generateAgentKey();
        await FileKeyStore(paths.nextKeyFile).save(next);
        worker.publicKey =
            next.publicKeyText; // the server rotated; the old key is gone
        final api = ServerApi(cloud.url);
        addTearDown(api.close);
        expect(
          await recoverPendingRotation(
            paths: paths,
            identity: identity,
            keyStore: FileKeyStore(paths.keyFile),
            api: api,
          ),
          isTrue,
        );
        expect(
          (await FileKeyStore(paths.keyFile).load())!.publicKeyText,
          next.publicKeyText,
        );
        expect(paths.nextKeyFile.existsSync(), isFalse);
      },
    );

    test('a pending key the server never accepted is discarded', () async {
      final (paths, identity, worker) = await paired();
      final before = worker.publicKey;
      await FileKeyStore(paths.nextKeyFile).save(await generateAgentKey());
      final api = ServerApi(cloud.url);
      addTearDown(api.close);
      expect(
        await recoverPendingRotation(
          paths: paths,
          identity: identity,
          keyStore: FileKeyStore(paths.keyFile),
          api: api,
        ),
        isFalse,
      );
      expect((await FileKeyStore(paths.keyFile).load())!.publicKeyText, before);
      expect(paths.nextKeyFile.existsSync(), isFalse);
    });
  });

  test(
    'uninstall removes private state and never touches working folders',
    () async {
      final worker = cloud.createWorker();
      final paths = pathsFor('a');
      await installAgent(
        code: cloud.createPairing(worker.id),
        paths: paths,
        keyStore: FileKeyStore(paths.keyFile),
      );
      final work = await Directory(
        '${root.path}/work/project',
      ).create(recursive: true);
      await File('${work.path}/notes.txt').writeAsString('mine');
      await uninstallAgent(paths: paths, keyStore: FileKeyStore(paths.keyFile));
      expect(paths.root.existsSync(), isFalse);
      expect(File('${work.path}/notes.txt').readAsStringSync(), 'mine');
    },
  );
}
