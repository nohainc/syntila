import 'dart:async';
import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('mcp-supervisor-'));
  tearDown(() => root.deleteSync(recursive: true));

  CliWorkerEngineSupervisor supervisor(String script) =>
      CliWorkerEngineSupervisor(
        engineExecutable: '/bin/sh',
        engineArgumentsPrefix: ['-c', script, 'test-engine'],
        processRegistryDirectory: Directory('${root.path}/registry'),
      );

  Future<Map<String, Object?>> call(
    CliWorkerEngineSupervisor host, {
    FutureOr<bool> Function()? authorize,
    FutureOr<bool> Function()? claim,
  }) => host.executeMcpToolCall(
    assignmentId: 'assignment',
    stateDirectory: Directory('${root.path}/state'),
    workingDirectory: root,
    maxConcurrentAssignments: 1,
    prepareRequest: () => {'tool': 'echo'},
    claimDispatch: claim ?? () => true,
    timeout: const Duration(seconds: 2),
    authorizeStart: authorize,
  );

  test('owns and executes a one-shot Engine in the shared pool', () async {
    final host = supervisor(
      r'''read request; printf '%s\n' '{"state":"completed","code":"completed","result":{"ok":true}}' ''',
    );
    final result = await call(host);
    expect(result['state'], 'completed');
    expect((result['result'] as Map)['ok'], isTrue);
    expect(host.activeSlotCount, 0);
    expect(Directory('${root.path}/registry').listSync(), isEmpty);
  }, skip: Platform.isWindows);

  test('does not start the Engine when authorization is revoked', () async {
    final marker = File('${root.path}/started');
    final host = supervisor('touch "${marker.path}"');
    final result = await call(host, authorize: () => false);
    expect(result['state'], 'rejected');
    expect(marker.existsSync(), isFalse);
    expect(host.activeSlotCount, 0);
  }, skip: Platform.isWindows);

  test('a missing result after dispatch is unknown', () async {
    final host = supervisor('read request; exit 1');
    final result = await call(host);
    expect(result['state'], 'unknown');
    expect(host.activeSlotCount, 0);
  }, skip: Platform.isWindows);

  test(
    'duplicate and failed claims never send a request to the Engine',
    () async {
      final marker = File('${root.path}/received');
      final host = supervisor('read request && touch "${marker.path}"');
      final duplicate = await call(host, claim: () => false);
      expect(duplicate['code'], 'dispatch_already_claimed');
      expect(marker.existsSync(), isFalse);
      final failed = await call(
        host,
        claim: () => throw StateError('disk error'),
      );
      expect(failed['state'], 'unknown');
      expect(marker.existsSync(), isFalse);
    },
    skip: Platform.isWindows,
  );

  test('cancelling a dispatched call does not claim it was rejected', () async {
    final marker = File('${root.path}/started');
    final host = supervisor('read request; touch "${marker.path}"; sleep 30');
    final outcome = call(host);
    for (var i = 0; i < 200 && !marker.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(marker.existsSync(), isTrue);
    expect(await host.cancel('assignment'), isTrue);
    expect((await outcome)['state'], 'unknown');
    expect(host.activeSlotCount, 0);
  }, skip: Platform.isWindows);

  group('crash and failure at each lifecycle boundary', () {
    Future<Map<String, Object?>> callWith(
      CliWorkerEngineSupervisor host, {
      FutureOr<Map<String, Object?>> Function()? prepare,
      FutureOr<bool> Function()? claim,
      Duration timeout = const Duration(seconds: 2),
    }) => host.executeMcpToolCall(
      assignmentId: 'assignment',
      stateDirectory: Directory('${root.path}/state'),
      workingDirectory: root,
      maxConcurrentAssignments: 1,
      prepareRequest: prepare ?? () => {'tool': 'echo'},
      claimDispatch: claim ?? () => true,
      timeout: timeout,
    );

    test('admission failure is rejected: no Engine, no claim', () async {
      final started = File('${root.path}/started');
      var claimed = false;
      final host = supervisor('touch "${started.path}"');
      final result = await callWith(
        host,
        prepare: () => throw StateError('consent revoked'),
        claim: () {
          claimed = true;
          return true;
        },
      );
      expect(result['state'], 'rejected');
      expect(claimed, isFalse);
      expect(started.existsSync(), isFalse);
      expect(host.activeSlotCount, 0);
    }, skip: Platform.isWindows);

    test('an Engine that dies before reading the request is unknown', () async {
      final host = supervisor('exit 7');
      final result = await callWith(host);
      expect(result['state'], 'unknown');
      expect(host.activeSlotCount, 0);
    }, skip: Platform.isWindows);

    test(
      'a garbled or out-of-contract answer is unknown, never a success',
      () async {
        for (final answer in [
          'not json',
          '{"state":"completed"}',
          '{"state":"great","code":"x"}',
          '{"state":"completed","code":5}',
        ]) {
          final host = supervisor("read request; printf '%s\\n' '$answer'");
          final result = await callWith(host);
          expect(result['state'], 'unknown', reason: answer);
          expect(result.containsKey('result'), isFalse, reason: answer);
        }
      },
      skip: Platform.isWindows,
    );

    test('a valid answer followed by a non-zero exit is unknown', () async {
      final host = supervisor(
        r'''read request; printf '%s\n' '{"state":"completed","code":"completed"}'; exit 3''',
      );
      expect((await callWith(host))['state'], 'unknown');
    }, skip: Platform.isWindows);

    test(
      'no answer before the deadline is unknown and frees the slot',
      () async {
        final host = supervisor('read request; sleep 30');
        final result = await callWith(
          host,
          timeout: const Duration(seconds: 1),
        );
        expect(result['state'], 'unknown');
        expect(host.activeSlotCount, 0);
      },
      skip: Platform.isWindows,
    );

    test(
      'the claim runs after admission and before the Engine sees bytes',
      () async {
        final order = <String>[];
        final received = File('${root.path}/received');
        final host = supervisor('read request && touch "${received.path}"');
        await callWith(
          host,
          prepare: () {
            order.add('prepare');
            return {'tool': 'echo'};
          },
          claim: () {
            order.add('claim:received=${received.existsSync()}');
            return true;
          },
        );
        expect(order, ['prepare', 'claim:received=false']);
      },
      skip: Platform.isWindows,
    );

    test(
      'process kill with SIGKILL between claim and write ends unknown and cleans up',
      () async {
        final pidFile = File('${root.path}/engine.pid');
        final received = File('${root.path}/received');
        final host = supervisor(
          'echo \$\$ > "${pidFile.path}"; read request && touch "${received.path}"; exit 0',
        );
        final result = await callWith(
          host,
          claim: () async {
            for (var i = 0; i < 200 && !pidFile.existsSync(); i++) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            final pid = int.parse(pidFile.readAsStringSync().trim());
            Process.killPid(pid, ProcessSignal.sigkill);
            return true;
          },
        );
        expect(result['state'], 'unknown');
        expect(
          result['code'],
          anyOf('outcome_unknown', 'invalid_engine_response'),
        );
        expect(received.existsSync(), isFalse);
        expect(host.activeSlotCount, 0);
      },
      skip: Platform.isWindows,
    );
  });
}
