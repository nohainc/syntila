import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart'
    show toolDefinitionHash;

import '../../brand.dart';
import '../../ax/ax_mcp_inventory.dart';
import '../../ax/sync/ax_mcp_inventories.dart';
import '../../ax/sync/ax_query_builder.dart';

/// Service-owned MCP servers management UI.
///
/// Displays installed servers, availability, consent status, tools and Worker
/// bindings. Lets users install remote servers, test connection, enable, disable,
/// remove, bind/unbind, and review complete tool definitions during consent with
/// a clear definition diff.
class McpManagementView extends StatefulWidget {
  const McpManagementView({
    super.key,
    required this.workspaceId,
    required this.inventories,
    this.knownWorkerTypes = const [],
  });

  final String workspaceId;
  final AxMcpInventories inventories;
  final List<String> knownWorkerTypes;

  @override
  State<McpManagementView> createState() => _McpManagementViewState();
}

class _McpManagementViewState extends State<McpManagementView> {
  final _search = TextEditingController();
  String? _statusMessage;
  bool _isError = false;
  bool _testing = false;
  String? _testingServerId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _setStatus(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = message;
      _isError = error;
    });
  }

  Future<void> _testServer(AxMcpServer server) async {
    setState(() {
      _testing = true;
      _testingServerId = server.serverId;
      _statusMessage = null;
    });
    try {
      final response = await widget.inventories.execute(
        widget.workspaceId,
        action: 'test',
        serverId: server.serverId,
      );
      final outcome = response['result'] as Map?;
      final count = outcome?['toolsCount'] ?? 0;
      _setStatus(
          'Server "${server.displayName}" is reachable ($count tools available).');
    } catch (e) {
      _setStatus('Test failed for "${server.displayName}": $e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
          _testingServerId = null;
        });
      }
    }
  }

  Future<void> _toggleEnabled(AxMcpServer server, bool enable) async {
    try {
      await widget.inventories.execute(
        widget.workspaceId,
        action: enable ? 'enable' : 'disable',
        serverId: server.serverId,
      );
      _setStatus(
          'Server "${server.displayName}" ${enable ? 'enabled' : 'disabled'}.');
    } catch (e) {
      _setStatus('Failed to update "${server.displayName}": $e', error: true);
    }
  }

  Future<void> _removeServer(AxMcpServer server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove MCP server'),
        content:
            Text('Are you sure you want to remove "${server.displayName}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('mcp-remove-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: SyntilaColors.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.inventories.execute(
        widget.workspaceId,
        action: 'remove',
        serverId: server.serverId,
      );
      _setStatus('Server "${server.displayName}" removed.');
    } catch (e) {
      _setStatus('Failed to remove server: $e', error: true);
    }
  }

  Future<void> _openConsentDialog(AxMcpServer server) async {
    final consented = await showDialog<bool>(
      context: context,
      builder: (ctx) => McpConsentDialog(
        workspaceId: widget.workspaceId,
        server: server,
        inventories: widget.inventories,
      ),
    );
    if (consented == true) {
      _setStatus('Consent recorded for "${server.displayName}".');
    }
  }

  Future<void> _openAddRemoteDialog() async {
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => McpAddRemoteServerDialog(
        workspaceId: widget.workspaceId,
        inventories: widget.inventories,
      ),
    );
    if (added == true) {
      _setStatus('Remote server added. Consent is required before enabling.');
    }
  }

  Future<void> _openBindingsDialog(AxMcpServer server) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => McpBindingsDialog(
        workspaceId: widget.workspaceId,
        server: server,
        inventories: widget.inventories,
        knownWorkerTypes: widget.knownWorkerTypes,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = SyntilaColors.navigationTextMuted(isDark);

    return AxQueryBuilder<AxMcpInventory?>(
      engine: widget.inventories.engine,
      query: widget.inventories.query(widget.workspaceId),
      builder: (context, state) {
        final inventory = state.data;
        final isStale = inventory?.isStale == true;

        final queryText = _search.text.trim().toLowerCase();
        final servers =
            (inventory?.servers ?? const <AxMcpServer>[]).where((s) {
          if (queryText.isEmpty) return true;
          return s.displayName.toLowerCase().contains(queryText) ||
              s.serverId.toLowerCase().contains(queryText) ||
              s.tools.any((t) => t.name.toLowerCase().contains(queryText));
        }).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'MCP SERVERS',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.7,
                    color: SyntilaColors.neutralText(isDark),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Manage Model Context Protocol servers connected to this Workspace.',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('setting-mcp-refresh'),
                      onPressed: () =>
                          widget.inventories.refresh(widget.workspaceId),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Refresh'),
                    ),
                    FilledButton.icon(
                      key: const ValueKey('setting-mcp-add-remote'),
                      onPressed: _openAddRemoteDialog,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add Remote Server'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (isStale)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border:
                      Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 18, color: Colors.amber),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Workspace is currently disconnected. Showing last reported inventory.',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: SyntilaColors.textPrimary(isDark)),
                      ),
                    ),
                  ],
                ),
              ),
            if (_statusMessage != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: (_isError ? SyntilaColors.error : Colors.green)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: (_isError ? SyntilaColors.error : Colors.green)
                        .withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _isError
                          ? Icons.error_outline
                          : Icons.check_circle_outline,
                      size: 18,
                      color: _isError ? SyntilaColors.error : Colors.green,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusMessage!,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: SyntilaColors.textPrimary(isDark)),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => setState(() => _statusMessage = null),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
            if ((inventory?.servers.length ?? 0) > 3)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: 'Filter MCP servers by name or tool...',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            if (servers.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: SyntilaColors.border(isDark)),
                ),
                child: Column(
                  children: [
                    Icon(Icons.hub_outlined, size: 36, color: muted),
                    const SizedBox(height: 8),
                    Text(
                      'No MCP servers configured for this Workspace.',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: SyntilaColors.textPrimary(isDark),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Click "Add Remote Server" above or use `syntila mcp add <id> --command <path>` on your machine.',
                      style: TextStyle(fontSize: 12.5, color: muted),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else
              for (final server in servers) ...[
                _buildServerCard(context, server, isDark, muted),
                const SizedBox(height: 12),
              ],
          ],
        );
      },
    );
  }

  Widget _buildServerCard(
    BuildContext context,
    AxMcpServer server,
    bool isDark,
    Color muted,
  ) {
    final isTestingThis = _testing && _testingServerId == server.serverId;

    return Container(
      key: ValueKey('setting-mcp-server-${server.serverId}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.03)
            : Colors.black.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: SyntilaColors.border(isDark)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          server.displayName,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: SyntilaColors.textPrimary(isDark),
                          ),
                        ),
                        _chip(
                          server.isRemote ? 'Remote' : 'Local',
                          isDark
                              ? Colors.purple.shade200
                              : Colors.purple.shade800,
                          isDark
                              ? Colors.purple.shade900.withValues(alpha: 0.3)
                              : Colors.purple.shade50,
                        ),
                        _availabilityChip(server.availability, isDark),
                        _consentChip(server.consented, isDark),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      server.serverId,
                      style: TextStyle(
                        fontFamily: 'JetBrains Mono',
                        fontSize: 12,
                        color: muted,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                key: ValueKey('setting-mcp-toggle-${server.serverId}'),
                value: server.enabled,
                onChanged: (val) => _toggleEnabled(server, val),
              ),
            ],
          ),
          if (server.blocker != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 15,
                  color:
                      server.consented ? Colors.orange : Colors.amber.shade700,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    server.blocker!,
                    style: TextStyle(
                      fontSize: 12,
                      color: server.consented
                          ? Colors.orange
                          : Colors.amber.shade700,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          // Tools & bindings summary
          Text(
            'Tools (${server.tools.length}): ${server.tools.map((t) => t.name).join(', ')}',
            style: TextStyle(
                fontSize: 12.5, color: SyntilaColors.textSecondary(isDark)),
          ),
          const SizedBox(height: 4),
          Text(
            'Worker bindings: ${server.boundWorkerTypes.isEmpty ? "None" : server.boundWorkerTypes.join(", ")}',
            style: TextStyle(fontSize: 12, color: muted),
          ),
          const SizedBox(height: 12),
          // Actions row
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: ValueKey('setting-mcp-test-${server.serverId}'),
                onPressed: isTestingThis ? null : () => _testServer(server),
                icon: isTestingThis
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.network_check, size: 16),
                label: Text(isTestingThis ? 'Testing...' : 'Test'),
              ),
              ElevatedButton.icon(
                key: ValueKey('setting-mcp-consent-${server.serverId}'),
                onPressed: () => _openConsentDialog(server),
                icon: const Icon(Icons.verified_user_outlined, size: 16),
                label: Text(server.consented ? 'Re-consent' : 'Consent'),
              ),
              if (!server.isRemote)
                OutlinedButton.icon(
                  key: ValueKey('setting-mcp-bind-${server.serverId}'),
                  onPressed: () => _openBindingsDialog(server),
                  icon: const Icon(Icons.link, size: 16),
                  label: const Text('Worker Bindings'),
                ),
              IconButton(
                key: ValueKey('setting-mcp-remove-${server.serverId}'),
                tooltip: 'Remove server',
                icon: const Icon(Icons.delete_outline,
                    size: 18, color: SyntilaColors.error),
                onPressed: () => _removeServer(server),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, Color fg, Color bg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style:
              TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: fg),
        ),
      );

  Widget _availabilityChip(String availability, bool isDark) {
    final Color fg;
    final Color bg;
    switch (availability) {
      case 'available':
        fg = isDark ? Colors.green.shade200 : Colors.green.shade800;
        bg = isDark
            ? Colors.green.shade900.withValues(alpha: 0.3)
            : Colors.green.shade50;
      case 'unavailable':
        fg = isDark ? Colors.red.shade200 : Colors.red.shade800;
        bg = isDark
            ? Colors.red.shade900.withValues(alpha: 0.3)
            : Colors.red.shade50;
      case 'incompatible':
        fg = isDark ? Colors.orange.shade200 : Colors.orange.shade800;
        bg = isDark
            ? Colors.orange.shade900.withValues(alpha: 0.3)
            : Colors.orange.shade50;
      default:
        fg = isDark ? Colors.grey.shade300 : Colors.grey.shade700;
        bg = isDark
            ? Colors.grey.shade800.withValues(alpha: 0.3)
            : Colors.grey.shade200;
    }
    return _chip(
      availability[0].toUpperCase() + availability.substring(1),
      fg,
      bg,
    );
  }

  Widget _consentChip(bool consented, bool isDark) => _chip(
        consented ? 'Consented' : 'Not Consented',
        consented
            ? (isDark ? Colors.teal.shade200 : Colors.teal.shade800)
            : (isDark ? Colors.amber.shade200 : Colors.amber.shade800),
        consented
            ? (isDark
                ? Colors.teal.shade900.withValues(alpha: 0.3)
                : Colors.teal.shade50)
            : (isDark
                ? Colors.amber.shade900.withValues(alpha: 0.3)
                : Colors.amber.shade50),
      );
}

