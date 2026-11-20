import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/ax_stores.dart';
import 'package:syntila_app/src/ax/sync/ax_session_catalogs.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/ax/sync/ax_realtime_cache_router.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'ax_fixture_data.dart';

class CatalogSource extends AxFixtureDataSource {
  int workflowReads = 0, workerReads = 0, grantReads = 0;
  Completer<List<AxBuiltinWorkflow>>? workflowResponse;
  Completer<List<AxWorker>>? workerResponse;
  bool fail = false;
  Completer<List<Map<String, dynamic>>>? grantResponse;
  List<AxBuiltinWorkflow> workflows = [
    AxBuiltinWorkflow.fromJson({'id': 'direct', 'name': 'Work', 'version': 2})
  ];
  List<AxWorker> workers = [
    AxWorker.fromJson({
      'id': 'worker',
      'workspaceId': 'workspace',
      'displayName': 'Shared Worker',
      'workspaceName': 'Machine',
      'readinessState': 'ready'
    })
  ];
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() {
    workflowReads++;
    if (fail) return Future.error(StateError('offline'));
    return workflowResponse?.future ?? Future.value(workflows);
  }

  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() {
    workerReads++;
    if (fail) return Future.error(StateError('offline'));
    return workerResponse?.future ?? Future.value(workers);
  }

  @override
  Future<List<Map<String, dynamic>>> loadSpaceWorkflowWorkspaceGrants(
      {required String spaceId}) {
    grantReads++;
    return grantResponse?.future ??
        Future.value([
          {'workspaceId': 'workspace'}
        ]);
  }
}

