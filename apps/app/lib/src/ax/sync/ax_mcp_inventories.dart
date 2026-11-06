import '../ax_data.dart';
import '../ax_mcp_inventory.dart';
import 'ax_sync_engine.dart';

/// Session-owned MCP inventory per Workspace. Navigation reuses the scoped
/// query; a changed Workspace gets its own key, so switching never shows
/// another Workspace's servers. A failed refresh keeps the last data, which the
/// UI shows as stale rather than dropping selections.
class AxMcpInventories {
  AxMcpInventories(this.source, {required this.engine});
  final AxDataSource source;
  final AxSyncEngine engine;
  final _queries = <String, AxQuery<AxMcpInventory?>>{};

  bool get isSupported => source is AxMcpInventoryDataSource;

  AxQuery<AxMcpInventory?> query(String workspaceId) => _queries.putIfAbsent(
        workspaceId,
        () => AxQuery<AxMcpInventory?>(
          key: AxQueryKey(['mcp-inventory', workspaceId]),
          staleTime: const Duration(minutes: 2),
          load: () => (source as AxMcpInventoryDataSource)
              .loadMcpInventory(workspaceId),
        ),
      );

  Future<AxMcpInventory?> ensure(String workspaceId) =>
      engine.ensure(query(workspaceId), policy: AxCachePolicy.cacheFirst);

  Future<AxMcpInventory?> refresh(String workspaceId) =>
      engine.refresh(query(workspaceId));
}
