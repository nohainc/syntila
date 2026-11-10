import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_mcp_inventory.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/sync/ax_mcp_inventories.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/features/settings/mcp_management_view.dart';
import 'package:syntila_app/src/features/settings/settings_page.dart';
import 'package:syntila_app/src/platform/view_preferences.dart';

class MockMcpDataSource implements AxDataSource, AxMcpInventoryDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  final Map<String, AxMcpInventory> inventories = {};
  final List<Map<String, dynamic>> actionLog = [];
  bool failNextAction = false;
  String? failActionMessage;

  @override
  Future<AxMcpInventory?> loadMcpInventory(String workspaceId) async {
    return inventories[workspaceId];
  }

  @override
  Future<Map<String, dynamic>> executeMcpAction(
    String workspaceId, {
    required String action,
    required String serverId,
    String? displayName,
    String? endpoint,
    String? tokenEnv,
    bool? insecureLoopback,
    String? workerTypeId,
    String? acceptHash,
  }) async {
    actionLog.add({
      'workspaceId': workspaceId,
      'action': action,
      'serverId': serverId,
      'displayName': displayName,
      'endpoint': endpoint,
      'tokenEnv': tokenEnv,
      'insecureLoopback': insecureLoopback,
      'workerTypeId': workerTypeId,
      'acceptHash': acceptHash,
    });

    if (failNextAction) {
      failNextAction = false;
      throw StateError(failActionMessage ?? 'Action failed');
    }

    final current = inventories[workspaceId];
    if (action == 'test') {
      return {
        'ok': true,
        'result': {
          'serverId': serverId,
          'reachable': true,
          'toolsCount': 2,
          'tools': [
            {
              'name': 'tool_alpha',
              'description': 'Does alpha operations',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'msg': {'type': 'string'}
                }
              },
            },
            {
              'name': 'tool_beta',
              'description': 'Beta tool',
              'inputSchema': {},
            },
          ],
        },
      };
    } else if (action == 'consent') {
      if (acceptHash == null) {
        return {
          'ok': true,
          'result': {
            'consentRequired': true,
            'documentHash': 'hash_probed_999',
            'document': {
              'serverId': serverId,
              'tools': [
                {
                  'name': 'tool_alpha',
                  'description': 'Does alpha operations updated',
                  'inputSchema': {'type': 'object'},
                },
                {
                  'name': 'tool_new',
                  'description': 'Brand new tool',
                  'inputSchema': {},
                },
              ],
            },
          },
        };
      } else {
        // Pinned consent accept
        if (current != null) {
          final updatedServers = current.servers.map((s) {
            if (s.serverId == serverId) {
              return AxMcpServer(
                serverId: s.serverId,
                displayName: s.displayName,
                transport: s.transport,
                consented: true,
                enabled: s.enabled,
                availability: s.availability,
                diagnostic: s.diagnostic,
                tools: [
                  const AxMcpTool(
                      name: 'tool_alpha', definitionHash: 'h_alpha_new'),
                  const AxMcpTool(name: 'tool_new', definitionHash: 'h_new'),
                ],
              );
            }
            return s;
          }).toList();
          inventories[workspaceId] = AxMcpInventory(
            revision: current.revision + 1,
            servers: updatedServers,
            online: current.online,
            ageSeconds: 1,
          );
        }
        return {
          'ok': true,
          'result': {
            'serverId': serverId,
            'consented': true,
            'documentHash': acceptHash,
          },
        };
      }
    } else if (action == 'enable' || action == 'disable') {
      final enable = action == 'enable';
      if (current != null) {
        final updatedServers = current.servers.map((s) {
          if (s.serverId == serverId) {
            return AxMcpServer(
              serverId: s.serverId,
              displayName: s.displayName,
              transport: s.transport,
              consented: s.consented,
              enabled: enable,
              availability: s.availability,
              diagnostic: s.diagnostic,
              tools: s.tools,
            );
          }
          return s;
        }).toList();
        inventories[workspaceId] = AxMcpInventory(
          revision: current.revision + 1,
          servers: updatedServers,
          online: current.online,
          ageSeconds: 1,
        );
      }
      return {
        'ok': true,
        'result': {'serverId': serverId, 'enabled': enable}
      };
    } else if (action == 'remove') {
      if (current != null) {
        final updatedServers =
            current.servers.where((s) => s.serverId != serverId).toList();
        inventories[workspaceId] = AxMcpInventory(
          revision: current.revision + 1,
          servers: updatedServers,
          online: current.online,
          ageSeconds: 1,
        );
      }
      return {
        'ok': true,
        'result': {'serverId': serverId, 'removed': true}
      };
    }

    return {'ok': true, 'result': {}};
  }
}