/// Dialog displaying complete tool definitions and a meaningful diff before consent.
class McpConsentDialog extends StatefulWidget {
  const McpConsentDialog({
    super.key,
    required this.workspaceId,
    required this.server,
    required this.inventories,
  });

  final String workspaceId;
  final AxMcpServer server;
  final AxMcpInventories inventories;

  @override
  State<McpConsentDialog> createState() => _McpConsentDialogState();
}

class _McpConsentDialogState extends State<McpConsentDialog> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _document;
  String? _documentHash;
  bool _accepting = false;

  @override
  void initState() {
    super.initState();
    _fetchConsentDocument();
  }

  Future<void> _fetchConsentDocument() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.inventories.execute(
        widget.workspaceId,
        action: 'consent',
        serverId: widget.server.serverId,
      );
      final outcome = response['result'] as Map?;
      if (outcome != null) {
        setState(() {
          _document = outcome['document'] != null
              ? Map<String, dynamic>.from(outcome['document'] as Map)
              : null;
          _documentHash = outcome['documentHash'] as String?;
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Invalid response from Workspace Service.';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _acceptConsent() async {
    if (_documentHash == null) return;
    setState(() => _accepting = true);
    try {
      await widget.inventories.execute(
        widget.workspaceId,
        action: 'consent',
        serverId: widget.server.serverId,
        acceptHash: _documentHash,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Consent failed: $e';
          _accepting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = SyntilaColors.navigationTextMuted(isDark);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.verified_user_outlined, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Consent to ${widget.server.displayName}'),
          ),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: 520,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline,
                            size: 36, color: SyntilaColors.error),
                        const SizedBox(height: 8),
                        Text(_error!,
                            style: const TextStyle(color: SyntilaColors.error),
                            textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        OutlinedButton(
                            onPressed: _fetchConsentDocument,
                            child: const Text('Retry')),
                      ],
                    ),
                  )
                : _buildContent(isDark, muted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('mcp-consent-confirm'),
          onPressed: _loading || _documentHash == null || _accepting
              ? null
              : _acceptConsent,
          child: Text(_accepting ? 'Recording...' : 'Accept & Consent'),
        ),
      ],
    );
  }

  Widget _buildContent(bool isDark, Color muted) {
    final doc = _document ?? const <String, dynamic>{};
    final probedTools = (doc['tools'] as List? ?? const []).cast<Map>();

    // Calculate diff against previous pins
    final previousPins = {
      for (final t in widget.server.tools) t.name: t.definitionHash
    };
    final addedTools = <String>[];
    final modifiedTools = <String>[];
    final unchangedTools = <String>[];

    for (final pt in probedTools) {
      final name = pt['name'] as String;
      // In definition hash comparison:
      final prevHash = previousPins[name];
      if (prevHash == null) {
        addedTools.add(name);
      } else {
        final currentHash = toolDefinitionHash(Map<String, Object?>.from(pt));
        if (currentHash != prevHash) {
          modifiedTools.add(name);
        } else {
          unchangedTools.add(name);
        }
      }
    }

    final probedNames = probedTools.map((t) => t['name'] as String).toSet();
    final removedTools =
        previousPins.keys.where((name) => !probedNames.contains(name)).toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Security warning banner
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.security, size: 18, color: Colors.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.server.isRemote
                        ? 'This is a remote server. Execution requests leave your computer and run remotely.'
                        : 'Local tool server. Execution occurs on your local machine under supervised Engine limits.',
                    style: TextStyle(
                        fontSize: 12, color: SyntilaColors.textPrimary(isDark)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Definition diff summary
          Text('DEFINITION CHANGES',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.7,
                  color: SyntilaColors.neutralText(isDark))),
          const SizedBox(height: 6),
          if (previousPins.isEmpty)
            Text(
                'First-time consent: pinning all ${probedTools.length} tool definitions.',
                style: TextStyle(fontSize: 12.5, color: muted))
          else if (addedTools.isEmpty &&
              modifiedTools.isEmpty &&
              removedTools.isEmpty)
            Text(
                'No definition changes detected. All tool hashes match existing consent.',
                style: TextStyle(fontSize: 12.5, color: Colors.green.shade600))
          else ...[
            if (addedTools.isNotEmpty)
              _diffRow('Added tools (${addedTools.length}):',
                  addedTools.join(', '), Colors.green),
            if (modifiedTools.isNotEmpty)
              _diffRow('Modified tools (${modifiedTools.length}):',
                  modifiedTools.join(', '), Colors.orange),
            if (removedTools.isNotEmpty)
              _diffRow('Removed tools (${removedTools.length}):',
                  removedTools.join(', '), SyntilaColors.error),
            if (unchangedTools.isNotEmpty)
              _diffRow('Unchanged tools (${unchangedTools.length}):',
                  unchangedTools.join(', '), muted),
          ],
          const SizedBox(height: 16),
          // Complete tool definitions
          Text('TOOL DEFINITIONS (${probedTools.length})',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.7,
                  color: SyntilaColors.neutralText(isDark))),
          const SizedBox(height: 8),
          for (final t in probedTools) ...[
            _buildToolCard(t, isDark, muted),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 16),
          // Document hash
          Text('DOCUMENT HASH',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.7,
                  color: SyntilaColors.neutralText(isDark))),
          const SizedBox(height: 4),
          SelectableText(
            _documentHash ?? '',
            style: const TextStyle(fontFamily: 'JetBrains Mono', fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _diffRow(String label, String value, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600, color: color)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(value, style: TextStyle(fontSize: 12, color: color)),
            ),
          ],
        ),
      );

  Widget _buildToolCard(Map tool, bool isDark, Color muted) {
    final name = tool['name'] as String;
    final description = tool['description'] as String?;
    final inputSchema = tool['inputSchema'];
    final encoder = const JsonEncoder.withIndent('  ');

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: SyntilaColors.border(isDark)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.build_circle_outlined, size: 16),
              const SizedBox(width: 6),
              Text(name,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: SyntilaColors.textPrimary(isDark))),
            ],
          ),
          if (description != null && description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(description,
                style: TextStyle(
                    fontSize: 12, color: SyntilaColors.textSecondary(isDark))),
          ],
          if (inputSchema != null) ...[
            const SizedBox(height: 6),
            Text('Input Schema:',
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600, color: muted)),
            const SizedBox(height: 2),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isDark ? Colors.black38 : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                encoder.convert(inputSchema),
                style: const TextStyle(
                    fontFamily: 'JetBrains Mono', fontSize: 10.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Dialog to configure and add a new remote MCP server.
class McpAddRemoteServerDialog extends StatefulWidget {
  const McpAddRemoteServerDialog({
    super.key,
    required this.workspaceId,
    required this.inventories,
  });

  final String workspaceId;
  final AxMcpInventories inventories;

  @override
  State<McpAddRemoteServerDialog> createState() =>
      _McpAddRemoteServerDialogState();
}

class _McpAddRemoteServerDialogState extends State<McpAddRemoteServerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _name = TextEditingController();
  final _endpoint = TextEditingController();
  final _tokenEnv = TextEditingController();
  bool _insecureLoopback = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _endpoint.dispose();
    _tokenEnv.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.inventories.execute(
        widget.workspaceId,
        action: 'addRemote',
        serverId: _id.text.trim().toLowerCase(),
        displayName: _name.text.trim(),
        endpoint: _endpoint.text.trim(),
        tokenEnv: _tokenEnv.text.trim().isEmpty ? null : _tokenEnv.text.trim(),
        insecureLoopback: _insecureLoopback,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Remote MCP Server'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!,
                      style: const TextStyle(
                          color: SyntilaColors.error, fontSize: 12)),
                ),
              TextFormField(
                key: const ValueKey('mcp-add-id'),
                controller: _id,
                decoration: const InputDecoration(
                  labelText: 'Server ID',
                  hintText: 'e.g. github-remote',
                  isDense: true,
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) return 'Required';
                  if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$')
                      .hasMatch(val.trim())) {
                    return 'Lowercase letters, numbers, dash and underscore only (max 64 chars)';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('mcp-add-name'),
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Display Name',
                  hintText: 'e.g. GitHub Tools',
                  isDense: true,
                ),
                validator: (val) =>
                    val == null || val.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('mcp-add-endpoint'),
                controller: _endpoint,
                decoration: const InputDecoration(
                  labelText: 'Endpoint URL',
                  hintText: 'https://...',
                  isDense: true,
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) return 'Required';
                  final uri = Uri.tryParse(val.trim());
                  if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
                    return 'Valid URL required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('mcp-add-token-env'),
                controller: _tokenEnv,
                decoration: const InputDecoration(
                  labelText: 'Token Environment Variable (optional)',
                  hintText: 'e.g. GITHUB_TOKEN',
                  isDense: true,
                ),
                validator: (val) {
                  if (val != null && val.trim().isNotEmpty) {
                    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$')
                        .hasMatch(val.trim())) {
                      return 'Valid environment variable name required';
                    }
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                key: const ValueKey('mcp-add-loopback'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Allow insecure loopback (http://localhost)',
                    style: TextStyle(fontSize: 13)),
                value: _insecureLoopback,
                onChanged: (val) => setState(() => _insecureLoopback = val),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('mcp-add-submit'),
          onPressed: _saving ? null : _submit,
          child: Text(_saving ? 'Adding...' : 'Add Server'),
        ),
      ],
    );
  }
}

