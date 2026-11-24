import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../brand.dart';
import '../../navigation/ax_navigation.dart';
import '../../ax/ax_models.dart';

/// Item in the command palette search results
class CommandPaletteAction {
  const CommandPaletteAction({
    required this.title,
    this.subtitle,
    required this.icon,
    required this.onSelect,
    this.category = 'General',
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback onSelect;
  final String category;
}

/// Global Command Palette Modal Dialog (`Cmd+K` / `Ctrl+K`)
class CommandPaletteDialog extends StatefulWidget {
  const CommandPaletteDialog({
    super.key,
    List<AxSpace>? spaces,
    required this.workspaces,
    Map<String, List<AxThread>>? threadsBySpace,
    this.run,
    ValueChanged<String>? onSelectSpace,
    required this.onNavigateTo,
    required this.onToggleTheme,
  })  : spaces = spaces ?? const [],
        threadsBySpace = threadsBySpace ?? const {},
        onSelectSpace = onSelectSpace ?? _noopString;

  static void _noopString(String _) {}

  final List<AxSpace> spaces;
  final List<AxWorkspace> workspaces;
  final Map<String, List<AxThread>> threadsBySpace;
  final AxRun? run;
  final ValueChanged<String> onSelectSpace;
  final ValueChanged<AxNavigation> onNavigateTo;
  final VoidCallback onToggleTheme;

  @override
  State<CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<CommandPaletteDialog> {
  final _searchController = TextEditingController();
  String _query = '';
  int _highlightedIndex = 0;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _query = _searchController.text.trim().toLowerCase();
        _highlightedIndex = 0;
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<CommandPaletteAction> _buildActions() {
    final actions = <CommandPaletteAction>[
      // Navigation Actions
      CommandPaletteAction(
        title: 'Home',
        subtitle: 'Overview, recent activity, and system status',
        icon: Icons.home_outlined,
        category: 'Navigation',
        onSelect: () {
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
          widget.onNavigateTo(const AxNavigation.home());
        },
      ),
      CommandPaletteAction(
        title: 'Workers',
        subtitle: 'Connected computers and assigned Worker profiles',
        icon: Icons.computer_outlined,
        category: 'Navigation',
        onSelect: () {
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
          widget.onNavigateTo(const AxNavigation.workspaces());
        },
      ),
      CommandPaletteAction(
        title: 'Profile & Security',
        subtitle: 'Profile, linked accounts, and active sessions',
        icon: Icons.person_outline_rounded,
        category: 'Navigation',
        onSelect: () {
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
          widget.onNavigateTo(const AxNavigation.profileSecurity());
        },
      ),
      CommandPaletteAction(
        title: 'Toggle Theme',
        subtitle: 'Switch between light and dark modes',
        icon: Icons.dark_mode_outlined,
        category: 'Actions',
        onSelect: () {
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
          widget.onToggleTheme();
        },
      ),
    ];

    // Add Spaces and Threads
    for (final space in widget.spaces) {
      actions.add(CommandPaletteAction(
        title: 'Space: ${space.name}',
        subtitle: space.description.isNotEmpty ? space.description : 'Space',
        icon: Icons.folder_outlined,
        category: 'Spaces',
        onSelect: () {
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
          widget.onSelectSpace(space.id);
        },
      ));

      // Add Threads (First-class)
      for (final thread
          in (widget.threadsBySpace[space.id] ?? const <AxThread>[])) {
        actions.add(CommandPaletteAction(
          title: 'Thread: ${thread.name}',
          subtitle: '${space.name} · ${thread.status}',
          icon: Icons.alt_route_rounded,
          category: 'Threads',
          onSelect: () {
            if (Navigator.of(context).canPop()) Navigator.of(context).pop();
            widget.onNavigateTo(AxNavigation.thread(space.id, thread.id));
          },
        ));
      }
    }

    // Add Active Run if present
    final activeRun = widget.run;
    if (activeRun != null) {
      final spaceId = activeRun.spaceId ?? widget.spaces.firstOrNull?.id ?? '';
      actions.add(CommandPaletteAction(
        title:
            'Active Run: ${activeRun.objective.isNotEmpty ? activeRun.objective : activeRun.id}',
        subtitle:
            '${activeRun.status.name} · ${activeRun.completedTaskCount}/${activeRun.taskCount} tasks',
        icon: Icons.play_circle_outline_rounded,
        category: 'Runs',
        onSelect: () {
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
          widget.onNavigateTo(AxNavigation.run(
            spaceId,
            activeRun.id,
            threadId: activeRun.threadId,
          ));
        },
      ));
    }

    // Add Workspaces
    for (final workspace in widget.workspaces) {
      actions.add(CommandPaletteAction(
        title: 'Workspace: ${workspace.name}',
        subtitle: '${workspace.hostname} · ${workspace.status}',
        icon: Icons.computer_outlined,
        category: 'Workspaces',
        onSelect: () {
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
          widget
              .onNavigateTo(AxNavigation.workspaces(workspaceId: workspace.id));
        },
      ));
    }

    if (_query.isEmpty) return actions;

    return actions.where((action) {
      final matchesTitle = action.title.toLowerCase().contains(_query);
      final matchesSubtitle =
          action.subtitle?.toLowerCase().contains(_query) ?? false;
      final matchesCategory = action.category.toLowerCase().contains(_query);
      return matchesTitle || matchesSubtitle || matchesCategory;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final actions = _buildActions();

    return Dialog(
      constraints: SyntilaDialogStyle.large,
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent || actions.isEmpty) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            setState(() =>
                _highlightedIndex = (_highlightedIndex + 1) % actions.length);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            setState(() => _highlightedIndex =
                (_highlightedIndex - 1 + actions.length) % actions.length);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.enter) {
            actions[_highlightedIndex].onSelect();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Container(
          width: 580,
          constraints: const BoxConstraints(maxHeight: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Search Input Header
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  style: TextStyle(
                    fontSize: 14,
                    color:
                        isDark ? SyntilaBrand.darkInk : SyntilaBrand.lightInk,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Type a command, space, or Thread...',
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    suffixIcon: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: isDark
                            ? SyntilaBrand.darkLine
                            : SyntilaBrand.lightLine,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'ESC',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? SyntilaBrand.darkInkMuted
                              : SyntilaBrand.lightInkMuted,
                        ),
                      ),
                    ),
                    filled: true,
                    fillColor: isDark
                        ? SyntilaBrand.darkPaper
                        : SyntilaBrand.lightPaper,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              Divider(
                  height: 1,
                  color:
                      isDark ? SyntilaBrand.darkLine : SyntilaBrand.lightLine),
              // Results List
              Flexible(
                child: actions.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'No results found for "$_query"',
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? SyntilaBrand.darkInkMuted
                                : SyntilaBrand.lightInkMuted,
                          ),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: actions.length,
                        itemBuilder: (context, index) {
                          final action = actions[index];
                          return ListTile(
                            dense: true,
                            selected: index == _highlightedIndex,
                            selectedTileColor: isDark
                                ? SyntilaBrand.accentWashDark
                                : SyntilaBrand.accentWash,
                            leading: Icon(action.icon,
                                size: 18, color: SyntilaBrand.accent),
                            title: Text(
                              action.title,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: isDark
                                    ? SyntilaBrand.darkInk
                                    : SyntilaBrand.lightInk,
                              ),
                            ),
                            subtitle: action.subtitle != null
                                ? Text(
                                    action.subtitle!,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isDark
                                          ? SyntilaBrand.darkInkMuted
                                          : SyntilaBrand.lightInkMuted,
                                    ),
                                  )
                                : null,
                            trailing: Text(
                              action.category,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: isDark
                                    ? SyntilaBrand.darkInkMuted
                                    : SyntilaBrand.lightInkMuted,
                              ),
                            ),
                            onTap: action.onSelect,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