void main() {
  late MockMcpDataSource dataSource;
  late AxSyncEngine syncEngine;
  late AxMcpInventories inventories;

  setUp(() {
    dataSource = MockMcpDataSource();
    syncEngine = AxSyncEngine();
    inventories = AxMcpInventories(dataSource, engine: syncEngine);
  });

  Widget buildSettings(
    WidgetTester tester, {
    String? workspaceId = 'ws-1',
    List<AxWorkspace> workspaces = const [
      AxWorkspace(id: 'ws-1', name: 'Main Mac', status: 'ready'),
      AxWorkspace(id: 'ws-2', name: 'Cloud Linux', status: 'ready'),
    ],
  }) {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SettingsPage(
            preferences: const ViewPreferences(),
            onChanged: (_) {},
            workspaceId: workspaceId,
            workspaces: workspaces,
            workers: const [
              AxWorker(
                  id: 'w1',
                  workspaceId: 'ws-1',
                  workspaceName: 'Main Mac',
                  workerTypeId: 'claude',
                  displayName: 'Claude',
                  status: 'ready',
                  readinessState: 'ready',
                  localConcurrencyLimit: 1),
              AxWorker(
                  id: 'w2',
                  workspaceId: 'ws-2',
                  workspaceName: 'Cloud Linux',
                  workerTypeId: 'other-worker',
                  displayName: 'Other',
                  status: 'ready',
                  readinessState: 'ready',
                  localConcurrencyLimit: 1),
            ],
            inventories: inventories,
          ),
        ),
      ),
    );
  }

  testWidgets('renders installed MCP servers and their status chips',
      (tester) async {
    dataSource.inventories['ws-1'] = const AxMcpInventory(
      revision: 1,
      online: true,
      ageSeconds: 3,
      servers: [
        AxMcpServer(
          serverId: 'github',
          displayName: 'GitHub Tools',
          transport: 'remote',
          consented: true,
          enabled: true,
          availability: 'available',
          diagnostic: null,
          tools: [
            AxMcpTool(name: 'get_issue', definitionHash: 'h_issue_123456789'),
            AxMcpTool(name: 'list_prs', definitionHash: 'h_prs_abcdef123456'),
          ],
        ),
        AxMcpServer(
          serverId: 'sqlite',
          displayName: 'Local SQLite',
          transport: 'local',
          consented: true,
          enabled: true,
          availability: 'unavailable',
          diagnostic: 'binary_not_found',
          tools: [],
        ),
        AxMcpServer(
          serverId: 'postgres',
          displayName: 'Postgres DB',
          transport: 'local',
          consented: false,
          enabled: false,
          availability: 'unknown',
          diagnostic: null,
          tools: [],
        ),
      ],
    );

    await tester.pumpWidget(buildSettings(tester));
    await tester.pumpAndSettle();

    expect(find.text('MCP SERVERS'), findsOneWidget);
    expect(find.text('GitHub Tools'), findsOneWidget);
    expect(find.text('github'), findsOneWidget);
    expect(find.text('Remote'), findsOneWidget);
    expect(find.text('Available'), findsOneWidget);
    expect(find.text('Consented'), findsNWidgets(2));
    expect(find.text('Tools (2): get_issue, list_prs'), findsOneWidget);
    // Servers are added only in the Workspace app and are not bound per Worker.
    expect(find.text('Add Remote Server'), findsNothing);
    expect(find.textContaining('Worker bindings'), findsNothing);

    expect(find.text('Local SQLite'), findsOneWidget);
    expect(find.text('sqlite'), findsOneWidget);
    expect(find.text('Local'), findsWidgets);
    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.text('Not reachable'), findsOneWidget);

    expect(find.text('Postgres DB'), findsOneWidget);
    expect(find.text('Not Consented'), findsOneWidget);
    expect(find.text('Not consented on the Workspace'), findsOneWidget);
  });

  testWidgets('toggles server enabled state via service action',
      (tester) async {
    dataSource.inventories['ws-1'] = const AxMcpInventory(
      revision: 1,
      online: true,
      ageSeconds: 3,
      servers: [
        AxMcpServer(
          serverId: 'github',
          displayName: 'GitHub Tools',
          transport: 'remote',
          consented: true,
          enabled: true,
          availability: 'available',
          diagnostic: null,
          tools: [],
        ),
      ],
    );

    await tester.pumpWidget(buildSettings(tester));
    await tester.pumpAndSettle();

    final toggleFinder =
        find.byKey(const ValueKey('setting-mcp-toggle-github'));
    expect(toggleFinder, findsOneWidget);

    // Toggle off (disable)
    await tester.tap(toggleFinder);
    await tester.pumpAndSettle();

    expect(dataSource.actionLog, hasLength(1));
    expect(dataSource.actionLog.first['action'], 'disable');
    expect(dataSource.actionLog.first['serverId'], 'github');
    expect(find.text('Server "GitHub Tools" disabled.'), findsOneWidget);

    // Toggle on (enable)
    await tester.tap(toggleFinder);
    await tester.pumpAndSettle();

    expect(dataSource.actionLog, hasLength(2));
    expect(dataSource.actionLog.last['action'], 'enable');
    expect(dataSource.actionLog.last['serverId'], 'github');
    expect(find.text('Server "GitHub Tools" enabled.'), findsOneWidget);
  });

  testWidgets('tests server connectivity and displays tool reachability',
      (tester) async {
    dataSource.inventories['ws-1'] = const AxMcpInventory(
      revision: 1,
      online: true,
      ageSeconds: 3,
      servers: [
        AxMcpServer(
          serverId: 'github',
          displayName: 'GitHub Tools',
          transport: 'remote',
          consented: true,
          enabled: true,
          availability: 'available',
          diagnostic: null,
          tools: [],
        ),
      ],
    );

    await tester.pumpWidget(buildSettings(tester));
    await tester.pumpAndSettle();

    final testBtnFinder = find.byKey(const ValueKey('setting-mcp-test-github'));
    expect(testBtnFinder, findsOneWidget);

    await tester.tap(testBtnFinder);
    await tester.pumpAndSettle();

    expect(dataSource.actionLog, hasLength(1));
    expect(dataSource.actionLog.first['action'], 'test');
    expect(dataSource.actionLog.first['serverId'], 'github');
    expect(find.text('Server "GitHub Tools" is reachable (2 tools available).'),
        findsOneWidget);
  });

  testWidgets('opens consent dialog, reviews tool diff, and accepts consent',
      (tester) async {
    dataSource.inventories['ws-1'] = const AxMcpInventory(
      revision: 1,
      online: true,
      ageSeconds: 3,
      servers: [
        AxMcpServer(
          serverId: 'github',
          displayName: 'GitHub Tools',
          transport: 'remote',
          consented: false,
          enabled: false,
          availability: 'available',
          diagnostic: null,
          tools: [
            AxMcpTool(name: 'tool_alpha', definitionHash: 'old_alpha_hash'),
            AxMcpTool(
                name: 'tool_obsolete', definitionHash: 'old_obsolete_hash'),
          ],
        ),
      ],
    );

    await tester.pumpWidget(buildSettings(tester));
    await tester.pumpAndSettle();

    final consentBtn = find.byKey(const ValueKey('setting-mcp-consent-github'));
    expect(consentBtn, findsOneWidget);

    await tester.tap(consentBtn);
    await tester.pumpAndSettle();

    // In consent dialog:
    expect(find.byType(McpConsentDialog), findsOneWidget);
    expect(find.text('Consent to GitHub Tools'), findsOneWidget);
    expect(find.textContaining('This is a remote server.'), findsOneWidget);
    expect(find.text('DEFINITION CHANGES'), findsOneWidget);

    // Diff summary chips:
    expect(find.textContaining('Added tools'), findsOneWidget);
    expect(find.textContaining('Modified tools'), findsOneWidget);
    expect(find.textContaining('Removed tools'), findsOneWidget);

    // Complete tool definitions:
    expect(find.text('tool_alpha'), findsWidgets);
    expect(find.text('Does alpha operations updated'), findsOneWidget);
    expect(find.text('tool_new'), findsWidgets);
    expect(find.text('Brand new tool'), findsOneWidget);

    // Document hash display:
    expect(find.textContaining('hash_probed_999'), findsOneWidget);

    // Consent button:
    final acceptBtn = find.byKey(const ValueKey('mcp-consent-confirm'));
    expect(acceptBtn, findsOneWidget);

    await tester.tap(acceptBtn);
    await tester.pumpAndSettle();

    // Confirm consent action with acceptHash was delivered:
    final consentAction =
        dataSource.actionLog.firstWhere((a) => a['acceptHash'] != null);
    expect(consentAction['action'], 'consent');
    expect(consentAction['serverId'], 'github');
    expect(consentAction['acceptHash'], 'hash_probed_999');

    expect(find.text('Consent recorded for "GitHub Tools".'), findsOneWidget);
  });

  testWidgets('removes server with confirmation dialog', (tester) async {
    dataSource.inventories['ws-1'] = const AxMcpInventory(
      revision: 1,
      online: true,
      ageSeconds: 3,
      servers: [
        AxMcpServer(
          serverId: 'github',
          displayName: 'GitHub Tools',
          transport: 'remote',
          consented: true,
          enabled: true,
          availability: 'available',
          diagnostic: null,
          tools: [],
        ),
      ],
    );

    await tester.pumpWidget(buildSettings(tester));
    await tester.pumpAndSettle();

    final removeBtn = find.byKey(const ValueKey('setting-mcp-remove-github'));
    expect(removeBtn, findsOneWidget);

    await tester.tap(removeBtn);
    await tester.pumpAndSettle();

    expect(find.text('Remove MCP server'), findsOneWidget);
    expect(find.text('Are you sure you want to remove "GitHub Tools"?'),
        findsOneWidget);

    final confirmBtn = find.byKey(const ValueKey('mcp-remove-confirm'));
    await tester.tap(confirmBtn);
    await tester.pumpAndSettle();

    expect(dataSource.actionLog, hasLength(1));
    expect(dataSource.actionLog.first['action'], 'remove');
    expect(dataSource.actionLog.first['serverId'], 'github');
    expect(find.text('Server "GitHub Tools" removed.'), findsOneWidget);
  });

  testWidgets('switches workspace and loads workspace inventory',
      (tester) async {
    dataSource.inventories['ws-1'] = const AxMcpInventory(
      revision: 1,
      online: true,
      ageSeconds: 3,
      servers: [
        AxMcpServer(
          serverId: 'server-1',
          displayName: 'Server On Mac',
          transport: 'local',
          consented: true,
          enabled: true,
          availability: 'available',
          diagnostic: null,
          tools: [],
        ),
      ],
    );
    dataSource.inventories['ws-2'] = const AxMcpInventory(
      revision: 1,
      online: true,
      ageSeconds: 3,
      servers: [
        AxMcpServer(
          serverId: 'server-2',
          displayName: 'Server On Cloud Linux',
          transport: 'remote',
          consented: true,
          enabled: true,
          availability: 'available',
          diagnostic: null,
          tools: [],
        ),
      ],
    );

    await tester.pumpWidget(buildSettings(tester));
    await tester.pumpAndSettle();

    expect(find.text('Server On Mac'), findsOneWidget);
    expect(find.text('Server On Cloud Linux'), findsNothing);

    // Switch workspace to ws-2
    final selector =
        find.byKey(const ValueKey('setting-mcp-workspace-selector'));
    expect(selector, findsOneWidget);
    await tester.tap(selector);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cloud Linux (ready)').last);
    await tester.pumpAndSettle();

    expect(find.text('Server On Mac'), findsNothing);
    expect(find.text('Server On Cloud Linux'), findsOneWidget);
  });
}