/// Dialog to manage Worker bindings for a server.
class McpBindingsDialog extends StatefulWidget {
  const McpBindingsDialog({
    super.key,
    required this.workspaceId,
    required this.server,
    required this.inventories,
    required this.knownWorkerTypes,
  });

  final String workspaceId;
  final AxMcpServer server;
  final AxMcpInventories inventories;
  final List<String> knownWorkerTypes;

  @override
  State<McpBindingsDialog> createState() => _McpBindingsDialogState();
}

class _McpBindingsDialogState extends State<McpBindingsDialog> {
  late final Set<String> _bound = {...widget.server.boundWorkerTypes};
  bool _busy = false;

  Future<void> _toggleBinding(String workerTypeId, bool bind) async {
    setState(() => _busy = true);
    try {
      await widget.inventories.execute(
        widget.workspaceId,
        action: bind ? 'bind' : 'unbind',
        serverId: widget.server.serverId,
        workerTypeId: workerTypeId,
      );
      setState(() {
        if (bind) {
          _bound.add(workerTypeId);
        } else {
          _bound.remove(workerTypeId);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Worker Bindings for ${widget.server.displayName}'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select which Workers may access this server when selected in a Workflow:',
              style: TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            for (final type in {
              ...widget.knownWorkerTypes,
              ...widget.server.boundWorkerTypes
            })
              CheckboxListTile(
                key: ValueKey('mcp-binding-$type'),
                title: Text(type),
                value: _bound.contains(type),
                enabled: !_busy,
                onChanged: (val) {
                  if (val != null) _toggleBinding(type, val);
                },
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