void main() {
  Future<void> drain() => Future<void>.delayed(Duration.zero);
  test(
      'global catalog and inventory share in-flight requests and immutable results',
      () async {
    final source = CatalogSource()
      ..workflowResponse = Completer<List<AxBuiltinWorkflow>>()
      ..workerResponse = Completer<List<AxWorker>>();
    final catalogs = AxSessionCatalogs(source);
    final workflows = catalogs.ensureWorkflows();
    final workers = catalogs.ensureWorkers();
    expect(catalogs.ensureWorkflows(), same(workflows));
    expect(catalogs.ensureWorkers(), same(workers));
    expect(source.workflowReads, 1);
    expect(source.workerReads, 1);
    source.workflowResponse!.complete(source.workflows);
    source.workerResponse!.complete(source.workers);
    await Future.wait<Object>([workflows, workers]);
    expect(await catalogs.ensureWorkflows(), same(await workflows));
    expect(await catalogs.ensureWorkers(), same(await workers));
    expect(() => catalogs.engine.peek(catalogs.workers).data!.clear(),
        throwsUnsupportedError);
    expect(source.workerReads, 1);
  });
  test(
      'Workflow TTL is 45 minutes; Worker TTL is 30 seconds with retained stale data',
      () async {
    var now = DateTime.utc(2026);
    final source = CatalogSource();
    final catalogs =
        AxSessionCatalogs(source, engine: AxSyncEngine(clock: () => now));
    final workflows = await catalogs.ensureWorkflows();
    final workers = await catalogs.ensureWorkers();
    now = now.add(const Duration(seconds: 29));
    await catalogs.ensureWorkers();
    expect(source.workerReads, 1);
    now = now.add(const Duration(seconds: 1));
    source.workerResponse = Completer<List<AxWorker>>();
    expect(await catalogs.ensureWorkers(), same(workers));
    expect(catalogs.engine.peek(catalogs.workers).isFetching, isTrue);
    expect(source.workerReads, 2);
    source.workerResponse!.complete([]);
    await drain();
    await catalogs.ensureWorkflows();
    expect(source.workflowReads, 1);
    now = DateTime.utc(2026).add(const Duration(minutes: 45));
    source.workflowResponse = Completer<List<AxBuiltinWorkflow>>();
    expect(await catalogs.ensureWorkflows(), same(workflows));
    expect(source.workflowReads, 2);
    source.workflowResponse!.complete(source.workflows);
    await drain();
  });
  test('inventory events refresh the single global query for all observers',
      () async {
    final source = CatalogSource();
    final store = AxStore(source);
    await store.catalogs.ensureWorkers();
    await store.catalogs.ensureWorkflows();
    var a = 0, b = 0;
    store.syncEngine
        .watch(store.catalogs.workers, (_) => a++, fireImmediately: false);
    store.syncEngine
        .watch(store.catalogs.workers, (_) => b++, fireImmediately: false);
    source.workers = [];
    await store.realtimeCacheRouter.handle(
        {'type': 'worker.inventory.updated', 'workspaceId': 'background'});
    expect(source.workerReads, 2);
    expect(store.syncEngine.peek(store.catalogs.workers).data, isEmpty);
    expect(a, greaterThan(0));
    expect(b, a);
    expect(source.workflowReads, 1);
  });
  test(
      'explicit Workflow invalidation refreshes observers and defers detached reads',
      () async {
    final source = CatalogSource();
    final catalogs = AxSessionCatalogs(source);
    await catalogs.ensureWorkflows();
    await catalogs.invalidateWorkflows();
    expect(source.workflowReads, 1);
    expect(catalogs.engine.peek(catalogs.workflows).isStale, isTrue);
    final cancel = catalogs.engine.watch(catalogs.workflows, (_) {});
    await catalogs.invalidateWorkflows();
    expect(source.workflowReads, 2);
    cancel();
  });
  test('failed refresh retains inventory and catalog data', () async {
    final source = CatalogSource();
    final catalogs = AxSessionCatalogs(source);
    final workers = await catalogs.ensureWorkers();
    final workflows = await catalogs.ensureWorkflows();
    source.fail = true;
    await expectLater(catalogs.refreshWorkers(), throwsStateError);
    await expectLater(
        catalogs.engine.refresh(catalogs.workflows), throwsStateError);
    expect(catalogs.engine.peek(catalogs.workers).data, same(workers));
    expect(catalogs.engine.peek(catalogs.workflows).data, same(workflows));
  });
  test(
      'session clear fences old responses and forces new catalog/inventory reads',
      () async {
    final source = CatalogSource()
      ..workerResponse = Completer<List<AxWorker>>();
    final store = AxStore(source);
    await store.catalogs.ensureWorkflows();
    final old = store.catalogs.ensureWorkers();
    store.clearServerState();
    source.workerResponse!.complete(source.workers);
    await old;
    expect(store.syncEngine.peek(store.catalogs.workers).hasData, isFalse);
    expect(store.syncEngine.peek(store.catalogs.workflows).hasData, isFalse);
    source.workerResponse = null;
    await store.catalogs.ensureWorkers();
    await store.catalogs.ensureWorkflows();
    expect(source.workerReads, 2);
    expect(source.workflowReads, 2);
  });
  test(
      'execution reconnect refreshes shared inventory without expiring Workflow catalog',
      () async {
    final source = CatalogSource();
    final catalogs = AxSessionCatalogs(source);
    await catalogs.ensureWorkers();
    await catalogs.ensureWorkflows();
    await AxRealtimeCacheRouter(catalogs.engine).handle({
      'type': 'sync.required',
      'scope': {'kind': 'execution_workspace', 'workspaceId': 'workspace'}
    });
    expect(source.workerReads, 2);
    expect(source.workflowReads, 1);
    expect(catalogs.engine.peek(catalogs.workflows).isStale, isFalse);
  });
  Widget page(String id, CatalogSource source, AxSessionCatalogs catalogs,
          {int initialTab = 0}) =>
      MaterialApp(
          home: Scaffold(
              body: ThreadPage(
        key: ValueKey(id),
        space: AxSpace.fromJson({'id': 'p', 'name': 'Space'}),
        thread: AxThread.fromJson({'id': id, 'spaceId': 'p', 'name': id}),
        dataSource: source,
        catalogs: catalogs,
        initialTab: initialTab,
        onBackToSpace: () {},
        onArchive: () {},
      )));
  testWidgets('recreated Threads reuse Workflow and Worker reads',
      (tester) async {
    final source = CatalogSource();
    final store = AxStore(source);
    await store.catalogs
        .ensureWorkers(); // Shell/bootstrap has already loaded it.
    await tester.pumpWidget(page('A', source, store.catalogs));
    await tester.pumpAndSettle();
    expect(source.workflowReads, 1);
    expect(source.workerReads, 1);
    await tester.pumpWidget(page('B', source, store.catalogs));
    await tester.pumpAndSettle();
    expect(source.workflowReads, 1);
    expect(source.workerReads, 1);
  });
  testWidgets('inventory change keeps Thread Work free of execution editors',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = CatalogSource();
    final store = AxStore(source);
    await tester.pumpWidget(page('A', source, store.catalogs, initialTab: 2));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Work settings'), findsNothing);
    source.workers = [];
    await store.realtimeCacheRouter
        .handle({'type': 'worker.inventory.updated'});
    await tester.pumpAndSettle();
    expect(find.byTooltip('Work settings'), findsNothing);
    expect(source.workerReads, 2);
    expect(source.workflowReads, 1);
  });
  testWidgets('delayed inventory cannot restore outdated Worker choices',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = CatalogSource()
      ..grantResponse = Completer<List<Map<String, dynamic>>>();
    final store = AxStore(source);
    await store.catalogs.ensureWorkers();
    await tester.pumpWidget(page('A', source, store.catalogs, initialTab: 2));
    await tester.pump(const Duration(milliseconds: 500));
    source.workers = [];
    await store.realtimeCacheRouter
        .handle({'type': 'worker.inventory.updated'});
    source.grantResponse!.complete([
      {'workspaceId': 'workspace'}
    ]);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Work settings'), findsNothing);
    expect(source.workerReads, 2);
  });
}
