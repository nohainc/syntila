import 'dart:io';

import 'package:syntila_worker_agent/syntila_worker_agent.dart';
import 'package:test/test.dart';

void main() {
  group('ArtifactLauncher', launcherTests);
  late Directory sandbox;
  late AllowedFolders folders;
  late Directory work;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('syntila-folders-');
    await Directory('${sandbox.path}/home').create();
    await Directory('${sandbox.path}/data').create();
    work = await Directory('${sandbox.path}/work').create();
    folders = AllowedFolders(
      File('${sandbox.path}/data/allowed.json'),
      home: '${sandbox.path}/home',
      dataRoot: '${sandbox.path}/data',
    );
  });
  tearDown(() => sandbox.delete(recursive: true));

  test('read and write are separate, and are re-checked before use', () async {
    final id = await folders.add(work.path);
    expect(id, startsWith('fld-'));
    expect(await folders.isAllowed(work.path), isTrue);
    expect(await folders.isAllowed(work.path, write: true), isFalse);
    await expectLater(
      folders.require(work.path, write: true),
      throwsA(isA<FolderRejectedException>()),
    );
    await folders.add(work.path, write: true);
    await folders.require(work.path, write: true);
    await folders.remove(id);
    await expectLater(
      folders.require(work.path),
      throwsA(isA<FolderRejectedException>()),
    );
  });

  test('a folder that was not approved cannot be reached', () async {
    final other = await Directory('${sandbox.path}/other').create();
    await folders.add(work.path, write: true);
    expect(await folders.isAllowed(other.path), isFalse);
    final link = Link('${work.path}/escape');
    await link.create(other.path);
    expect(await folders.isAllowed('${work.path}/escape'), isFalse);
  });

  test(
    'the Work Root maps Spaces and adopts existing folders explicitly',
    () async {
      final root = WorkRoot(
        File('${sandbox.path}/data/work-root.json'),
        folders,
      );
      await expectLater(
        root.spaceDirectory('space-1'),
        throwsA(isA<FolderRejectedException>()),
      );
      await root.setRoot(work.path);
      final dir = await root.spaceDirectory('space-1');
      expect(dir.path, endsWith('/spaces/space-1'));
      await expectLater(
        root.spaceDirectory('../escape'),
        throwsA(isA<FolderRejectedException>()),
      );
      final legacy = await Directory('${sandbox.path}/legacy').create();
      await expectLater(
        root.adopt({'space-2': legacy.path}),
        throwsA(isA<FolderRejectedException>()),
      );
      await folders.add(legacy.path, write: true);
      await root.adopt({'space-2': legacy.path});
      expect(
        (await root.spaceDirectory('space-2')).path,
        legacy.resolveSymbolicLinksSync(),
      );
      expect(await legacy.exists(), isTrue);
    },
  );

  test('a handoff is an artifact ID with a grant, never a path', () {
    for (final bad in <Object?>[
      '/Users/a/report.txt',
      {'path': '/x'},
      {'artifactId': '../x'},
    ]) {
      expect(
        () => ArtifactRef.parse(bad),
        throwsA(isA<MissingArtifactException>()),
      );
    }
    final ok = ArtifactRef.parse({
      'artifactId': 'art-11111111-1111-4111-8111-111111111111',
      'name': '../../etc/passwd',
      'sizeBytes': 3,
      'sha256': 'sha256:${'a' * 64}',
      'grant': {'token': 't'},
    });
    expect(safeArtifactName(ok.name), 'passwd');
    expect(safeArtifactName('..'), 'artifact');
  });
}

class _OkRun implements EngineRun {
  @override
  Future<EngineOutcome> get outcome => Future.value(
    const EngineOutcome(TerminalKind.completed, {'summary': 'ok'}),
  );
  @override
  Future<void> cancel() async {}
}

class _RecordingLauncher implements EngineLauncher {
  Map<String, Object?>? last;
  @override
  Future<EngineRun> launch(EngineRequest request) async {
    last = request.payload;
    return _OkRun();
  }

