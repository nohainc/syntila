import 'dart:convert';

import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/features/workspace/workspace_member_access_section.dart';
import 'workflow_editor_test.dart' show worker;

class AccessSource implements AxWorkspaceMemberAccessDataSource {
  AccessSource([this.access = const AxWorkspaceMemberAccess()]);
  AxWorkspaceMemberAccess access;
  final saves = <AxWorkspaceMemberAccess>[];
  bool failLoad = false;
  @override
  Future<AxWorkspaceMemberAccess> loadWorkspaceMemberAccess(
      String workspaceId) async {
    if (failLoad) throw StateError('offline');
    return access;
  }

  @override
  Future<AxWorkspaceMemberAccess> saveWorkspaceMemberAccess(
      String workspaceId, AxWorkspaceMemberAccess next) async {
    saves.add(next);
    return access = next;
  }
}

Future<void> pump(WidgetTester tester, AccessSource source) async {
  await tester.binding.setSurfaceSize(const Size(900, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SingleChildScrollView(
              child: WorkspaceMemberAccessSection(
                  workspaceId: 'ws',
                  workers: [worker('a'), worker('b', workspaceId: 'elsewhere')],
                  source: source)))));
  await tester.pumpAndSettle();
}

void main() {
  test('policy JSON round-trips and omits workers when unrestricted', () {
    final access = AxWorkspaceMemberAccess.fromJson({
      'restricted': true,
      'policy': {
        'schemaVersion': 1,
        'workers': {
          'a': {
            'models': ['analysis'],
            'efforts': null,
            'modelEfforts': {
              'analysis': ['low']
            }
          }
        }
      }
    });
    expect(access.workers['a']!.models, ['analysis']);
    expect(access.workers['a']!.efforts, isNull);
    expect(access.workers['a']!.modelEfforts?['analysis'], ['low']);
    expect(access.toJson()['workers'], {
      'a': {
        'models': ['analysis'],
        'efforts': null,
        'modelEfforts': {
          'analysis': ['low']
        }
      }
    });
    expect(const AxWorkspaceMemberAccess().toJson(), {'restricted': false});
  });

  test('mode and person access parse; unknown modes are ignored', () {
    final access = AxWorkspaceMemberAccess.fromJson({
      'restricted': true,
      'policy': {'mode': 'work', 'workers': {}}
    });
    expect(access.mode, 'work');
    expect(access.toJson()['mode'], 'work');
    expect(
        AxWorkspaceMemberAccess.fromJson({
          'restricted': true,
          'policy': {'mode': 'root', 'workers': {}}
        }).mode,
        isNull);
    final person = AxPersonAccess.fromJson({
      'custom': true,
      'policy': {'mode': 'chat', 'workers': {}}
    });
    expect(person.custom, isTrue);
    expect(person.access.mode, 'chat');
    expect(
        AxPersonAccess.fromJson({'custom': false, 'policy': null})
            .access
            .restricted,
        isFalse);
  });

  testWidgets(
      'always limited: shows only this Workspace Workers, no switch or mode',
      (tester) async {
    final source = AccessSource();
    await pump(tester, source);
    expect(
        find.byKey(const ValueKey('member-access-restricted')), findsNothing);
    expect(find.byKey(const ValueKey('member-mode-chat')), findsNothing);
    expect(find.byKey(const ValueKey('share-worker-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('share-worker-b')), findsNothing);
  });

  testWidgets('shares a Worker with chosen models and efforts, then saves',
      (tester) async {
    final source = AccessSource();
    await pump(tester, source);
    await tester.tap(find.byKey(const ValueKey('share-worker-a')));
    await tester.pumpAndSettle();
    // Deselecting one model narrows "All" to the rest.
    await tester.tap(find.byKey(const ValueKey('member-model-review-a')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('member-effort-analysis-high-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('member-access-save')));
    await tester.pumpAndSettle();
    expect(source.saves, hasLength(1));
    expect(source.saves.single.restricted, isTrue);
    expect(source.saves.single.workers['a']!.models, ['analysis']);
    expect(
        source.saves.single.workers['a']!.modelEfforts?['analysis'], ['low']);
    // Saved state is clean again.
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('member-access-save')))
            .onPressed,
        isNull);
  });

  testWidgets('handles independent effort selection per model', (tester) async {
    final source = AccessSource();
    await pump(tester, source);
    await tester.tap(find.byKey(const ValueKey('share-worker-a')));
    await tester.pumpAndSettle();
    // Both models analysis and review are active.
    // analysis has low, high; review has thorough.
    expect(find.byKey(const ValueKey('member-effort-analysis-high-a')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('member-effort-review-thorough-a')),
        findsOneWidget);
    // Select low for analysis only (by toggling off high)
    await tester
        .tap(find.byKey(const ValueKey('member-effort-analysis-high-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('member-access-save')));
    await tester.pumpAndSettle();
    expect(source.saves, hasLength(1));
    expect(source.saves.single.workers['a']!.models, isNull); // All models
    expect(
        source.saves.single.workers['a']!.modelEfforts?['analysis'], ['low']);
    expect(source.saves.single.workers['a']!.modelEfforts?['review'], isNull);
  });

  testWidgets('load failure is retryable', (tester) async {
    final source = AccessSource()..failLoad = true;
    await pump(tester, source);
    expect(find.text('Member access could not be loaded.'), findsOneWidget);
    source.failLoad = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('member-access-save')), findsOneWidget);
  });

  testWidgets('displays official provider icons for workers in the table',
      (tester) async {
    final source = AccessSource();
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const geminiWorker = AxWorker(
      id: 'w-gemini',
      workspaceId: 'ws',
      workspaceName: 'Laptop',
      workerTypeId: 'gemini',
      displayName: 'Gemini',
      status: 'ready',
      readinessState: 'ready',
      localConcurrencyLimit: 1,
    );
    const chatgptWorker = AxWorker(
      id: 'w-chatgpt',
      workspaceId: 'ws',
      workspaceName: 'Laptop',
      workerTypeId: 'chatgpt',
      displayName: 'ChatGPT',
      status: 'ready',
      readinessState: 'ready',
      localConcurrencyLimit: 1,
    );
    const claudeWorker = AxWorker(
      id: 'w-claude',
      workspaceId: 'ws',
      workspaceName: 'Laptop',
      workerTypeId: 'claude',
      displayName: 'Claude',
      status: 'ready',
      readinessState: 'ready',
      localConcurrencyLimit: 1,
    );
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkspaceMemberAccessSection(
                    workspaceId: 'ws',
                    workers: [geminiWorker, chatgptWorker, claudeWorker],
                    source: source)))));
    await tester.pumpAndSettle();

    final imageWidgets = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(
        imageWidgets.any((img) =>
            img.image is AssetImage &&
            (img.image as AssetImage).assetName ==
                'assets/worker_icons/gemini.png'),
        isTrue);
    expect(
        imageWidgets.any((img) =>
            img.image is AssetImage &&
            (img.image as AssetImage).assetName ==
                'assets/worker_icons/chatgpt.png'),
        isTrue);
    expect(
        imageWidgets.any((img) =>
            img.image is AssetImage &&
            (img.image as AssetImage).assetName ==
                'assets/worker_icons/claude.png'),
        isTrue);
  });

  test('API client reads shared Workers and manages member access', () async {
    final requests = <String>[];
    final client = AxApiClient(
      baseUrl: 'https://cloud.test/api',
      client: MockClient((request) async {
        requests.add('${request.method} ${request.url.path}'
            '${request.url.hasQuery ? '?${request.url.query}' : ''}');
        if (request.url.path.endsWith('/member-access')) {
          if (request.method == 'PUT') {
            expect(jsonDecode(request.body), {
              'restricted': true,
              'workers': {
                'a': {
                  'models': ['analysis'],
                  'efforts': null
                }
              }
            });
          }
          return http.Response(
              jsonEncode({
                'restricted': true,
                'policy': {
                  'schemaVersion': 1,
                  'workers': {
                    'a': {
                      'models': ['analysis'],
                      'efforts': null
                    }
                  }
                }
              }),
              200);
        }
        return http.Response(jsonEncode({'workers': []}), 200);
      }),
    );
    expect(await client.loadWorkspaceWorkerInventory(), isEmpty);
    final saved = await client.saveWorkspaceMemberAccess(
        'ws 1',
        const AxWorkspaceMemberAccess(restricted: true, workers: {
          'a': AxSharedWorker(models: ['analysis'])
        }));
    expect(saved.workers['a']!.models, ['analysis']);
    expect((await client.loadWorkspaceMemberAccess('ws 1')).restricted, isTrue);
    expect(requests, [
      'GET /api/workspace-workers?includeShared=true',
      'PUT /api/workspaces/ws%201/member-access',
      'GET /api/workspaces/ws%201/member-access',
    ]);
  });
}
