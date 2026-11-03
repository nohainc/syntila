import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/ax/sync/ax_workflow_configurations.dart';
import 'workflows_page_test.dart' show WorkflowSource;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/features/workspace/workspaces_page.dart';
import 'package:syntila_app/src/features/common/workspace_release.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';

import 'ax_fixture_snapshot.dart';

void main() {
  Widget buildTestScaffold(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    );
  }

  group('Workspaces page', () {
    testWidgets(
        'Make default persists the selection inherited by Spaces and shows a badge',
        (tester) async {
      final source = WorkflowSource();
      final engine = AxSyncEngine();
      final configurations = AxWorkflowConfigurations(source, engine: engine);
      final inherited =
          AxWorkflowConfigurations(source, engine: engine, spaceId: 'S');
      final explicit =
          AxWorkflowConfigurations(source, engine: engine, spaceId: 'E');
      source.selectedSpaceWorkspaces['E'] = 'ws';
      await inherited.ensureWorkspace();
      await explicit.ensureWorkspace();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: [
          AxWorkspace.fromJson(
              {'id': 'ws', 'name': 'First Workspace', 'role': 'owner'}),
          AxWorkspace.fromJson(
              {'id': 'other', 'name': 'Second Workspace', 'role': 'owner'}),
        ],
        workflowConfigurations: configurations,
      )));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('default-workspace-badge')),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('workspace-tab-other')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('default-workspace-badge')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('make-default-workspace')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(source.workspaceWrites, 0);
      await tester.tap(find.byKey(const ValueKey('make-default-workspace')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-default-workspace')));
      await tester.pumpAndSettle();
      expect(source.selectedWorkspace, 'other');
      expect(source.workspaceWrites, 1);
      expect(find.byKey(const ValueKey('default-workspace-badge')),
          findsOneWidget);
      expect((await inherited.ensureWorkspace()).workspaceId, 'other');
      expect((await explicit.ensureWorkspace()).workspaceId, 'ws');
      await tester.tap(find.byKey(const Key('workspace-tab-ws')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('default-workspace-badge')), findsNothing);
      expect(
          find.byKey(const ValueKey('make-default-workspace')), findsOneWidget);
    });

    test('detects an available Workspace update', () {
      expect(workspaceUpdateAvailable('1.0.2'), isTrue);
      expect(workspaceUpdateAvailable('1.0.3'), isFalse);
      expect(workspaceUpdateAvailable('not-installed'), isFalse);
    });

    test('parses runtime-reported machine facts', () {
      final workspace = AxWorkspace.fromJson({
        'id': 'workspace-1',
        'name': 'MacBook Pro',
        'slug': 'macbook-pro',
        'status': 'online',
        'hasRuntimeIdentity': false,
        'role': 'owner',
        'platform': 'macos',
        'architecture': 'arm64',
        'hostname': 'Vitalii-MacBook-Pro',
        'appVersion': '1.0.3',
        'activeTransport': 'http_long_poll',
        'connectionMode': 'Connected · HTTPS fallback',
        'runtimeCapabilitiesJson': '["dart", "shell"]',
      });

      expect(workspace.platform, 'macos');
      expect(workspace.status, 'online');
      expect(workspace.architecture, 'arm64');
      expect(workspace.hostname, 'Vitalii-MacBook-Pro');
      expect(workspace.appVersion, '1.0.3');
      expect(workspace.activeTransport, 'http_long_poll');
      expect(workspace.connectionMode, 'Connected · HTTPS fallback');
      expect(workspace.runtimeCapabilities, ['dart', 'shell']);
    });

    testWidgets('shows registered machine facts and live Workspace summary',
        (tester) async {
      final workspace = AxWorkspace.fromJson({
        'id': 'workspace-paired',
        'name': 'Vitalii’s MacBook Pro',
        'status': 'online',
        'platform': 'macos',
        'architecture': 'arm64',
        'hostname': 'vitalii-macbook.local',
        'appVersion': '1.4.2',
        'runtimeCapabilitiesJson':
            '{"os":"macos","arch":"arm64","appVersion":"1.4.2","supportedRuntimes":["dart"],"maxConcurrentWorkers":2}',
        'lastSeen': '2026-09-26T12:30:00.000Z',
        'workerCount': 3,
        'activeTaskCount': 2,
        'hasRuntimeIdentity': 1,
        'activeTransport': 'http_long_poll',
        'connectionMode': 'Connected · HTTPS fallback',
      });

      expect(workspace.runtimeCapabilities,
          ['dart', 'Up to 2 concurrent Workers']);

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: [workspace],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Vitalii’s MacBook Pro'), findsWidgets);
      expect(find.text('macOS'), findsOneWidget);
      expect(find.textContaining('Apple Silicon'), findsNothing);
      expect(find.byTooltip('Online'), findsOneWidget);
      expect(find.text('Connected · HTTPS fallback'), findsNothing);
      expect(find.text('1.4.2'), findsNothing);
      expect(find.text('dart · Up to 2 concurrent Workers'), findsNothing);
      expect(find.textContaining('3 Workers'), findsNothing);
      expect(find.text('Active work'), findsNothing);
      expect(find.text('Runtime capabilities'), findsNothing);
      expect(find.text('2026-09-26T12:30:00.000Z'), findsNothing);
    });

    testWidgets('shows Workspaces as the single execution destination',
        (tester) async {
      final snapshot = axFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(
        find.text(
            'Workspaces are connected execution environments. Workers are the AI integrations configured on each Workspace.'),
        findsNothing,
      );
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text(snapshot.workspaces.first.name), findsWidgets);
      expect(find.textContaining('AI Account'), findsNothing);
      expect(find.textContaining('Credential Profile'), findsNothing);
      expect(find.textContaining('desired state'), findsNothing);
      expect(find.textContaining('package '), findsNothing);
    });

    testWidgets('shows the Workspace list without lifecycle controls',
        (tester) async {
      final snapshot = axFixtureSnapshot();

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text(snapshot.workspaces.first.name), findsWidgets);

      expect(find.byTooltip('Connect Workspace'), findsNothing);
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Update Workspace'), findsNothing);
      expect(find.text('Unpair Workspace'), findsNothing);

      expect(find.text('Connect Account'), findsNothing);
      expect(find.text('Make available'), findsNothing);
      expect(find.text('Remove from Workspace'), findsNothing);
      expect(find.text('View capabilities'), findsNothing);
    });

    testWidgets('Workspace page has no detached global Worker inventory',
        (tester) async {
      final snapshot = axFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('Add AI Account'), findsNothing);
      expect(find.text('Workers from your Workspaces'), findsNothing);
    });

    testWidgets('shows Workspace-owned inventory without credential details',
        (tester) async {
      final worker = AxWorker.fromJson({
        'id': 'local-worker-1',
        'workspaceId': 'workspace-1',
        'workspaceName': 'Build Mac',
        'workerTypeId': 'chatgpt',
        'displayName': 'ChatGPT',
        'description': 'ChatGPT coding assistant',
        'name': 'ChatGPT Personal',
        'status': 'ready',
        'authStrategy': 'browser_auth',
        'credentialStatus': 'ready',
        'localConcurrencyLimit': 2,
        'revision': 4,
        'capabilities': ['code'],
        'allowedModels': ['gpt-5.5'],
        'defaultModel': 'gpt-5.5',
      });
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          AxWorkspace(
            id: 'workspace-1',
            name: 'Build Mac',
            hostname: 'build-mac.local',
            status: 'online',
            appVersion: '1.2.0',
            workerCount: 1,
            activeTaskCount: 0,
          ),
        ],
        workspaceWorkers: [worker],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('ChatGPT'), findsOneWidget);
      expect(find.textContaining('Cloud scheduling'), findsNothing);
      expect(find.text('Auth strategy'), findsNothing);
      expect(find.textContaining('credentialRef'), findsNothing);
      expect(find.text('Add legacy Cloud Worker'), findsNothing);
    });

    testWidgets('empty state explains Workspace registration', (tester) async {
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [],
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('No Workspaces connected'), findsOneWidget);
      expect(find.text('Connect Workspace'), findsNothing);
      expect(
          find.textContaining(
              'Download and register Syntila Workspace to make a Workspace and its Workers available here.'),
          findsOneWidget);
      expect(find.text('Download Syntila Workspace'), findsNothing);
    });

    testWidgets('shows Workspace machine and Workers without extra details',
        (tester) async {
      final snapshot = axFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Hostname'), findsNothing);
      expect(find.text('App version'), findsNothing);
      expect(find.text('Last seen'), findsNothing);
      expect(find.text('Connection status'), findsNothing);
      expect(find.text('Machine'), findsNothing);
      expect(find.text('Active work'), findsNothing);
      expect(find.text('Workers'), findsNothing);
      expect(find.text('Development Workspace'), findsWidgets);
    });

    testWidgets('each Workspace is a tab that switches the detail',
        (tester) async {
      AxWorkspace workspace(String id) => AxWorkspace(
            id: id,
            name: 'Workspace $id',
            hostname: '$id.local',
            status: 'online',
          );

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: List.generate(3, (index) => workspace('$index')),
      )));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace-tab-0')), findsOneWidget);
      expect(find.byKey(const Key('workspace-tab-2')), findsOneWidget);
      final tabBar = find.byKey(const Key('workspace-tabs'));
      final firstTab = tester.getRect(find.byKey(const Key('workspace-tab-0')));
      final lastTab = tester.getRect(find.byKey(const Key('workspace-tab-2')));
      expect((firstTab.left + lastTab.right) / 2,
          closeTo(tester.getRect(tabBar).center.dx, 1));
      expect(tester.getSize(tabBar).width,
          tester.getSize(find.byType(WorkspacesPage)).width);
      expect(find.byKey(const Key('workspace-detail-0')), findsOneWidget);
      expect(find.byKey(const Key('workspace-detail-1')), findsNothing);

      await tester.tap(find.byKey(const Key('workspace-tab-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace-detail-1')), findsOneWidget);
      expect(find.byKey(const Key('workspace-detail-0')), findsNothing);
    });

    testWidgets('Workspace deep link selects the target tab', (tester) async {
      AxWorkspace workspace(String id) => AxWorkspace(
            id: id,
            name: 'Workspace $id',
            hostname: '$id.local',
            status: 'online',
          );

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: List.generate(3, (index) => workspace('$index')),
        initialWorkspaceId: '2',
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('workspace-detail-2')), findsOneWidget);
      expect(find.byKey(const Key('workspace-detail-0')), findsNothing);
    });

    testWidgets('expanded Workspace lists its Worker projections',
        (tester) async {
      final snapshot = axFixtureSnapshot();
      final localWorker = const AxWorker(
        id: 'local-worker-1',
        workspaceId: 'workspace-macbook',
        workspaceName: 'MacBook Pro',
        workerTypeId: 'chatgpt',
        displayName: 'ChatGPT',
        description: 'ChatGPT coding assistant',
        status: 'ready',
        readinessState: 'ready',
        localConcurrencyLimit: 2,
      );
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
        workspaceWorkers: [localWorker],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('ChatGPT'), findsOneWidget);
      expect(find.text('Codex Personal'), findsNothing);
      expect(find.byTooltip('Remove binding'), findsNothing);
    });

    testWidgets('Worker rows show safe readiness and public catalog summary',
        (tester) async {
      final worker = AxWorker.fromJson({
        'id': 'worker-chatgpt',
        'workspaceId': 'workspace-1',
        'workspaceName': 'Build Mac',
        'workerTypeId': 'chatgpt',
        'displayName': 'ChatGPT',
        'description': 'ChatGPT coding assistant',
        'readinessState': 'ready',
        'localConcurrencyLimit': 2,
        'capabilities': ['code'],
        'authStrategy': 'must-not-display',
        'credentialStatus': 'must-not-display',
        'model': 'must-not-display',
      });
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          AxWorkspace(
            id: 'workspace-1',
            name: 'Build Mac',
            hostname: 'build-mac.local',
            status: 'online',
            appVersion: '1.0.0',
            workerCount: 1,
            activeTaskCount: 0,
          ),
        ],
        workspaceWorkers: [worker],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      final workerIcon = find.byWidgetPredicate((widget) =>
          widget is Image && widget.semanticLabel == 'ChatGPT icon');
      expect(tester.getSize(workerIcon), const Size(32, 32));
      expect(find.text('ChatGPT'), findsOneWidget);
      expect(find.text('Ready locally'), findsNothing);
      expect(find.textContaining('Cloud scheduling'), findsNothing);
      expect(find.text('Unavailable'), findsOneWidget);
      expect(find.textContaining('Models:'), findsNothing);
      expect(find.text('Workers'), findsNothing);
      expect(find.text('Authentication · browser_auth'), findsNothing);

      await tester.tap(find.text('ChatGPT').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Local attention'), findsNothing);
      expect(find.text('Allowed models'), findsNothing);

      expect(find.text('Disable'), findsNothing);
      expect(find.text('Drain'), findsNothing);
    });

    testWidgets('Worker rows show v8 runtime metadata', (tester) async {
      final worker = AxWorker.fromJson({
        'id': 'worker-chatgpt',
        'workspaceId': 'workspace-1',
        'workspaceName': 'Build Mac',
        'workerTypeId': 'chatgpt',
        'displayName': 'ChatGPT',
        'description': 'ChatGPT coding assistant',
        'status': 'ready',
        'readinessState': 'ready',
        'localConcurrencyLimit': 1,
        'capabilities': ['text'],
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 4,
        'providerToolName': 'Codex CLI',
        'providerToolVersion': '0.190.0',
      });

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          AxWorkspace(
            id: 'workspace-1',
            name: 'Build Mac',
            hostname: 'build-mac.local',
            status: 'online',
            appVersion: '1.0.0',
            workerCount: 1,
            activeTaskCount: 0,
          ),
        ],
        workspaceWorkers: [worker],
      )));
      await tester.pumpAndSettle();
      expect(find.text('Codex CLI 0.190.0'), findsOneWidget);
      expect(find.text('Profile v4'), findsNothing);
      expect(find.text('Unavailable'), findsOneWidget);
      expect(find.textContaining('Models:'), findsNothing);
    });

    testWidgets('Workers are grouped only under their owning Workspace ID',
        (tester) async {
      AxWorkspace workspace(String id) => AxWorkspace(
            id: id,
            name: 'Workspace $id',
            hostname: '$id.local',
            status: 'online',
            appVersion: '1.0.0',
            workerCount: 1,
            activeTaskCount: 0,
          );
      AxWorker worker(String id, String workspaceId, String workerTypeId,
              String displayName) =>
          AxWorker(
            id: id,
            workspaceId: workspaceId,
            workspaceName: 'Workspace $workspaceId',
            workerTypeId: workerTypeId,
            displayName: displayName,
            description: '$displayName coding assistant',
            status: 'ready',
            readinessState: 'ready',
            localConcurrencyLimit: 1,
          );

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: [workspace('one'), workspace('two')],
        workspaceWorkers: [
          worker('one', 'one', 'chatgpt', 'ChatGPT'),
          worker('two', 'two', 'gemini', 'Gemini'),
        ],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('ChatGPT'), findsOneWidget);
      expect(find.text('Gemini'), findsNothing);
      await tester.tap(find.byKey(const Key('workspace-tab-two')));
      await tester.pumpAndSettle();
      expect(find.text('Gemini'), findsOneWidget);
      expect(find.text('ChatGPT'), findsNothing);
    });

    testWidgets('needs-attention stays concise and avoids internal details',
        (tester) async {
      final worker = AxWorker.fromJson({
        'id': 'worker-needs-auth',
        'workspaceId': 'workspace-auth',
        'workspaceName': 'Auth Mac',
        'workerTypeId': 'chatgpt',
        'displayName': 'ChatGPT',
        'description': 'ChatGPT coding assistant',
        'name': 'ChatGPT Personal',
        'readinessState': 'sign_in_required',
        'attentionReasonCode': 'authentication_required',
        'authStrategy': 'browser_auth',
        'credentialStatus': 'needs_authentication',
        'localConcurrencyLimit': 1,
        'revision': 1,
        'capabilities': ['code'],
        'allowedModels': [],
      });
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          AxWorkspace(
            id: 'workspace-auth',
            name: 'Auth Mac',
            status: 'online',
          ),
        ],
        workspaceWorkers: [worker],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Provider sign-in required'), findsNothing);
      expect(find.byIcon(Icons.warning_amber), findsOneWidget);
      expect(find.textContaining('authentication_required'), findsNothing);
      expect(find.textContaining('Syntila Workspace'), findsNothing);
    });

    testWidgets('disconnected Workspace stays read-only', (tester) async {
      AxWorkspace? connectedWorkspace;
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          AxWorkspace(
            id: 'workspace-offline',
            name: 'Offline Mac',
            status: 'offline',
            appVersion: '1.4.0',
          ),
        ],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onConnect: (workspace) async => connectedWorkspace = workspace,
      )));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Not connected'), findsOneWidget);
      expect(find.text('Connect Machine'), findsNothing);
      expect(connectedWorkspace, isNull);
    });

    testWidgets('zero Workers explains local desktop configuration',
        (tester) async {
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          AxWorkspace(id: 'workspace-empty', name: 'New Mac'),
        ],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'No Workers are available for this Workspace yet. Configure Workers in Syntila Workspace on this computer.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Workspace inventory does not expose scheduling controls',
        (tester) async {
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          AxWorkspace(
            id: 'workspace-enable',
            name: 'Enable Workspace',
            hostname: 'enable.local',
            status: 'online',
            appVersion: '1.0.0',
            workerCount: 1,
            activeTaskCount: 0,
          ),
        ],
        workspaceWorkers: const [
          AxWorker(
            id: 'worker-disabled',
            workspaceId: 'workspace-enable',
            workspaceName: 'Enable Mac',
            workerTypeId: 'ollama',
            displayName: 'Ollama',
            status: 'ready',
            readinessState: 'ready',
            localConcurrencyLimit: 1,
          ),
        ],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Enable'), findsNothing);
      expect(find.textContaining('Cloud scheduling'), findsNothing);
    });

    testWidgets('renders without layout exceptions in a scroll view',
        (tester) async {
      final snapshot = axFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'manages Space AI chat and work availability per workspace with license agreement',
        (tester) async {
      final ws1 = AxWorkspace.fromJson({
        'id': 'ws1',
        'name': 'Primary Workspace',
        'role': 'owner',
      });
      final ws2 = AxWorkspace.fromJson({
        'id': 'ws2',
        'name': 'Secondary Workspace',
        'role': 'owner',
      });
      String? updatedWsId;
      bool? updatedChat;
      bool? updatedWork;

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: [ws1, ws2],
        onSpaceAiSharingChanged: (id, {allowChat, allowWork}) {
          updatedWsId = id;
          if (allowChat != null) updatedChat = allowChat;
          if (allowWork != null) updatedWork = allowWork;
        },
      )));
      await tester.pumpAndSettle();

      final chatBox1 =
          find.byKey(const ValueKey('workspace-space-ai-chat-ws1'));
      final workBox1 =
          find.byKey(const ValueKey('workspace-space-ai-work-ws1'));
      expect(chatBox1, findsOneWidget);
      expect(workBox1, findsOneWidget);
      expect(tester.widget<CheckboxListTile>(chatBox1).value, isFalse);
      expect(tester.widget<CheckboxListTile>(workBox1).value, isFalse);

      // Check chat option -> shows agreement dialog
      await tester.tap(chatBox1);
      await tester.pumpAndSettle();
      expect(
          find.text('Worker License & Subscription Agreement'), findsOneWidget);
      expect(find.textContaining('worker model licenses and subscriptions'),
          findsOneWidget);

      // Cancel agreement
      await tester.tap(find.byKey(const ValueKey('agreement-cancel-button')));
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(chatBox1).value, isFalse);
      expect(updatedChat, isNull);

      // Tap again and agree
      await tester.tap(chatBox1);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agreement-confirm-button')));
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(chatBox1).value, isTrue);
      expect(updatedWsId, 'ws1');
      expect(updatedChat, isTrue);

      // Check work option -> shows agreement dialog
      await tester.tap(workBox1);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agreement-confirm-button')));
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(workBox1).value, isTrue);
      expect(updatedWork, isTrue);

      // Uncheck chat option -> directly unchecks without dialog
      await tester.tap(chatBox1);
      await tester.pumpAndSettle();
      expect(
          find.text('Worker License & Subscription Agreement'), findsNothing);
      expect(tester.widget<CheckboxListTile>(chatBox1).value, isFalse);
      expect(updatedChat, isFalse);

      // Switch to ws2 tab: should have its own unchecked options
      await tester.tap(find.byKey(const Key('workspace-tab-ws2')));
      await tester.pumpAndSettle();
      final chatBox2 =
          find.byKey(const ValueKey('workspace-space-ai-chat-ws2'));
      final workBox2 =
          find.byKey(const ValueKey('workspace-space-ai-work-ws2'));
      expect(tester.widget<CheckboxListTile>(chatBox2).value, isFalse);
      expect(tester.widget<CheckboxListTile>(workBox2).value, isFalse);
    });

    testWidgets(
        'does not display workspace allowance count, places available workers below Space AI options, and aligns parallel requests to the right',
        (tester) async {
      final ws = AxWorkspace.fromJson({
        'id': 'ws1',
        'name': 'Primary Workspace',
        'role': 'owner',
        'parallelSlots': 4,
      });
      final worker = AxWorker.fromJson({
        'id': 'worker-1',
        'displayName': 'Claude Code',
        'workspaceId': 'ws1',
        'workspaceName': 'Primary Workspace',
        'workerTypeId': 'claude-code',
        'status': 'ready',
      });

      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: [ws],
        workspaceWorkers: [worker],
        accountPlanSource: _AccountPlanSource(),
        onSetParallelSlots: (_, __) async {},
      )));
      await tester.pumpAndSettle();

      // 1. No first line about number of workspaces / workspace allowance
      expect(find.byKey(const ValueKey('workspace-allowance')), findsNothing);
      expect(find.textContaining('personal Workspace'), findsNothing);

      // 2. Parallel requests control is right-aligned
      final labelFinder = find.text('Parallel requests');
      final selectFinder = find.byKey(const ValueKey('parallel-slots-select'));
      expect(labelFinder, findsOneWidget);
      expect(selectFinder, findsOneWidget);
      final labelTopLeft = tester.getTopLeft(labelFinder);
      final selectTopRight = tester.getTopRight(selectFinder);
      expect(labelTopLeft.dx, 0.0);
      expect(selectTopRight.dx, greaterThan(700.0));

      // 3. Available workers are rendered below "Use Space AI for work"
      final workAiOptionFinder =
          find.byKey(const ValueKey('workspace-space-ai-work-ws1'));
      final workerCardFinder =
          find.byKey(const Key('workspace-worker-row-worker-1'));
      expect(workAiOptionFinder, findsOneWidget);
      expect(workerCardFinder, findsOneWidget);
      final workAiBottom = tester.getBottomLeft(workAiOptionFinder);
      final workerCardTop = tester.getTopLeft(workerCardFinder);
      expect(workerCardTop.dy, greaterThan(workAiBottom.dy));
    });
  });
}

class _AccountPlanSource implements AxAccountPlanDataSource {
  @override
  Future<AxAccountPlan> loadAccountPlan() async => const AxAccountPlan(
        isPaid: false,
        ownedWorkspaces: 1,
        workspaceLimit: 1,
      );
}
