import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_agent/syntila_worker_agent.dart';
import 'package:test/test.dart';

class StubVerifier implements ProfileVerifier {
  StubVerifier(this.accept);
  bool accept;

  @override
  Future<bool> verify(List<int> profileBytes, String? signature) async =>
      accept;
}

void main() {
  late Directory dir;
  setUp(
    () async => dir = await Directory.systemTemp.createTemp('syntila-state-'),
  );
  tearDown(() => dir.delete(recursive: true));

  group('Profile cache', () {
    test(
      'keeps the last known good and never replaces it with a bad update',
      () async {
        final verifier = StubVerifier(true);
        final cache = ProfileCache(Directory('${dir.path}/profiles'), verifier);
        final v1 = utf8.encode('profile v1');
        final digest1 = await cache.put(v1, revision: 1);
        expect((await cache.lastKnownGood())!.digest, digest1);
        verifier.accept = false;
        await expectLater(
          cache.put(utf8.encode('profile v2'), revision: 2),
          throwsA(isA<ProfileRejectedException>()),
        );
        expect(await cache.lastKnownGood(), isNull);
        verifier.accept = true;
        expect((await cache.lastKnownGood())!.digest, digest1);
        await expectLater(
          cache.put(utf8.encode('x'), revision: 3, expectedDigest: 'sha256:00'),
          throwsA(isA<ProfileRejectedException>()),
        );
        expect((await cache.lastKnownGood())!.revision, 1);
      },
    );

    test('an older revision is stored but does not become current', () async {
      final cache = ProfileCache(
        Directory('${dir.path}/profiles'),
        StubVerifier(true),
      );
      final newer = await cache.put(utf8.encode('new'), revision: 5);
      final older = await cache.put(utf8.encode('old'), revision: 3);
      expect((await cache.lastKnownGood())!.digest, newer);
      expect(
        await cache.has(older),
        isTrue,
        reason: 'a pinned older digest can still be served',
      );
    });

    test('tampered cache entries are not served', () async {
      final cache = ProfileCache(
        Directory('${dir.path}/profiles'),
        StubVerifier(true),
      );
      final digest = await cache.put(utf8.encode('profile'), revision: 1);
      final file = Directory('${dir.path}/profiles')
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('.profile'));
      await file.writeAsString('tampered');
      expect(await cache.read(digest), isNull);
      expect(await cache.lastKnownGood(), isNull);
      expect(await cache.has(digest), isFalse);
    });

    test('requires an admission proof and rechecks current trust', () async {
      final verifier = StubVerifier(true);
      final directory = Directory('${dir.path}/profiles');
      final cache = ProfileCache(directory, verifier);
      final bytes = utf8.encode('profile');
      final digest = await cache.put(bytes, signature: 'proof', revision: 1);
      expect(await cache.read(digest), bytes);
      verifier.accept = false;
      expect(await cache.read(digest), isNull);
      verifier.accept = true;
      await File('${directory.path}/sha256-$digest.signature.json').delete();
      expect(await cache.read(digest), isNull);
      expect(await cache.verifiedFile(digest), isNull);
    });

    test('rejects malformed digests before resolving a cache path', () async {
      final cache = ProfileCache(
        Directory('${dir.path}/profiles'),
        StubVerifier(true),
      );
      expect(await cache.read('../../outside'), isNull);
      expect(await cache.has('sha256:../outside'), isFalse);
    });
  });

  group('readiness', () {
    test(
      'ready only when every check passes; a throwing check is a failure',
      () async {
        final ok = ReadinessChecker([ReadinessCheck('a', () async => null)]);
        expect((await ok.evaluate()).ready, isTrue);
        final bad = ReadinessChecker([
          ReadinessCheck('a', () async => null),
          ReadinessCheck('engine', () async => 'engine_unavailable'),
          ReadinessCheck('boom', () async => throw StateError('/secret/path')),
        ]);
        final report = await bad.evaluate();
        expect(report.ready, isFalse);
        expect(report.failures, {
          'engine': 'engine_unavailable',
          'boom': 'check_failed',
        });
        expect(jsonEncode(report.toJson()), isNot(contains('/secret')));
      },
    );
  });

  group('allowed folders', () {
    late Directory home;
    late Directory data;
    late AllowedFolders folders;
    setUp(() async {
      home = await Directory('${dir.path}/home').create();
      data = await Directory(
        '${dir.path}/home/appdata/Syntila',
      ).create(recursive: true);
      folders = AllowedFolders(
        File('${dir.path}/registry/folders.json'),
        home: home.path,
        dataRoot: data.path,
      );
    });

    test('grants a project folder and returns only an opaque id', () async {
      final project = await Directory('${home.path}/project').create();
      final id = await folders.add(project.path);
      expect(id, startsWith('fld-'));
      expect(id, isNot(contains('project')));
      expect(
        await folders.add(project.path),
        id,
        reason: 'granting twice is the same grant',
      );
      expect(await folders.list(), hasLength(1));
      expect(
        await folders.isAllowed('${project.path}/sub/../file.txt'),
        isFalse,
        reason: 'the file does not exist',
      );
      await File('${project.path}/file.txt').writeAsString('x');
      expect(await folders.isAllowed('${project.path}/file.txt'), isTrue);
      expect(await folders.isAllowed(home.path), isFalse);
    });

    test(
      'refuses roots, the home folder, its parents and Syntila application data',
      () async {
        for (final path in [
          home.path,
          home.parent.path,
          data.path,
          '${home.path}/appdata',
          '/',
        ]) {
          await expectLater(
            folders.add(path),
            throwsA(isA<FolderRejectedException>()),
            reason: path,
          );
        }
        await expectLater(
          folders.add('${home.path}/missing'),
          throwsA(isA<FolderRejectedException>()),
        );
      },
    );

    test('a link out of a granted folder does not pass', () async {
      if (Platform.isWindows) return;
      final project = await Directory('${home.path}/project').create();
      final outside = await Directory('${home.path}/outside').create();
      await File('${outside.path}/secret.txt').writeAsString('x');
      await Link('${project.path}/escape').create(outside.path);
      await folders.add(project.path);
      expect(
        await folders.isAllowed('${project.path}/escape/secret.txt'),
        isFalse,
      );
    });

    test('remove revokes the grant', () async {
      final project = await Directory('${home.path}/project').create();
      final id = await folders.add(project.path);
      expect(await folders.remove(id), isTrue);
      expect(await folders.remove(id), isFalse);
      expect(await folders.list(), isEmpty);
    });
  });

  group('config', () {
    test('validates values and round-trips', () async {
      final file = File('${dir.path}/config/config.json');
      var config = const AgentConfig()
          .set('maxConcurrent', '3')
          .set('autoStart', 'true')
          .set('logLevel', 'debug');
      await config.save(file);
      config = await AgentConfig.load(file);
      expect(config.maxConcurrent, 3);
      expect(config.autoStart, isTrue);
      expect(config.logLevel, 'debug');
      for (final bad in [
        () => config.set('maxConcurrent', '0'),
        () => config.set('maxConcurrent', 'many'),
        () => config.set('autoStart', 'yes'),
        () => config.set('logLevel', 'loud'),
        () => config.set('nope', '1'),
      ]) {
        expect(bad, throwsFormatException);
      }
    });

    test('auto-start is off by default', () {
      expect(const AgentConfig().autoStart, isFalse);
    });
  });
}
