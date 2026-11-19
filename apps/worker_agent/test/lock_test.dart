import 'dart:io';

import 'package:syntila_worker_agent/syntila_worker_agent.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(
    () async => dir = await Directory.systemTemp.createTemp('syntila-lock-'),
  );
  tearDown(() => dir.delete(recursive: true));

  test(
    'a second owner in the same process is refused until the first lets go',
    () async {
      final file = File('${dir.path}/agent.lock');
      final first = await AgentLock.acquire(file);
      await expectLater(
        AgentLock.acquire(file),
        throwsA(isA<AgentLockedException>()),
      );
      expect(await AgentLock.isHeld(file), isTrue);
      await first.release();
      expect(await AgentLock.isHeld(file), isFalse);
      final again = await AgentLock.acquire(file);
      await again.release();
    },
  );

  test(
    'a second process is refused while the first holds the directory',
    () async {
      final file = File('${dir.path}/agent.lock');
      final owner = await AgentLock.acquire(file);
      try {
        final result = await Process.run(Platform.resolvedExecutable, [
          'run',
          'test/fixtures/lock_attempt.dart',
          file.path,
        ]).timeout(const Duration(seconds: 60));
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      } finally {
        await owner.release();
      }
    },
  );

  test('two data directories never block each other', () async {
    final a = await AgentLock.acquire(File('${dir.path}/a/agent.lock'));
    final b = await AgentLock.acquire(File('${dir.path}/b/agent.lock'));
    await a.release();
    await b.release();
  });
}
