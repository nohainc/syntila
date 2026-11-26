import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:syntila_connect/syntila_connect.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
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

  test('the Work Root maps Spaces under spaces/<space-id>', () async {
    final root = WorkRoot(File('${sandbox.path}/data/work-root.json'), folders);
    await expectLater(
      root.spaceDirectory('space-1'),
      throwsA(isA<FolderRejectedException>()),
    );
    await root.setRoot(work.path);
    final dir = await root.spaceDirectory('space-1');
    expect(dir.path, endsWith(p.join('spaces', 'space-1')));
    await expectLater(
      root.spaceDirectory('../escape'),
      throwsA(isA<FolderRejectedException>()),
    );
  });

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
  EngineRequest? lastRequest;
  @override
  Future<EngineRun> launch(EngineRequest request) async {
    last = request.payload;
    lastRequest = request;
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
      expect(output, contains(p.join('spaces', 'space-1')));
      expect(await folders.isAllowed(output, write: true), isTrue);
    },
  );

  test('forwards activity through the artifact staging wrapper', () async {
    await root.setRoot(work.path);
    final inner = _RecordingLauncher();
    final received = <String>[];
    final original = request([]);
    await launcher(inner).launch(
      EngineRequest(
        assignmentId: original.assignmentId,
        attemptId: original.attemptId,
        payload: original.payload,
        onActivity: (event) => received.add(event.title),
      ),
    );
    inner.lastRequest!.onActivity!(
      WorkerActivity(
        requestId: 'request',
        assignmentId: original.assignmentId,
        executionId: 'execution',
        workerId: 'chatgpt',
        eventId: 'event',
        sequence: 1,
        timestamp: DateTime.now().toUtc().toIso8601String(),
        eventType: 'tool.started',
        status: 'running',
        title: 'Searching the web',
      ),
    );
    expect(received, ['Searching the web']);
  });

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

  test('an invalid Git reference fails before the Engine starts', () async {
    await root.setRoot(work.path);
    final inner = _RecordingLauncher();
    final bad = EngineRequest(
      assignmentId: 'a1',
      attemptId: 't1',
      payload: {
        'snapshot': {
          'spaceId': 'space-1',
          'contextRefs': <Object?>[],
          'gitReferences': [
            {
              'kind': 'git',
              'remote': 'https://user:pw@github.com/a/b.git',
              'commit': 'a' * 40,
            },
          ],
        },
      },
    );
    final run = await launcher(inner).launch(bad);
    expect((await run.outcome).payload['errorCode'], 'invalid_git_reference');
    expect(inner.last, isNull);
  });

  test(
    'a stale fencing token fails the step before the Engine starts',
    () async {
      await root.setRoot(work.path);
      final inner = _RecordingLauncher();
      EngineRequest step(int token) => EngineRequest(
        assignmentId: 'a$token',
        attemptId: 't1',
        payload: {
          'snapshot': {
            'spaceId': 'space-1',
            'contextRefs': <Object?>[],
            'threadId': 'thread-1',
            'fencingToken': token,
          },
        },
      );
      await (await launcher(inner).launch(step(5))).outcome;
      expect(inner.last, isNotNull);
      inner.last = null;
      final stale = await launcher(inner).launch(step(4));
      expect((await stale.outcome).payload['errorCode'], 'stale_fence');
      expect(inner.last, isNull);
      await (await launcher(inner).launch(step(5))).outcome;
      expect(
        inner.last,
        isNotNull,
        reason: 'the same token may continue its lease',
      );
    },
  );

  test('Git references are validated like the server does', () {
    final ok = {
      'kind': 'git',
      'remote': 'https://github.com/nohainc/syntila.git',
      'commit': 'a' * 40,
      'ref': 'refs/heads/main',
    };
    expect(validGitReference(ok), isTrue);
    expect(validGitReferences(null), isTrue);
    expect(validGitReference({...ok, 'path': '/tmp'}), isFalse);
    expect(validGitReference({...ok, 'commit': 'main'}), isFalse);
    expect(
      validGitReference({...ok, 'remote': 'file:///Users/a/repo'}),
      isFalse,
    );
    expect(validGitReference({...ok, 'ref': 'refs/heads/a..b'}), isFalse);
    expect(validGitReferences(List.filled(9, ok)), isFalse);
  });
}
