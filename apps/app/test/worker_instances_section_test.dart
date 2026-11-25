import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syntila_app/src/features/workers/worker_instances_section.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/mcp_worker_pin.dart';
import 'package:syntila_app/src/ax/sync/ax_session_catalogs.dart';
import 'package:syntila_app/src/features/navigation/app_menu.dart';
import 'package:syntila_app/src/features/navigation/breadcrumb.dart';
import 'package:syntila_app/src/features/navigation/ax_shell_context.dart';
import 'package:syntila_app/src/navigation/ax_navigation.dart';
import 'package:syntila_protocol/syntila_protocol.dart';

void main() {
  testWidgets(
      'navigation names the Workers destination when the rollout is enabled',
      (tester) async {
    final source = _UxSource();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: GlobalAppMenu(
      shellContext: AxShellContext(
          navigation: const AxNavigation.workers(),
          spaces: const [],
          catalogs: AxSessionCatalogs(source)),
      onNavigateTo: (_) {},
      onOpenAbout: () {},
      onOpenExternal: (_) {},
      onLogout: () {},
    ))));
    await tester.tap(find.byTooltip('Application menu'));
    await tester.pumpAndSettle();
    expect(find.text('Workers'), findsOneWidget);
    expect(find.text('Workspaces'), findsNothing);
  });

  testWidgets('Workers breadcrumb also covers old Workspace detail links',
      (tester) async {
    final source = _UxSource();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AppBreadcrumb(
      shellContext: AxShellContext(
          navigation: const AxNavigation.worker('old-id'),
          spaces: const [],
          catalogs: AxSessionCatalogs(source)),
      onNavigateTo: (_) {},
      inkColor: Colors.black,
      mutedInk: Colors.grey,
    ))));
    await tester.pumpAndSettle();
    expect(find.text('Workers'), findsOneWidget);
    expect(find.text('Workspaces'), findsNothing);
  });
  test('pairing code addresses the configured backend and selected Worker',
      () async {
    final api = AxApiClient(
        baseUrl: 'https://auth.example/api',
        backendBaseUrl: 'https://backend.example/api',
        client: MockClient((request) async {
          if (request.url.path == '/api/backend-token') {
            return http.Response('{}', 401);
          }
          expect(request.method, 'POST');
          expect(request.url.path, '/api/workers/worker-1/pairing');
          return http.Response(
              jsonEncode({
                'challenge': {
                  'challengeId': 'challenge',
                  'secret': 'secret',
                  'workerId': 'worker-1'
                }
              }),
              201);
        }));
    final code = await api.pairWorkerInstance('worker-1');
    expect(code, startsWith('syntila-pair:v1:'));
    final payload = code.substring('syntila-pair:v1:'.length);
    expect(
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload)))),
        {
          's': 'https://backend.example',
          'w': 'worker-1',
          'c': 'challenge',
          'k': 'secret'
        });
  });
  testWidgets('loads and shows Workers', (tester) async {
    final enabled = _IdentitySource(true);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: WorkerInstancesSection(
          key: const ValueKey('enabled'), catalogs: AxSessionCatalogs(enabled)),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Workers'), findsOneWidget);
    expect(find.text('No Workers yet.'), findsOneWidget);
    expect(enabled.loads, 1);
  });

  testWidgets('distinguishes same-name Workers and unknown readiness',
      (tester) async {
    WorkerInstance worker(String id, bool known) => WorkerInstance(
          id: id,
          actorId: 'actor-$id',
          workerTypeId: 'type',
          workerTypeName: 'Type',
          name: 'Writer',
          description: id == 'worker-abcdefgh' ? 'Laptop' : '',
          enabled: true,
          online: true,
          ready: false,
          readinessKnown: known,
          createdAt: '2026-01-01',
          updatedAt: '2026-01-01',
        );
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WorkerInstancesList(
      workers: [
        worker('worker-abcdefgh', false),
        worker('worker-ijklmnop', true)
      ],
      error: null,
      onRefresh: () async => null,
    ))));
    expect(find.text('Writer'), findsNWidgets(2));
    expect(find.text('Type'), findsNWidgets(2));
    expect(find.text('Online'), findsNWidgets(2));
    expect(find.text('Readiness unknown'), findsNothing);
    expect(find.textContaining('abcdefgh'), findsNothing);
    expect(find.textContaining('ijklmnop'), findsNothing);
  });

  testWidgets('adds a Worker from the server Type list', (tester) async {
    final source = _ManagementSource();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WorkerInstancesList(
                workers: const [],
                error: null,
                onRefresh: () async => null,
                management: source))));
    await tester.tap(find.byKey(const ValueKey('add-worker-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'My Worker');
    await tester.tap(find.text('Add Worker').last);
    await tester.pumpAndSettle();
    expect(source.created, [('type', 'My Worker')]);
  });

  testWidgets(
      'Add Worker initializes name to selected type and updates it until edited',
      (tester) async {
    final source = _ManagementSource(types: const [
      (id: 'claude', name: 'Claude'),
      (id: 'codex', name: 'Codex'),
    ]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WorkerInstancesList(
                workers: const [],
                error: null,
                onRefresh: () async => null,
                management: source))));

    await tester.tap(find.byKey(const ValueKey('add-worker-button')));
    await tester.pumpAndSettle();

    final nameField = tester.widget<TextField>(find.byType(TextField));
    expect(nameField.controller?.text, 'Claude');
    expect(
        find.byKey(const ValueKey('add-worker-type-selector')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('add-worker-type-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codex').last);
    await tester.pumpAndSettle();
    expect(nameField.controller?.text, 'Codex');

    await tester.enterText(find.byType(TextField), 'Custom Worker');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('add-worker-type-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude').last);
    await tester.pumpAndSettle();
    expect(nameField.controller?.text, 'Custom Worker');

    await tester.tap(find.text('Add Worker').last);
    await tester.pumpAndSettle();
    expect(source.created, [('claude', 'Custom Worker')]);
  });

  testWidgets('renames, disables and confirms removal by Worker ID',
      (tester) async {
    final source = _ManagementSource();
    const worker = WorkerInstance(
        id: 'worker-12345678',
        actorId: 'actor',
        workerTypeId: 'type',
        workerTypeName: 'Type',
        name: 'Writer',
        description: '',
        enabled: true,
        online: false,
        ready: false,
        createdAt: 'now',
        updatedAt: 'now');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkerInstancesList(
                    workers: [worker],
                    error: null,
                    selectedWorkerId: 'worker-12345678',
                    onRefresh: () async => null,
                    management: source)))));
    expect(find.text('worker-12345..'), findsOneWidget);
    expect(find.byKey(const ValueKey('worker-detail-copy-id')), findsOneWidget);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Renamed',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(source.updates.single.$1, 'worker-12345678');
    expect(source.updates.single.$2, {'name': 'Renamed'});
    await tester.tap(find.text('Disable'));
    await tester.pumpAndSettle();
    expect(source.updates.last.$1, 'worker-12345678');
    expect(source.updates.last.$2, {'enabled': false});
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(source.removed, isEmpty);
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    expect(source.removed, ['worker-12345678']);
  });

  testWidgets('shows Pair when unpaired and Unpair when paired',
      (tester) async {
    final source = _ManagementSource();
    WorkerInstance makeWorker(String id, bool paired) => WorkerInstance(
          id: id,
          actorId: 'actor',
          workerTypeId: 'type',
          workerTypeName: 'Type',
          name: paired ? 'Paired' : 'Unpaired',
          description: '',
          enabled: true,
          online: false,
          paired: paired,
          ready: false,
          createdAt: 'now',
          updatedAt: 'now',
        );
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkerInstancesList(
                    workers: [makeWorker('w1', false), makeWorker('w2', true)],
                    error: null,
                    selectedWorkerId: 'w1',
                    onRefresh: () async => throw Exception('transient refresh'),
                    management: source)))));

    expect(find.text('Pair'), findsOneWidget);
    expect(find.text('Unpair'), findsNothing);
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();
    expect(find.text('pairing-code'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('copy-pairing-code-button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('copy-pairing-code-button')));
    await tester.pumpAndSettle();
    expect(find.text('Copied'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Disable'));
    await tester.pumpAndSettle();
    expect(source.updates.last.$1, 'w1');
    expect(source.updates.last.$2, {'enabled': false});
    expect(find.textContaining('Could not update Worker'), findsNothing);

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkerInstancesList(
                    workers: [makeWorker('w1', false), makeWorker('w2', true)],
                    error: null,
                    selectedWorkerId: 'w2',
                    onRefresh: () async => null,
                    management: source)))));
    expect(find.text('Unpair'), findsOneWidget);
    expect(find.text('Pair'), findsNothing);
  });

  testWidgets('detail actions update the Worker immediately', (tester) async {
    final source = _LiveSectionSource();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkerInstancesSection(
                    selectedWorkerId: 'w-live',
                    catalogs: AxSessionCatalogs(source))))));
    await tester.pumpAndSettle();
    expect(find.text('Writer'), findsOneWidget);
    expect(find.text('Offline'), findsWidgets);

    await tester.tap(find.text('Disable'));
    await tester.pumpAndSettle();
    expect(find.text('Disabled'), findsWidgets);

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    expect(find.text('Worker not found.'), findsOneWidget);
  });

  testWidgets(
      'clicking a Worker opens detail view with attributes and visibility table',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = _ManagementSource();
    const worker = WorkerInstance(
      id: 'wrk-detail-1',
      actorId: 'actor',
      workerTypeId: 'claude',
      workerTypeName: 'Claude Code',
      name: 'My Claude',
      description: '',
      enabled: true,
      online: true,
      paired: true,
      ready: true,
      deviceName: 'MacBook Pro',
      providerToolName: 'claude',
      providerToolVersion: '1.2.3',
      executionOptions: {
        'schemaVersion': 1,
        'models': {
          'supported': true,
          'discovery': 'static',
          'options': [
            {
              'id': 'claude-sonnet',
              'name': 'Claude Sonnet',
              'effort': {
                'supported': true,
                'values': ['low', 'high'],
              },
            },
          ],
        },
        'effort': {
          'supported': true,
          'values': ['low', 'high'],
        },
      },
      createdAt: 'now',
      updatedAt: 'now',
    );
    String? selectedId;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkerInstancesList(
      workers: const [worker],
      error: null,
      onRefresh: () async => null,
      management: source,
      onSelectWorker: (id) => selectedId = id,
    )))));
    await tester
        .tap(find.byKey(const ValueKey('worker-instance-wrk-detail-1')));
    await tester.pumpAndSettle();
    expect(selectedId, 'wrk-detail-1');

    var backed = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkerInstancesList(
      workers: const [worker],
      error: null,
      selectedWorkerId: 'wrk-detail-1',
      onBackToList: () => backed = true,
      onRefresh: () async => null,
      management: source,
    )))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('worker-detail-wrk-detail-1')),
        findsOneWidget);
    expect(find.text('MacBook Pro'), findsOneWidget);
    // Once in the Worker's own table, once in the members' table.
    expect(find.text('Claude Sonnet'), findsNWidgets(2));

    await tester.tap(find
        .byKey(const ValueKey('worker-visibility-effort-claude-sonnet-low')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('worker-visibility-save')));
    await tester.pumpAndSettle();
    expect(source.updates.last.$1, 'wrk-detail-1');
    expect(source.updates.last.$2, {
      'visibility': {
        'hiddenModels': <String>[],
        'hiddenEfforts': {
          'claude-sonnet': ['low'],
        },
      },
    });

    await tester.tap(find.byKey(const ValueKey('worker-detail-back')));
    await tester.pumpAndSettle();
    expect(backed, isTrue);
  });
}

