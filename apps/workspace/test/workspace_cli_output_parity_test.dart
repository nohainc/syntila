import 'dart:io';
import 'package:syntila_workspace/workspace_cli.dart';
import 'package:syntila_workspace/workspace_manager_ipc.dart';
import 'package:test/test.dart';

void main() {
  final candidate = Platform.environment['SYNTILA_CLI'];
  test('compiled CLI matches source output across service commands', () async {
    final root = await Directory('/tmp').createTemp('syn-parity-');
    final worker = <String, Object?>{
      'workerId': 'w1',
      'productWorkerTypeId': 'gemini',
      'activationState': 'enabled',
      'readinessState': 'ready',
      'lastLiveTestPassed': true
    };
    final fixtures = <String, Object?>{
      'workers.list': [worker],
      'workers.checkReadiness': {
        'workers': [worker]
      },
      'workers.testWorker': worker,
      'workers.configureWorker': worker,
      'workers.removeWorker': {'workerId': 'w1', 'state': 'removed'},
      'workers.enableWorker': worker,
      'workers.disableWorker': worker,
      'folders.list': {
        'folders': [
          {
            'id': 'f1',
            'displayName': 'Project',
            'path': '/project',
            'status': 'ready'
          }
        ]
      },
      'folders.add': {
        'id': 'f1',
        'displayName': 'Project',
        'path': '/project',
        'status': 'ready'
      },
      'folders.remove': {'removed': true},
      'execution.getSlots': {
        'active': 1,
        'queued': 2,
        'limit': 5,
        'workers': [
          {'workerTypeId': 'gemini', 'active': 1, 'queued': 2}
        ],
        'activeAssignmentIds': ['a1']
      },
      'execution.listActiveAssignments': {
        'activeAssignmentIds': ['a1', 'a2']
      },
      'execution.cancelAssignment': {'cancelled': true},
      'diagnostics.getLogs': {'text': 'first line\nsecond line\n'},
      'diagnostics.getMetrics': {
        'processId': 42,
        'residentMemoryBytes': 1048576,
        'cpuPercent': 2,
        'sampledAt': 'today',
        'activeAssignments': 1,
        'workerCount': 1,
        'cloudConnected': true,
        'reconnectCount': 0
      },
      'connection.pause': {
        'cloud': {'connected': true, 'acceptingNewWork': false}
      },
      'connection.resume': {
        'cloud': {'connected': true, 'acceptingNewWork': true}
      },
    };
    Future<Object?> handler(
        String command, Map<String, Object?> payload) async {
      if (!fixtures.containsKey(command))
        throw StateError('Missing fixture: $command');
      return fixtures[command];
    }

    final server = WorkspaceManagerIpcServer(
        runtimeDirectory: Directory('${root.path}/runtime'),
        serviceVersion: 'parity',
        snapshotProvider: () async => {},
        requestHandler: handler);
    await server.start();
    final cases = <List<String>>[
      ['workers'],
      ['workers', 'check'],
      ['workers', 'test', 'gemini'],
      ['workers', 'add', 'gemini'],
      ['workers', 'remove', 'gemini'],
      ['workers', 'enable', 'gemini'],
      ['workers', 'disable', 'gemini'],
      ['folders'],
      ['folders', 'add', '/project', '--name', 'Project'],
      ['folders', 'remove', 'f1'],
      ['slots'],
      ['assignments'],
      ['assignments', 'cancel', 'a1'],
      ['metrics'],
      ['logs'],
      ['pause'],
      ['resume']
    ];
    try {
      for (final args in cases) {
        for (final json in [false, true]) {
          final full = ['--data-dir', root.path, if (json) '--json', ...args];
          final reference = await Process.run(candidate!, full);
          final out = StringBuffer(), err = StringBuffer();
          final code = await WorkspaceCli(out: out, err: err, request: handler)
              .run(full);
          final label = '${args.join(' ')} (json=$json)';
          expect(reference.exitCode, code, reason: label);
          expect(reference.stdout, out.toString(), reason: label);
          expect(reference.stderr, err.toString(), reason: label);
        }
      }
    } finally {
      await server.close();
      await root.delete(recursive: true);
    }
  },
      skip: candidate == null
          ? 'Set SYNTILA_CLI to a compiled candidate.'
          : false);
}
