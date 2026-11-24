import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../navigation/ax_navigation.dart';
import '../../ax/ax_models.dart';
import '../common/command_palette.dart';

/// Full-page search view rendered in the main workspace content area.
class SearchPage extends StatelessWidget {
  const SearchPage({
    super.key,
    required this.query,
    required this.spaces,
    required this.workspaces,
    required this.threadsBySpace,
    this.run,
    required this.onNavigateTo,
    required this.onSelectSpace,
    required this.onClearSearch,
    this.onToggleTheme,
    this.onCreateContextualItem,
  });

  // Compatibility constructor / parameter forwarding
  const SearchPage.compat({
    super.key,
    required this.query,
    required this.spaces,
    required this.workspaces,
    required this.threadsBySpace,
    this.run,
    required this.onNavigateTo,
    required this.onSelectSpace,
    required this.onClearSearch,
    this.onToggleTheme,
    this.onCreateContextualItem,
  });

  final String query;
  final List<AxSpace> spaces;
  final List<AxWorkspace> workspaces;
  final Map<String, List<AxThread>> threadsBySpace;
  final AxRun? run;
  final ValueChanged<AxNavigation> onNavigateTo;
  final ValueChanged<String> onSelectSpace;
  final VoidCallback onClearSearch;
  final VoidCallback? onToggleTheme;
  final VoidCallback? onCreateContextualItem;

  // Compatibility getters

  List<CommandPaletteAction> _buildAllActions(BuildContext context) {
    final actions = <CommandPaletteAction>[
      // Navigation Actions
      CommandPaletteAction(
        title: 'Home',
        subtitle: 'Overview, recent activity, and system status',
        icon: Icons.home_outlined,
        category: 'Navigation',
        onSelect: () {
          onClearSearch();
          onNavigateTo(const AxNavigation.home());
        },
      ),
      CommandPaletteAction(
        title: 'Spaces',
        subtitle: 'Explore spaces and ongoing threads',
        icon: Icons.folder_outlined,
        category: 'Navigation',
        onSelect: () {
          onClearSearch();
          onNavigateTo(const AxNavigation.spaces());
        },
      ),
      CommandPaletteAction(
        title: 'Workers',
        subtitle: 'Connected computers and assigned Worker profiles',
        icon: Icons.computer_outlined,
        category: 'Navigation',
        onSelect: () {
          onClearSearch();
          onNavigateTo(const AxNavigation.workspaces());
        },
      ),
      CommandPaletteAction(
        title: 'Profile & Security',
        subtitle: 'Profile, linked accounts, and active sessions',
        icon: Icons.person_outline_rounded,
        category: 'Navigation',
        onSelect: () {
          onClearSearch();
          onNavigateTo(const AxNavigation.profileSecurity());
        },
      ),
    ];

    if (onToggleTheme != null) {
      actions.add(CommandPaletteAction(
        title: 'Toggle Theme',
        subtitle: 'Switch between light and dark modes',
        icon: Icons.dark_mode_outlined,
        category: 'Actions',
        onSelect: () {
          onClearSearch();
          onToggleTheme!();
        },
      ));
    }

    if (onCreateContextualItem != null) {
      actions.add(CommandPaletteAction(
        title: 'Create Space or Thread',
        subtitle: 'Add a focused area for team discussion and Work',
        icon: Icons.add_rounded,
        category: 'Actions',
        onSelect: () {
          onClearSearch();
          onCreateContextualItem!();
        },
      ));
    }

    // Spaces and Threads
    for (final space in spaces) {
      actions.add(CommandPaletteAction(
        title: space.name,
        subtitle: space.description.isNotEmpty ? space.description : 'Space',
        icon: Icons.folder_outlined,
        category: 'Spaces',
        onSelect: () {
          onClearSearch();
          onSelectSpace(space.id);
        },
      ));

      for (final thread in (threadsBySpace[space.id] ?? const <AxThread>[])) {
        actions.add(CommandPaletteAction(
          title: thread.name,
          subtitle: '${space.name} · ${thread.status}',
          icon: Icons.alt_route_rounded,
          category: 'Threads',
          onSelect: () {
            onClearSearch();
            onNavigateTo(AxNavigation.thread(space.id, thread.id));
          },
        ));
      }
    }

    // Active Run
    final activeRun = run;
    if (activeRun != null) {
      final spaceId = spaces.firstOrNull?.id ?? '';
      actions.add(CommandPaletteAction(
        title: activeRun.objective.isNotEmpty
            ? activeRun.objective
            : 'Active Run: ${activeRun.id}',
        subtitle:
            '${activeRun.status.name} · ${activeRun.completedTaskCount}/${activeRun.taskCount} tasks',
        icon: Icons.play_circle_outline_rounded,
        category: 'Runs',
        onSelect: () {
          onClearSearch();
          onNavigateTo(AxNavigation.run(
            spaceId,
            activeRun.id,
            threadId: activeRun.threadId,
          ));
        },
      ));
    }

    // Workspaces
    for (final workspace in workspaces) {
      actions.add(CommandPaletteAction(
        title: workspace.name,
        subtitle: '${workspace.hostname} · ${workspace.status}',
        icon: Icons.computer_outlined,
        category: 'Workers',
        onSelect: () {
          onClearSearch();
          onNavigateTo(AxNavigation.workspaces(workspaceId: workspace.id));
        },
      ));
    }

    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) return actions;