class _ManagementSource implements AxWorkerManagementSource {
  _ManagementSource({this.types = const [(id: 'type', name: 'Type')]});
  final List<({String id, String name})> types;
  final updates = <(String, Map<String, Object?>)>[];
  final removed = <String>[];
  final created = <(String, String)>[];
  @override
  Future<List<({String id, String name})>> loadWorkerTypes() async => types;
  @override
  Future<void> createWorkerInstance(String typeId, String name) async =>
      created.add((typeId, name));
  @override
  Future<String> pairWorkerInstance(String id) async => 'pairing-code';
  @override
  Future<McpWorkerPinState> loadMcpWorkerPin(String id) async =>
      const McpWorkerPinState();
  @override
  Future<void> setMcpWorkerPin(String id, McpWorkerVersion version) async {}
  @override
  Future<void> clearMcpWorkerPin(String id) async {}
  @override
  Future<AxWorkerSpaceAccess> loadWorkerSpaceAccess(
          String workerId, String spaceId) async =>
      AxWorkerSpaceAccess(workerId: workerId, spaceId: spaceId);
  @override
  Future<AxWorkerSpaceAccess> saveWorkerSpaceAccess(
    String workerId,
    String spaceId,
    List<AxWorkerSpaceMemberAccess> members,
  ) async =>
      AxWorkerSpaceAccess(
          workerId: workerId, spaceId: spaceId, members: members);
  @override
  Future<AxWorkerMemberModelAccess> loadWorkerMemberModelAccess(
          String workerId) async =>
      const AxWorkerMemberModelAccess();
  @override
  Future<AxWorkerMemberModelAccess> saveWorkerMemberModelAccess(
          String workerId, AxWorkerMemberModelAccess access) async =>
      access;
  @override
  Future<void> revokeWorkerCredential(String id) async {}
  @override
  Future<void> updateWorkerInstance(
          String id, Map<String, Object?> changes) async =>
      updates.add((id, changes));
  @override
  Future<void> removeWorkerInstance(String id) async => removed.add(id);
}

