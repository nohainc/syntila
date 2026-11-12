import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syntila_protocol/syntila_protocol.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/ax/sync/ax_worker_visibility_preferences.dart';

class FakeSource implements AxDataSource, AxWorkerVisibilityDataSource {
  AxWorkerVisibility value = AxWorkerVisibility();
  bool fail = false;
  Completer<AxWorkerVisibility>? pending;
  @override
  Future<AxWorkerVisibility> loadWorkerVisibility(String workspaceId) async =>
      pending?.future ?? value;
  @override
  Future<AxWorkerVisibility> saveWorkerVisibility(
      String workspaceId, AxWorkerVisibility preferences) async {
    if (fail) throw StateError('save failed');
    return value = preferences;
  }

  @override
  Future<AxWorkerVisibility> resetWorkerVisibility(String workspaceId) async =>
      value = AxWorkerVisibility();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const catalog = ExecutionSelectionCatalog([
    WorkerSelectionCapability(
        id: 'w',
        name: 'Worker',
        catalogRevision: 'r1',
        allowedModelIds: [
          'm',
          'new'
        ],
        models: [
          ExecutionModelCapability(
              id: 'm',
              name: 'Model',
              selectionMode: 'combined',
              efforts: ['low', 'high']),
          ExecutionModelCapability(id: 'new', name: 'New', efforts: ['medium'])
        ]),
  ]);
  final hidden = AxWorkerVisibility(hiddenWorkers: [
    'w'
  ], hiddenModels: {
    'w': ['m']
  }, hiddenEfforts: {
    'w': {
      'm': ['high']
    }
  });
  test(
      'projects only authorized supported options and retains hidden saved selection',
      () {
    final projected = AxWorkerVisibilityProjection(catalog, hidden,
        selected: const ExecutionSelection(
            worker: 'w', model: 'm', effort: 'high', catalogRevision: 'r1'));
    expect(projected.workers.single.catalogRevision, 'r1');
    expect(projected.workerLabel(projected.workers.single), contains('Hidden'));
    expect(projected.models('w'), {'m': contains('Hidden')});
    expect(projected.efforts('w', 'm'), ['high']);
    expect(projected.effortLabel('w', 'm', 'high'), contains('Hidden'));
    expect(projected.models('unknown'), isEmpty);
    expect(catalog.worker('w')!.model('m')!.selectionMode, 'combined');
    expect(
        catalog.worker('w')!.validatePreference(
            const ExecutionSelection(worker: 'w', model: 'm', effort: 'high')),
        isNull);
  });
  test('new options appear and efforts are model specific', () {
    final p = AxWorkerVisibilityProjection(
        catalog,
        AxWorkerVisibility(hiddenModels: {
          'w': ['m']
        }, hiddenEfforts: {
          'w': {
            'new': ['medium']
          }
        }));
    expect(p.models('w'), {'new': 'New'});
    expect(p.efforts('w', 'new'), isEmpty);
    expect(p.efforts('w', 'm'), isEmpty);
    expect(
        AxWorkerVisibilityProjection(catalog, AxWorkerVisibility())
            .models('w')
            .keys,
        containsAll(['m', 'new']));
  });
  test('scoped cache handles failed save, reset and session clearing',
      () async {
    final source = FakeSource();
    final engine = AxSyncEngine();
    final root = AxWorkerVisibilityPreferences(source, engine: engine);
    final scoped = root.forWorkspace('one');
    await scoped.ensure();
    await scoped.save(hidden);
    source.fail = true;
    await expectLater(scoped.save(AxWorkerVisibility()), throwsStateError);
    expect(engine.peek(scoped.query).data!.hiddenWorkers, ['w']);
    source.fail = false;
    await scoped.reset();
    expect(engine.peek(scoped.query).data!.hiddenWorkers, isEmpty);
    source.pending = Completer<AxWorkerVisibility>();
    final loading = scoped.refresh();
    root.clear();
    source.pending!.complete(hidden);
    await loading;
    expect(engine.peek(root.forWorkspace('one').query).hasData, isFalse);
  });
  test('API reads saves and resets versioned document', () async {
    final methods = <String>[];
    final client = AxApiClient(
        baseUrl: 'https://example.test/api',
        client: MockClient((request) async {
          methods.add(request.method);
          expect(
              request.url.path, '/api/workspaces/ws%2Fone/worker-preferences');
          if (request.method == 'PUT') {
            expect(jsonDecode(request.body), hidden.toJson());
          }
          return http.Response(
              jsonEncode({
                'preferences': request.method == 'DELETE'
                    ? AxWorkerVisibility().toJson()
                    : hidden.toJson()
              }),
              200);
        }));
    expect((await client.loadWorkerVisibility('ws/one')).hiddenWorkers, ['w']);
    await client.saveWorkerVisibility('ws/one', hidden);
    expect(
        (await client.resetWorkerVisibility('ws/one')).hiddenWorkers, isEmpty);
    expect(methods, ['GET', 'PUT', 'DELETE']);
  });
}
