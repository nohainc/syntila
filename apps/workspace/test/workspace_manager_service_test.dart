import 'dart:async';
import 'dart:io';

import 'package:syntila_workspace/cloud_connection.dart';
import 'package:syntila_workspace/workspace.dart';
import 'package:syntila_workspace/workspace_lifecycle.dart';
import 'package:syntila_workspace/workspace_lifecycle_store.dart';
import 'package:syntila_workspace/workspace_manager_ipc.dart';
import 'package:syntila_workspace/workspace_manager_service.dart';
import 'package:test/test.dart';
import 'package:syntila_workspace/worker_readiness.dart';
import 'support/logical_worker_catalog_fixture.dart';

void main() {
  test(
    'service streams running check progress and terminal evidence over IPC',
    () async {
      final root = await Directory('/tmp').createTemp('ws-check-progress-');
      addTearDown(() => root.delete(recursive: true));
      final registry = LocalWorkerRegistry(
        dataDirectory: root,
        workspaceId: 'workspace-test',
      );
      await registry.create(
        catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
        localPermissions: const ['repository:read'],
        status: LocalWorkerStatus.ready,
      );
      final assessment = Completer<WorkerReadinessAssessment>();
      final monitor = WorkerReadinessMonitor(
        registry: registry,
        assessWorker: (_) => assessment.future,
      );
      addTearDown(monitor.dispose);
      final workspace = Workspace(
        config: WorkspaceConfig(dataDirectory: root),
        localWorkerRegistry: registry,
        workerReadinessMonitor: monitor,
      );
      final manager = WorkspaceManagerService(workspace);
      await manager.start();
      addTearDown(manager.close);
      final key = (await File(
        '${root.path}/runtime/manager-ipc.key',
      ).readAsString())
          .trim();
      final client = await WorkspaceManagerIpcClient.connect(
        socketPath: '${root.path}/runtime/manager.sock',
        key: key,
      );
      addTearDown(client.close);
      await client.subscribe();
      await expectLater(
        client.request('workers.refreshWorker'),
        throwsA(
          isA<WorkspaceManagerProtocolException>().having(
            (e) => e.code,
            'code',
            'invalid_request',
          ),
        ),
      );
      expect(
        await client.request(
          'workers.refreshWorker',
          payload: {'workerTypeId': 'chatgpt'},
        ),
        isA<Map>(),
      );
      final runningEvent = client.events.firstWhere((event) {
        final catalog = event['workerCatalog'];
        if (event['name'] != 'worker.catalogChanged' || catalog is! Map) {
          return false;
        }
        final checks = catalog['checks'];
        return checks is Map &&
            checks['chatgpt'] is Map &&
            (checks['chatgpt'] as Map)['phase'] == 'probe';
      });
      final check = monitor.checkNow(mode: LocalWorkerProbeMode.live);
      final event = await runningEvent.timeout(const Duration(seconds: 5));
      expect(
        (((event['workerCatalog'] as Map)['checks'] as Map)['chatgpt']
            as Map)['outcome'],
        'running',
      );
      assessment.complete(
        const WorkerReadinessAssessment(WorkerReadinessState.ready),
      );
      await check;
      final catalog = (await manager.snapshot())['workerCatalog'] as Map;
      expect(
        ((catalog['checks'] as Map)['chatgpt'] as Map)['outcome'],
        'passed',
      );
    },
    skip: Platform.isWindows ? 'POSIX only' : false,
  );

  test(
    'snapshot separates service health from configured Cloud intent',
    () async {
      final root = await Directory('/tmp').createTemp('ws-state-');
      addTearDown(() => root.delete(recursive: true));
      final connection = WorkspaceCloudConnection(
        uri: Uri.parse('https://cloud.example.test'),
        workspaceRuntimeId: 'runtime-test',
        workspaceId: 'workspace-test',
        factory: (_) async =>
            throw StateError('fixture must stay disconnected'),
      );
      addTearDown(connection.close);
      final workspace = Workspace(
        config: WorkspaceConfig(
          dataDirectory: root,
          connectOnStart: true,
          cloudUri: Uri.parse('wss://cloud.example.test/gateway?token=hidden'),
        ),
        cloudConnection: connection,
      );
      final manager = WorkspaceManagerService(workspace);
      final state = await manager.snapshot();
      final service = (state['service'] as Map).cast<String, Object?>();
      final cloud = (state['cloud'] as Map).cast<String, Object?>();
      expect(service['serviceHealthy'], isFalse);
      expect(cloud['desiredConnectionState'], 'connected');
      expect(cloud['connected'], isFalse);
      expect(cloud['effectiveUrl'], 'https://cloud.example.test');
      expect(cloud['acceptingNewWork'], isFalse);
    },
  );

  test(
    'allowed folders are managed over IPC without touching user files',
    () async {
      final root = await Directory('/tmp').createTemp('ws-folders-');
      addTearDown(() => root.delete(recursive: true));
      final workRoot = await Directory('${root.path}/work').create();
      final shared = await Directory('${root.path}/shared').create();
      File('${shared.path}/notes.md').writeAsStringSync('keep');
      final manager = WorkspaceManagerService(
        Workspace(
          config: WorkspaceConfig(
            dataDirectory: Directory('${root.path}/state'),
            workRootPath: workRoot.path,
          ),
        ),
      );
      try {
        await manager.start();
      } on SocketException catch (error) {
        if (error.osError?.errorCode == 1) {
          markTestSkipped('Execution sandbox blocks local Unix sockets.');
          return;
        }
        rethrow;
      }
      addTearDown(manager.close);
      final key = (await File(
        '${root.path}/state/runtime/manager-ipc.key',
      ).readAsString())
          .trim();
      final client = await WorkspaceManagerIpcClient.connect(
        socketPath: '${root.path}/state/runtime/manager.sock',
        key: key,
      );
      addTearDown(client.close);

      final added = await client.request(
        'folders.add',
        payload: {'path': shared.path, 'displayName': 'Shared docs'},
      ) as Map;
      expect(added['displayName'], 'Shared docs');
      expect(added['status'], 'available');
      await expectLater(
        client.request('folders.add', payload: {'path': workRoot.path}),
        throwsA(
          isA<WorkspaceManagerProtocolException>().having(
            (error) => error.code,
            'code',
            'protected',
          ),
        ),
      );

      final listed = await client.request('folders.list') as Map;
      expect((listed['folders'] as List).single['id'], added['id']);
      expect(
        await client.request(
          'folders.remove',
          payload: {'folderId': added['id']},
        ),
        {'removed': true},
      );
      expect(
        ((await client.request('folders.list') as Map)['folders'] as List),
        isEmpty,
      );
      expect(File('${shared.path}/notes.md').readAsStringSync(), 'keep');
    },
    skip: Platform.isWindows ? 'POSIX only' : false,
  );

  test(
    'update checks are handled by the service without reconnecting Cloud',
    () async {
      final root = await Directory('/tmp').createTemp('ws-updates-');
      addTearDown(() => root.delete(recursive: true));
      var checks = 0;
      final workspace = Workspace(
        config: WorkspaceConfig(dataDirectory: root),
        updateHandler: (request) async {
          expect(request['action'], 'check');
          checks++;
          return const {'phase': 'idle'};
        },
      );
      final manager = WorkspaceManagerService(workspace);
      try {
        await manager.start();
      } on SocketException catch (error) {
        if (error.osError?.errorCode == 1) {
          markTestSkipped('Execution sandbox blocks local Unix sockets.');
          return;
        }
        rethrow;
      }
      addTearDown(manager.close);
      final key = (await File(
        '${root.path}/runtime/manager-ipc.key',
      ).readAsString())
          .trim();
      final client = await WorkspaceManagerIpcClient.connect(
        socketPath: '${root.path}/runtime/manager.sock',
        key: key,
      );
      addTearDown(client.close);

      expect(await client.request('updates.check'), {'phase': 'idle'});
      expect(checks, 1);
    },
    skip: Platform.isWindows ? 'POSIX only' : false,
  );

  test(
    'prepareStop drains Cloud admission while process shutdown stays host-owned',
    () async {
      final root = await Directory('/tmp').createTemp('ws-stop-');
      addTearDown(() => root.delete(recursive: true));
      var cloudAttempts = 0;
      final connection = WorkspaceCloudConnection(
        uri: Uri.parse('https://cloud.example.test'),
        workspaceRuntimeId: 'runtime-test',
        workspaceId: 'workspace-test',
        factory: (_) async {
          cloudAttempts++;
          throw StateError('This test must not open a Cloud connection');
        },
      );
      addTearDown(connection.close);
      final manager = WorkspaceManagerService(
        Workspace(
          config: WorkspaceConfig(dataDirectory: root),
          cloudConnection: connection,
        ),
      );
      try {
        await manager.start();
      } on SocketException catch (error) {
        if (error.osError?.errorCode == 1) {
          markTestSkipped('Execution sandbox blocks local Unix sockets.');
          return;
        }
        rethrow;
      }
      addTearDown(manager.close);
      final key = (await File(
        '${root.path}/runtime/manager-ipc.key',
      ).readAsString())
          .trim();
      final client = await WorkspaceManagerIpcClient.connect(
        socketPath: '${root.path}/runtime/manager.sock',
        key: key,
      );
      addTearDown(client.close);
      await expectLater(
        client.request(
          'configuration.update',
          payload: {'workRootPath': '${root.path}/work'},
        ),
        throwsA(
          isA<WorkspaceManagerProtocolException>().having(
            (error) => error.code,
            'code',
            'unsupported_command',
          ),
        ),
      );
      await client.request('service.prepareStop');
      expect(connection.acceptingNewWork, isFalse);
      expect(cloudAttempts, 0);
      // The IPC process remains available until the native host stops it.
      expect(await client.request('service.getStatus'), isA<Map>());
      await expectLater(
        client.request('service.shutdown'),
        throwsA(isA<WorkspaceManagerProtocolException>()),
      );
    },
    skip: Platform.isWindows ? 'POSIX only' : false,
  );
  test('configuration changes require a host restart', () async {
    final root = await Directory('/tmp').createTemp('ws-reload-');
    addTearDown(() => root.delete(recursive: true));
    final cloudGate = Completer<void>();
    var attempts = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
        'wss://cloud.example.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-test',
      ),
      workspaceRuntimeId: 'runtime-test',
      workspaceId: 'workspace-test',
      factory: (_) async {
        attempts++;
        await cloudGate.future;
        throw StateError('Offline fixture');
      },
    );
    final replacement = Workspace(
      config: WorkspaceConfig(
        dataDirectory: root,
        workRootPath: '${root.path}-work',
      ),
      cloudConnection: connection,
    );
    // User work cannot be nested inside this isolated application-data root.
    addTearDown(() async {
      if (!cloudGate.isCompleted) cloudGate.complete();
      await replacement.stop();
      final work = Directory('${root.path}-work');
      if (await work.exists()) await work.delete(recursive: true);
    });
    final preferences = WorkspaceLifecyclePreferencesStore(root);
    await preferences.write(
      preferences.readSync().copyWith(
            desiredRuntime: DesiredRuntimeState.connected,
          ),
    );
    final manager = WorkspaceManagerService(
      Workspace(config: WorkspaceConfig(dataDirectory: root)),
      reloadRuntime: () async => replacement,
    );
    await manager.start();
    addTearDown(manager.close);
    final key = (await File(
      '${root.path}/runtime/manager-ipc.key',
    ).readAsString())
        .trim();
    final client = await WorkspaceManagerIpcClient.connect(
      socketPath: '${root.path}/runtime/manager.sock',
      key: key,
    );
    addTearDown(client.close);
    await expectLater(
      client.request(
        'configuration.reload',
        timeout: const Duration(seconds: 2),
      ),
      throwsA(
        isA<WorkspaceManagerProtocolException>().having(
          (error) => error.code,
          'code',
          'unsupported_command',
        ),
      ),
    );
    expect(attempts, 0);
    expect(cloudGate.isCompleted, isFalse);
    expect(replacement.isRunning, isFalse);
    cloudGate.complete();
  }, skip: Platform.isWindows ? 'POSIX only' : false);
}