class _IdentitySource implements AxDataSource, AxWorkerIdentityFeatureSource {
  _IdentitySource(this.enabled);
  final bool enabled;
  int loads = 0;
  @override
  Future<bool> workerIdentityEnabled() async => enabled;
  @override
  Future<List<WorkerInstance>> loadWorkerInstances() async {
    loads++;
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UxSource implements AxDataSource, AxWorkersUxFeatureSource {
  @override
  Future<bool> workersUxEnabled() async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LiveSectionSource extends _ManagementSource
    implements
        AxDataSource,
        AxWorkerIdentityFeatureSource,
        AxWorkersUxFeatureSource {
  var _workers = [
    const WorkerInstance(
      id: 'w-live',
      actorId: 'actor',
      workerTypeId: 'type',
      workerTypeName: 'Type',
      name: 'Writer',
      description: '',
      enabled: true,
      online: false,
      paired: true,
      ready: false,
      createdAt: 'now',
      updatedAt: 'now',
    ),
  ];

  @override
  Future<bool> workerIdentityEnabled() async => true;

  @override
  Future<bool> workersUxEnabled() async => true;

  @override
  Future<List<WorkerInstance>> loadWorkerInstances() async => _workers;

  @override
  Future<void> updateWorkerInstance(
      String id, Map<String, Object?> changes) async {
    await super.updateWorkerInstance(id, changes);
    _workers = [
      for (final w in _workers)
        if (w.id == id)
          WorkerInstance(
            id: w.id,
            actorId: w.actorId,
            workerTypeId: w.workerTypeId,
            workerTypeName: w.workerTypeName,
            name: (changes['name'] as String?) ?? w.name,
            description: w.description,
            enabled: (changes['enabled'] as bool?) ?? w.enabled,
            online: w.online,
            paired: w.paired,
            ready: w.ready,
            createdAt: w.createdAt,
            updatedAt: w.updatedAt,
          )
        else
          w,
    ];
  }

  @override
  Future<void> removeWorkerInstance(String id) async {
    await super.removeWorkerInstance(id);
    _workers = _workers.where((w) => w.id != id).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
