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
}
