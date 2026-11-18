import 'dart:io';

import 'package:syntila_workspace/assignment_journal.dart';
import 'package:syntila_workspace/provider_failure_cipher.dart';
import 'package:syntila_workspace/secure_credentials.dart';
import 'package:test/test.dart';

class _MemoryCredentials implements SecureCredentialStore {
  final values = <String, String>{};
  @override
  String? readSync(String key) => values[key];
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test('encrypts provider failures and replays them after restart', () async {
    final directory =
        await Directory.systemTemp.createTemp('encrypted-journal-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/assignments.jsonl');
    final store = _MemoryCredentials();
    AssignmentJournal journal() => AssignmentJournal(file,
        providerFailureCipher:
            ProviderFailureCipher(store, file, 'install-test'));
    await journal().append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.failed,
      updatedAt: DateTime.utc(2026),
      result: {
        'error': 'failed',
        'providerFailure': {
          'schemaVersion': 1,
          'source': 'stderr',
          'providerErrorText': 'secret output',
        },
      },
    ));
    expect(await file.readAsString(), isNot(contains('secret output')));
    final restored = (await journal().find('assignment-1'))!
        .result!['providerFailure'] as Map;
    expect(restored['providerErrorText'], 'secret output');
    final savedCredentials = Map<String, String>.of(store.values);
    store.values.clear();
    // Losing the key must not make the journal unreadable.
    await journal().append(AssignmentRecord(
      assignmentId: 'unrelated',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.utc(2026),
      result: {'summary': 'ok'},
    ));
    final degraded = journal();
    final lost = (await degraded.find('assignment-1'))!;
    expect(lost.status, AssignmentStatus.failed);
    expect(lost.result!['error'], 'failed');
    expect(lost.result!.containsKey('providerFailure'), isFalse);
    expect(lost.result!['providerFailureUnavailable'], true);
    expect(
        (await degraded.find('unrelated'))!.status, AssignmentStatus.completed);
    expect(await file.readAsString(), isNot(contains('secret output')));
    final lines = await file.readAsLines();
    await file
        .writeAsString('${List.filled(500, lines.join('\n')).join('\n')}\n');
    expect(await journal().compactIfNeeded(), isFalse);
    store.values.addAll(savedCredentials);
    expect(
        ((await journal().find('assignment-1'))!.result!['providerFailure']
            as Map)['providerErrorText'],
        'secret output');
    store.values.clear();
    await expectLater(
        journal().append(AssignmentRecord(
          assignmentId: 'another',
          status: AssignmentStatus.failed,
          updatedAt: DateTime.utc(2026),
          result: {
            'providerFailure': {'source': 'stderr'}
          },
        )),
        throwsStateError);
  });
  test('binds encrypted details to the assignment and rejects tampering',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('cipher-integrity-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/assignments.jsonl');
    final cipher =
        ProviderFailureCipher(_MemoryCredentials(), file, 'install-test');
    final envelope =
        await cipher.encrypt('assignment-1', {'providerErrorText': 'private'});
    await expectLater(
        cipher.decrypt('assignment-2', envelope), throwsA(isA<Exception>()));
    final altered = Map<String, Object?>.from(envelope);
    final ciphertext = altered['ciphertext'] as String;
    altered['ciphertext'] =
        '${ciphertext[0] == 'A' ? 'B' : 'A'}${ciphertext.substring(1)}';
    await expectLater(
        cipher.decrypt('assignment-1', altered), throwsA(isA<Exception>()));
  });
  test('reconciles the latest idempotent assignment state', () async {
    final directory = await Directory.systemTemp.createTemp('syntila-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.running,
      updatedAt: DateTime.utc(2026, 1, 1),
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
      result: {'ok': true},
    ));

    final state = await journal.reconcile();
    expect(state['assignment-1']!.status, AssignmentStatus.completed);
    expect(state['assignment-1']!.result?['ok'], true);
    await directory.delete(recursive: true);
  });

  test('ignores a truncated final record after a process crash', () async {
    final directory = await Directory.systemTemp.createTemp('journal-');
    final file = File('${directory.path}/assignments.jsonl');
    final journal = AssignmentJournal(file);
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.utc(2026, 1, 1),
    ));
    await file.writeAsString('{"assignmentId":"partial"',
        mode: FileMode.append);
    final state = await journal.reconcile();
    expect(state['assignment-1']!.status, AssignmentStatus.completed);
    await directory.delete(recursive: true);
  });

  test('rejects corruption in a complete non-final record', () async {
    final directory = await Directory.systemTemp.createTemp('journal-');
    final file = File('${directory.path}/assignments.jsonl');
    await file.writeAsString(
      '{"assignmentId":"assignment-1","status":"running","updatedAt":"2026-01-01T00:00:00Z"}\n'
      '{"assignmentId":"assignment-2","status":"running"}\n',
    );
    await expectLater(
      AssignmentJournal(file).reconcile(),
      throwsFormatException,
    );
    await directory.delete(recursive: true);
  });

  test('uses the later record when timestamps are equal', () async {
    final directory = await Directory.systemTemp.createTemp('journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final timestamp = DateTime.utc(2026, 1, 1);
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.received,
      updatedAt: timestamp,
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.accepted,
      updatedAt: timestamp,
    ));
    expect((await journal.reconcile())['assignment-1']!.status,
        AssignmentStatus.accepted);
    await directory.delete(recursive: true);
  });

  test('uses timestamps rather than append order during replay', () async {
    final directory = await Directory.systemTemp.createTemp('journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.utc(2026, 1, 2),
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.running,
      updatedAt: DateTime.utc(2026, 1, 1),
    ));
    expect((await journal.reconcile())['assignment-1']!.status,
        AssignmentStatus.completed);
    await directory.delete(recursive: true);
  });

  test('rejects a transition from a terminal state back to running', () async {
    final directory = await Directory.systemTemp.createTemp('journal-');
    final file = File('${directory.path}/assignments.jsonl');
    final journal = AssignmentJournal(file);
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.utc(2026, 1, 1),
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.running,
      updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
    ));
    await expectLater(journal.reconcile(), throwsFormatException);
    await directory.delete(recursive: true);
  });

  test('marks started work outcome-unknown after a service restart', () async {
    final directory =
        await Directory.systemTemp.createTemp('journal-recovery-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-running',
      status: AssignmentStatus.running,
      updatedAt: DateTime.utc(2026, 1, 1),
      workerId: 'worker-1',
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-received',
      status: AssignmentStatus.received,
      updatedAt: DateTime.utc(2026, 1, 1),
    ));

    final recovered = await journal.recoverAfterRestart();
    expect(
        recovered['assignment-running']!.status, AssignmentStatus.interrupted);
    expect(recovered['assignment-running']!.result?['recoveryState'],
        'outcome_unknown');
    expect(recovered['assignment-received']!.result?['recoveryState'],
        'not_started');
    final recoveredAgain = await journal.recoverAfterRestart();
    expect(
        recoveredAgain.values
            .where((record) => record.status == AssignmentStatus.interrupted)
            .length,
        2);
    await directory.delete(recursive: true);
  });

  test('find sees appends made through the same instance without a reload',
      () async {
    final directory = await Directory.systemTemp.createTemp('journal-find-');
    addTearDown(() => directory.delete(recursive: true));
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    expect(await journal.find('assignment-1'), isNull);
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.received,
      updatedAt: DateTime.utc(2026, 1, 1),
    ));
    expect((await journal.find('assignment-1'))!.status,
        AssignmentStatus.received);
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.running,
      updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
    ));
    expect(
        (await journal.find('assignment-1'))!.status, AssignmentStatus.running);
  });

  test('notices a record written to the file outside this instance', () async {
    final directory = await Directory.systemTemp.createTemp('journal-ext-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/assignments.jsonl');
    final journal = AssignmentJournal(file);
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.running,
      updatedAt: DateTime.utc(2026, 1, 1),
    ));
    expect(
        (await journal.find('assignment-1'))!.status, AssignmentStatus.running);
    await file.writeAsString(
      '{"assignmentId":"assignment-1","status":"completed",'
      '"updatedAt":"2026-01-02T00:00:00Z"}\n',
      mode: FileMode.append,
    );
    expect((await journal.find('assignment-1'))!.status,
        AssignmentStatus.completed);
  });

  test('a returned snapshot can be iterated while appending', () async {
    final directory = await Directory.systemTemp.createTemp('journal-iter-');
    addTearDown(() => directory.delete(recursive: true));
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    for (var i = 0; i < 3; i++) {
      await journal.append(AssignmentRecord(
        assignmentId: 'assignment-$i',
        status: AssignmentStatus.running,
        updatedAt: DateTime.utc(2026, 1, 1),
      ));
    }
    for (final record in (await journal.reconcile()).values) {
      await journal.append(AssignmentRecord(
        assignmentId: record.assignmentId,
        status: AssignmentStatus.interrupted,
        updatedAt: DateTime.utc(2026, 1, 2),
      ));
    }
    expect((await journal.reconcile()).length, 3);
  });

  test('compacts a large, mostly superseded journal and keeps latest state',
      () async {
    final directory = await Directory.systemTemp.createTemp('journal-compact-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/assignments.jsonl');
    final journal = AssignmentJournal(file);
    var tick = 0;
    DateTime next() => DateTime.utc(2026, 1, 1).add(Duration(seconds: tick++));
    for (var i = 0; i < 400; i++) {
      for (final status in const [
        AssignmentStatus.received,
        AssignmentStatus.accepted,
        AssignmentStatus.running,
        AssignmentStatus.completed,
      ]) {
        await journal.append(AssignmentRecord(
          assignmentId: 'assignment-$i',
          status: status,
          updatedAt: next(),
        ));
      }
    }
    expect(file.readAsLinesSync().length, 1600);

    expect(await journal.compactIfNeeded(), isTrue);

    expect(file.readAsLinesSync().length, 400);
    final fresh = await AssignmentJournal(file).reconcile();
    expect(fresh.length, 400);
    expect(fresh.values.every((r) => r.status == AssignmentStatus.completed),
        isTrue);
    // Appending after compaction still works and is seen immediately.
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-new',
      status: AssignmentStatus.received,
      updatedAt: next(),
    ));
    expect((await journal.find('assignment-new'))!.status,
        AssignmentStatus.received);
    expect(await journal.compactIfNeeded(), isFalse);
  });
}
