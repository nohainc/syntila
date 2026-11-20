import 'dart:io';

import 'package:syntila_connect/syntila_connect.dart';
import 'package:test/test.dart';

const ctx = AssignmentContext(
  runId: 'run',
  taskId: 'task',
  attemptId: 'att',
  idempotencyKey: 'idem',
);

void main() {
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('syntila-journal-');
    file = File('${dir.path}/commands/journal.jsonl');
  });
  tearDown(() => dir.delete(recursive: true));

  Future<AgentJournal> open() async {
    final journal = AgentJournal(file);
    await journal.open();
    return journal;
  }

  test('state survives a restart, in order', () async {
    var journal = await open();
    await journal.record(
      'a1',
      LocalStatus.received,
      context: ctx,
      command: {
        'payload': {'prompt': 'hi'},
      },
      correlation: {'assignmentId': 'a1'},
    );
    await journal.record('a1', LocalStatus.accepted);
    await journal.record('a1', LocalStatus.starting);
    await journal.close();
    journal = await open();
    final entry = journal.find('a1')!;
    expect(entry.status, LocalStatus.starting);
    expect(entry.engineStarts, 1);
    expect(entry.command, isNotNull);
    expect(entry.correlation['assignmentId'], 'a1');
    expect(journal.unacknowledged, hasLength(1));
    await journal.close();
  });

  test('a terminal record drops the command and keeps the result', () async {
    var journal = await open();
    await journal.record(
      'a1',
      LocalStatus.received,
      context: ctx,
      command: {'payload': {}},
    );
    await journal.record('a1', LocalStatus.accepted);
    await journal.record(
      'a1',
      LocalStatus.terminal,
      kind: TerminalKind.completed,
      terminal: {'summary': 's'},
    );
    expect(journal.find('a1')!.command, isNull);
    await journal.close();
    journal = await open();
    expect(journal.find('a1')!.terminalKind, TerminalKind.completed);
    expect(journal.find('a1')!.terminal, {'summary': 's'});
    await journal.close();
  });

  test('states only move forward', () async {
    final journal = await open();
    await expectLater(
      journal.record('x', LocalStatus.accepted),
      throwsA(isA<IllegalTransitionException>()),
      reason: 'the first record must be received',
    );
    await journal.record('a1', LocalStatus.received, context: ctx);
    await journal.record('a1', LocalStatus.accepted);
    await expectLater(
      journal.record('a1', LocalStatus.received, context: ctx),
      throwsA(isA<IllegalTransitionException>()),
    );
    await expectLater(
      journal.record('a1', LocalStatus.running),
      throwsA(isA<IllegalTransitionException>()),
      reason: 'running needs starting first',
    );
    await journal.record(
      'a1',
      LocalStatus.terminal,
      kind: TerminalKind.cancelled,
    );
    await expectLater(
      journal.record('a1', LocalStatus.starting),
      throwsA(isA<IllegalTransitionException>()),
      reason: 'a settled assignment never starts',
    );
    await journal.close();
  });

  test(
    'a partial last line from a crash mid-write is dropped and repaired',
    () async {
      var journal = await open();
      await journal.record('a1', LocalStatus.received, context: ctx);
      await journal.close();
      await file.writeAsString(
        '{"seq":2,"at":"2026-01-01T00:00:00Z","id":"a1","sta',
        mode: FileMode.append,
      );
      journal = await open();
      expect(journal.find('a1')!.status, LocalStatus.received);
      await journal.record('a1', LocalStatus.accepted);
      await journal.close();
      journal = await open(); // the repaired file replays cleanly
      expect(journal.find('a1')!.status, LocalStatus.accepted);
      await journal.close();
    },
  );

  test('damage anywhere else fails closed', () async {
    var journal = await open();
    await journal.record('a1', LocalStatus.received, context: ctx);
    await journal.close();
    final good = await file.readAsString();
    await file.writeAsString('garbage\n$good');
    await expectLater(open(), throwsA(isA<JournalCorruptedException>()));
    await file.writeAsString('$good$good'); // sequence goes backwards
    await expectLater(open(), throwsA(isA<JournalCorruptedException>()));
  });

  test('a hook that throws aborts the write: nothing is recorded', () async {
    final journal = AgentJournal(
      file,
      beforeWrite: (id, event) {
        if (event == 'accepted') throw SimulatedCrash('before-accepted');
      },
    );
    await journal.open();
    await journal.record('a1', LocalStatus.received, context: ctx);
    await expectLater(
      journal.record('a1', LocalStatus.accepted),
      throwsA(isA<SimulatedCrash>()),
    );
    expect(journal.find('a1')!.status, LocalStatus.received);
    await journal.close();
    final again = await open();
    expect(again.find('a1')!.status, LocalStatus.received);
    await again.close();
  });

  test('cancel intent is durable', () async {
    var journal = await open();
    await journal.record('a1', LocalStatus.received, context: ctx);
    await journal.recordCancelIntent('a1');
    await journal.close();
    journal = await open();
    expect(journal.find('a1')!.cancelRequested, isTrue);
    expect(journal.find('a1')!.status, LocalStatus.received);
    await journal.close();
  });

  test(
    'compaction drops old acknowledged entries and keeps the rest',
    () async {
      var now = DateTime.utc(2026, 1, 1);
      var journal = AgentJournal(file, clock: () => now);
      await journal.open();
      for (final id in ['old', 'live']) {
        await journal.record(
          id,
          LocalStatus.received,
          context: ctx,
          command: {'payload': {}},
        );
        await journal.record(id, LocalStatus.accepted);
      }
      await journal.record(
        'old',
        LocalStatus.terminal,
        kind: TerminalKind.completed,
      );
      await journal.record('old', LocalStatus.acknowledged);
      now = now.add(const Duration(days: 2));
      expect(await journal.compact(), 1);
      expect(journal.find('old'), isNull);
      expect(journal.find('live')!.command, isNotNull);
      await journal.close();
      journal = AgentJournal(file, clock: () => now);
      await journal.open();
      expect(journal.entries.map((e) => e.assignmentId), ['live']);
      await journal.record(
        'live',
        LocalStatus.starting,
      ); // still writable after compaction
      await journal.close();
    },
  );

  test('writes are serialized: concurrent records never interleave', () async {
    final journal = await open();
    await Future.wait([
      for (var i = 0; i < 25; i++)
        journal.record('a$i', LocalStatus.received, context: ctx),
    ]);
    await journal.close();
    final replay = await open();
    expect(replay.entries, hasLength(25));
    await replay.close();
  });
}
