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
                boundWorkerTypes: s.boundWorkerTypes,
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
              boundWorkerTypes: s.boundWorkerTypes,
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
    } else if (action == 'bind' || action == 'unbind') {
      final bind = action == 'bind';
      if (current != null) {
        final updatedServers = current.servers.map((s) {
          if (s.serverId == serverId) {
            final bindings = Set<String>.from(s.boundWorkerTypes);
            if (bind && workerTypeId != null) {
              bindings.add(workerTypeId);
            } else if (!bind && workerTypeId != null) {
              bindings.remove(workerTypeId);
            }
            return AxMcpServer(
              serverId: s.serverId,
              displayName: s.displayName,
              transport: s.transport,
              consented: s.consented,
              enabled: s.enabled,
              availability: s.availability,
              diagnostic: s.diagnostic,
              tools: s.tools,
              boundWorkerTypes: bindings.toList()..sort(),
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
          'workerTypeId': workerTypeId,
          'bound': bind,
        },
      };
    } else if (action == 'addRemote') {
      if (current != null) {
        final newServer = AxMcpServer(
          serverId: serverId,
          displayName: displayName ?? serverId,
          transport: 'remote',
          consented: false,
          enabled: false,
          availability: 'unknown',
          diagnostic: null,
          tools: const [],
          boundWorkerTypes: const [],
        );
        inventories[workspaceId] = AxMcpInventory(
          revision: current.revision + 1,
          servers: [...current.servers, newServer],
          online: current.online,
          ageSeconds: 1,
        );
      }
      return {
        'ok': true,
        'result': {
          'serverId': serverId,
          'transport': 'remote',
        },
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
          boundWorkerTypes: ['chatgpt', 'claude'],
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
          boundWorkerTypes: [],
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
          boundWorkerTypes: [],
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
    expect(find.textContaining('chatgpt'), findsOneWidget);
    expect(find.textContaining('claude'), findsOneWidget);

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
          boundWorkerTypes: [],
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
          boundWorkerTypes: [],
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
          boundWorkerTypes: [],
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

  testWidgets('adds remote server through dialog and validates endpoint',
      (tester) async {
    dataSource.inventories['ws-1'] = const AxMcpInventory(
      revision: 1,
      online: true,
      ageSeconds: 3,
      servers: [],
    );

    await tester.pumpWidget(buildSettings(tester));
    await tester.pumpAndSettle();

    final addBtn = find.byKey(const ValueKey('setting-mcp-add-remote'));
    expect(addBtn, findsOneWidget);

    await tester.tap(addBtn);
    await tester.pumpAndSettle();

    expect(find.byType(McpAddRemoteServerDialog), findsOneWidget);

    // Attempt invalid submit:
    final submitBtn = find.byKey(const ValueKey('mcp-add-submit'));
    await tester.tap(submitBtn);
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsWidgets);

    // Enter details:
    await tester.enterText(
        find.byKey(const ValueKey('mcp-add-id')), 'my-remote');
    await tester.enterText(
        find.byKey(const ValueKey('mcp-add-name')), 'My Remote Server');
    await tester.enterText(find.byKey(const ValueKey('mcp-add-endpoint')),
        'https://mcp.example.com/sse');
    await tester.enterText(
        find.byKey(const ValueKey('mcp-add-token-env')), 'EXAMPLE_API_TOKEN');

    await tester.tap(submitBtn);
    await tester.pumpAndSettle();

    expect(dataSource.actionLog, hasLength(1));
    final addAction = dataSource.actionLog.first;
    expect(addAction['action'], 'addRemote');
    expect(addAction['serverId'], 'my-remote');
    expect(addAction['displayName'], 'My Remote Server');
    expect(addAction['endpoint'], 'https://mcp.example.com/sse');
    expect(addAction['tokenEnv'], 'EXAMPLE_API_TOKEN');

    expect(
        find.text('Remote server added. Consent is required before enabling.'),
        findsOneWidget);
  });

  testWidgets('binds and unbinds worker types', (tester) async {
    dataSource.inventories['ws-1'] = const AxMcpInventory(
      revision: 1,
      online: true,
      ageSeconds: 3,
      servers: [
        AxMcpServer(
          serverId: 'github',
          displayName: 'GitHub Tools',
          transport: 'local',
          consented: true,
          enabled: true,
          availability: 'available',
          diagnostic: null,
          tools: [],
          boundWorkerTypes: ['chatgpt'],
        ),
      ],
    );

    await tester.pumpWidget(buildSettings(tester));
    await tester.pumpAndSettle();

    final bindingsBtn = find.byKey(const ValueKey('setting-mcp-bind-github'));
    expect(bindingsBtn, findsOneWidget);

    await tester.tap(bindingsBtn);
    await tester.pumpAndSettle();

    expect(find.byType(McpBindingsDialog), findsOneWidget);
    expect(find.text('Worker Bindings for GitHub Tools'), findsOneWidget);

    // Bind 'claude'
    final claudeCheckbox = find.byKey(const ValueKey('mcp-binding-claude'));
    expect(claudeCheckbox, findsOneWidget);
    await tester.tap(claudeCheckbox);
    await tester.pumpAndSettle();

    expect(
        dataSource.actionLog
            .any((a) => a['action'] == 'bind' && a['workerTypeId'] == 'claude'),
        isTrue);

    // Unbind 'chatgpt'
    final chatgptCheckbox = find.byKey(const ValueKey('mcp-binding-chatgpt'));
    expect(chatgptCheckbox, findsOneWidget);
    await tester.tap(chatgptCheckbox);
    await tester.pumpAndSettle();

    expect(
        dataSource.actionLog.any(
            (a) => a['action'] == 'unbind' && a['workerTypeId'] == 'chatgpt'),
        isTrue);

    // Close
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
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
          boundWorkerTypes: [],
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
          boundWorkerTypes: [],
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
          boundWorkerTypes: [],
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
