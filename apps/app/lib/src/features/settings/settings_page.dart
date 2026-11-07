import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../platform/view_preferences.dart';
import '../../ax/ax_models.dart';
import '../../ax/sync/ax_mcp_inventories.dart';
import 'mcp_management_view.dart';

/// Device-local view settings and Workspace MCP management.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.preferences,
    required this.onChanged,
    this.workspaceId,
    this.workspaces = const [],
    this.inventories,
    this.knownWorkerTypes = const ['chatgpt', 'codex', 'claude'],
  });

  final ViewPreferences preferences;
  final ValueChanged<ViewPreferences> onChanged;
  final String? workspaceId;
  final List<AxWorkspace> workspaces;
  final AxMcpInventories? inventories;
  final List<String> knownWorkerTypes;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _selectedWorkspaceId;

  @override
  void initState() {
    super.initState();
    _selectedWorkspaceId = widget.workspaceId ??
        (widget.workspaces.isNotEmpty ? widget.workspaces.first.id : null);
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.workspaceId != oldWidget.workspaceId &&
        widget.workspaceId != null) {
      _selectedWorkspaceId = widget.workspaceId;
    } else if (_selectedWorkspaceId == null && widget.workspaces.isNotEmpty) {
      _selectedWorkspaceId = widget.workspaces.first.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = SyntilaColors.navigationTextMuted(isDark);
    final showRecent = widget.preferences.showRecentThreads;
    final currentWorkspaceId = _selectedWorkspaceId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Settings',
            style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w700,
                color: SyntilaColors.textPrimary(isDark))),
        const SizedBox(height: 4),
        Text('These preferences apply to this device.',
            style: TextStyle(fontSize: 12.5, color: muted)),
        const SizedBox(height: 24),
        Text('APPEARANCE',
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
                color: SyntilaColors.neutralText(isDark))),
        const SizedBox(height: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Text size', style: TextStyle(fontSize: 14)),
                const SizedBox(height: 2),
                Text('Makes text larger across the app.',
                    style: TextStyle(fontSize: 12, color: muted)),
              ],
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<TextSizeOption>(
                key: const ValueKey('setting-text-size'),
                showSelectedIcon: false,
                segments: [
                  for (final option in TextSizeOption.values)
                    ButtonSegment(value: option, label: Text(option.label)),
                ],
                selected: {widget.preferences.textSize},
                onSelectionChanged: (selection) => widget.onChanged(
                    widget.preferences.copyWith(textSize: selection.first)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text('SIDEBAR',
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
                color: SyntilaColors.neutralText(isDark))),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const ValueKey('setting-show-recent-threads'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Show recent threads'),
          subtitle: Text(
              'List your most recently active threads at the top of the sidebar.',
              style: TextStyle(fontSize: 12, color: muted)),
          value: showRecent,
          onChanged: (value) => widget
              .onChanged(widget.preferences.copyWith(showRecentThreads: value)),
        ),
        const SizedBox(height: 8),
        Opacity(
          opacity: showRecent ? 1 : 0.45,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Recent threads to show',
                        style: TextStyle(fontSize: 14)),
                    const SizedBox(height: 2),
                    Text('How many threads the section lists.',
                        style: TextStyle(fontSize: 12, color: muted)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              SegmentedButton<int>(
                key: const ValueKey('setting-recent-threads-count'),
                showSelectedIcon: false,
                segments: [
                  for (final count in ViewPreferences.recentThreadsCountOptions)
                    ButtonSegment(value: count, label: Text('$count')),
                ],
                selected: {widget.preferences.recentThreadsCount},
                onSelectionChanged: showRecent
                    ? (selection) => widget.onChanged(widget.preferences
                        .copyWith(recentThreadsCount: selection.first))
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text('NOTIFICATIONS',
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
                color: SyntilaColors.neutralText(isDark))),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const ValueKey('setting-mute-sound'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Mute sound notifications'),
          subtitle: Text(
              'Silence sounds when a new message arrives or a request completes.',
              style: TextStyle(fontSize: 12, color: muted)),
          value: widget.preferences.muteSound,
          onChanged: (value) =>
              widget.onChanged(widget.preferences.copyWith(muteSound: value)),
        ),
        if (widget.inventories != null) ...[
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 24),
          if (widget.workspaces.length > 1) ...[
            Text('WORKSPACE',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.7,
                    color: SyntilaColors.neutralText(isDark))),
            const SizedBox(height: 8),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Active Workspace',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  key: const ValueKey('setting-mcp-workspace-selector'),
                  value: currentWorkspaceId,
                  isDense: true,
                  isExpanded: true,
                  items: [
                    for (final ws in widget.workspaces)
                      DropdownMenuItem(
                        value: ws.id,
                        child: Text('${ws.name} (${ws.status})'),
                      ),
                  ],
                  onChanged: (id) => setState(() => _selectedWorkspaceId = id),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (currentWorkspaceId != null)
            McpManagementView(
              key: ValueKey('mcp-view-$currentWorkspaceId'),
              workspaceId: currentWorkspaceId,
              inventories: widget.inventories!,
              knownWorkerTypes: widget.knownWorkerTypes,
            )
          else ...[
            Text('MCP SERVERS',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.7,
                    color: SyntilaColors.neutralText(isDark))),
            const SizedBox(height: 8),
            Text(
                'Connect a Workspace to manage Model Context Protocol servers.',
                style: TextStyle(fontSize: 12.5, color: muted)),
          ],
        ],
      ],
    );
  }
}