    return actions.where((action) {
      final matchesTitle = action.title.toLowerCase().contains(trimmed);
      final matchesSubtitle =
          action.subtitle?.toLowerCase().contains(trimmed) ?? false;
      final matchesCategory = action.category.toLowerCase().contains(trimmed);
      return matchesTitle || matchesSubtitle || matchesCategory;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final results = _buildAllActions(context);

    // Group results by category
    final grouped = <String, List<CommandPaletteAction>>{};
    for (final action in results) {
      grouped.putIfAbsent(action.category, () => []).add(action);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Search Header
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: SyntilaColors.primarySoftColor(isDark),
                          borderRadius: BorderRadius.circular(SyntilaRadius.sm),
                        ),
                        child: Icon(
                          Icons.search_rounded,
                          size: 22,
                          color: SyntilaColors.primaryForeground(isDark),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'Search Results',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -.4,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    query.trim().isEmpty
                        ? 'Showing all items across Syntila'
                        : 'Found ${results.length} ${results.length == 1 ? "result" : "results"} for "${query.trim()}"',
                    style: TextStyle(
                      fontSize: 13,
                      color: SyntilaColors.textSecondary(isDark),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),

        // Results or Empty State
        if (results.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
            decoration: BoxDecoration(
              color:
                  isDark ? SyntilaBrand.darkSurface : SyntilaBrand.lightSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark ? SyntilaBrand.darkLine : SyntilaBrand.lightLine,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.search_off_rounded,
                  size: 48,
                  color: SyntilaColors.neutral,
                ),
                const SizedBox(height: 16),
                Text(
                  'No results found for "${query.trim()}"',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Try searching for space names, threads, workers, or navigation destinations.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: SyntilaColors.textSecondary(isDark),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: onClearSearch,
                  icon: const Icon(Icons.arrow_back_rounded, size: 16),
                  label: const Text('Back to previous page'),
                  style: FilledButton.styleFrom(
                    backgroundColor: SyntilaBrand.accent,
                  ),
                ),
              ],
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final entry in grouped.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 10),
                  child: Row(
                    children: [
                      Text(
                        entry.key.toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: SyntilaColors.textSecondary(isDark),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: SyntilaColors.surfaceHover(isDark),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${entry.value.length}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: SyntilaColors.textSecondary(isDark),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: entry.value.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final item = entry.value[index];
                    return _SearchResultTile(
                      action: item,
                      isDark: isDark,
                    );
                  },
                ),
                const SizedBox(height: 18),
              ],
            ],
          ),
      ],
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.action,
    required this.isDark,
  });

  final CommandPaletteAction action;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: action.onSelect,
      borderRadius: BorderRadius.circular(10),
      hoverColor: SyntilaColors.surfaceHover(isDark),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: SyntilaColors.surface(isDark),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: SyntilaColors.border(isDark),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: SyntilaColors.surfaceHover(isDark),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: SyntilaColors.border(isDark),
                ),
              ),
              child: Icon(
                action.icon,
                size: 18,
                color: SyntilaColors.textSecondary(isDark),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    action.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: SyntilaColors.textPrimary(isDark),
                    ),
                  ),
                  if (action.subtitle != null &&
                      action.subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      action.subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: SyntilaColors.textSecondary(isDark),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: SyntilaColors.surfaceHover(isDark),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                action.category,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: SyntilaColors.textSecondary(isDark),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: SyntilaColors.textSecondary(isDark),
            ),
          ],
        ),
      ),
    );
  }
}