  @override
  Future<int> recoverOrphans() async => 0;
  @override
  Future<String?> probe() async => null;
}

void launcherTests() {
  late Directory sandbox;
  late AllowedFolders folders;
  late WorkRoot root;
  late Directory work;
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('syntila-launch-');
    await Directory('${sandbox.path}/home').create();
    await Directory('${sandbox.path}/data').create();
    work = await Directory('${sandbox.path}/work').create();
    folders = AllowedFolders(
      File('${sandbox.path}/data/allowed.json'),
      home: '${sandbox.path}/home',
      dataRoot: '${sandbox.path}/data',
    );
    root = WorkRoot(File('${sandbox.path}/data/work-root.json'), folders);
  });
  tearDown(() => sandbox.delete(recursive: true));

  ArtifactLauncher launcher(_RecordingLauncher inner) => ArtifactLauncher(
    inner: inner,
    folders: folders,
    workRoot: root,
    client: ArtifactClient('http://127.0.0.1:1'),
    holder: AgentSessionHolder(),
    workerId: 'w1',
  );

  EngineRequest request(List<Object?> refs) => EngineRequest(
    assignmentId: 'a1',
    attemptId: 't1',
    payload: {
      'snapshot': {'spaceId': 'space-1', 'contextRefs': refs},
    },
  );

  test(
    'a step with an artifact input fails when its folder was not approved',
    () async {
      final inner = _RecordingLauncher();
      final run = await launcher(inner).launch(
        request([
          {'artifactId': 'art-11111111-1111-4111-8111-111111111111'},
        ]),
      );
      final outcome = await run.outcome;
      expect(outcome.kind, TerminalKind.failed);
      expect(outcome.payload['errorCode'], 'folder_not_approved');
      expect(inner.last, isNull, reason: 'the Engine must not start');
    },
  );

  test(
    'a path handoff fails as a missing artifact before the Engine starts',
    () async {
      await root.setRoot(work.path);
      final inner = _RecordingLauncher();
      final run = await launcher(
        inner,
      ).launch(request(['/Users/alice/report.txt']));
      final outcome = await run.outcome;
      expect(outcome.payload['errorCode'], 'missing_artifact');
      expect(inner.last, isNull);
    },
  );

  test(
    'a step without inputs runs with an output folder inside the approved Space folder',
    () async {
      await root.setRoot(work.path);
      final inner = _RecordingLauncher();
      final run = await launcher(inner).launch(request([]));
      expect((await run.outcome).kind, TerminalKind.completed);
      final output = inner.last!['outputDirectory'] as String;
      expect(output, contains('spaces/space-1'));
      expect(await folders.isAllowed(output, write: true), isTrue);
    },
  );

  test('files are uploaded only when the step declared them', () async {
    await root.setRoot(work.path);
    final inner = _RecordingLauncher();
    final run = await launcher(inner).launch(request([]));
    final output = inner.last!['outputDirectory'] as String;
    await File('$output/secret.txt').writeAsString('not declared');
    // Nothing is declared, so nothing is uploaded; an upload would fail here
    // because this launcher has no session.
    final outcome = await run.outcome;
    expect(outcome.kind, TerminalKind.completed);
    expect(outcome.payload.containsKey('artifactIds'), isFalse);
  });

  test(
    'output declarations are validated and matched like the server does',
    () {
      expect(
        declaredOutputs(['report.md', '../x', 'a/b', '*.png', 'report.md', 3]),
        ['report.md', '*.png'],
      );
      expect(declaredOutputs('report.md'), isEmpty);
      expect(declaredOutputs(List.generate(20, (i) => 'f$i')), hasLength(8));
      expect(matchesDeclaredOutput(['*.png'], 'chart.png'), isTrue);
      expect(matchesDeclaredOutput(['*.png'], 'chart.jpg'), isFalse);
      expect(matchesDeclaredOutput(['report.md'], 'report.md'), isTrue);
      expect(matchesDeclaredOutput([], 'report.md'), isFalse);
    },
  );
}
