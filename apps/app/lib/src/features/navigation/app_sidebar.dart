import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../brand.dart';
import '../../navigation/ax_navigation.dart';
import '../../ax/ax_models.dart';
import 'app_menu.dart';
import 'space_tree.dart';
import 'ax_shell_context.dart';

/// Canonical Application Sidebar for Syntila.
class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    this.onNavigateToRecentThread,
    ValueChanged<String>? onToggleSpaceExpanded,
    VoidCallback? onCreateSpace,
    this.onCreateThread,
    this.onEditSpace,
    this.onArchiveSpace,
    this.onDeleteSpace,
    this.onRenameThread,
    this.onSetThreadArchived,
    this.onDeleteThread,
    this.onReorderThreads,
    this.onSetSpacePinned,
    this.onSetThreadPinned,
    this.onReorderPinnedSpaces,
    this.onReorderPinnedThreads,
    this.searchController,
    this.searchFocusNode,
    this.onSearchChanged,
    this.onClearSearch,
    this.onOpenCommandPalette,
    this.onOpenNotifications,
    this.onToggleTheme,
    this.onSetThemeMode,
    required this.onLogout,
    required this.onOpenAbout,
    required this.onOpenExternal,
    this.onOpenArchivedSpaces,
    this.onToggleCollapse,
    this.compact = false,
  })  : onToggleSpaceExpanded = onToggleSpaceExpanded ?? _noopString,
        onCreateSpace = onCreateSpace ?? _noopVoid;

  static void _noopString(String _) {}
  static void _noopVoid() {}

  final AxShellContext shellContext;
  final ValueChanged<AxNavigation> onNavigateTo;
  final ValueChanged<AxNavigation>? onNavigateToRecentThread;
  final ValueChanged<String> onToggleSpaceExpanded;
  final VoidCallback onCreateSpace;
  final ValueChanged<AxSpace>? onCreateThread;
  final Future<void> Function(AxSpace space)? onEditSpace;
  final Future<void> Function(AxSpace space)? onArchiveSpace;
  final Future<void> Function(AxSpace space)? onDeleteSpace;
  final Future<void> Function(AxThread thread, String name)? onRenameThread;
  final Future<void> Function(AxThread thread, bool archived)?
      onSetThreadArchived;
  final Future<void> Function(AxThread thread)? onDeleteThread;
  final Future<void> Function(AxSpace space, List<String> orderedThreadIds)?
      onReorderThreads;
  final Future<void> Function(AxSpace space, bool pinned)? onSetSpacePinned;
  final Future<void> Function(AxThread thread, bool pinned)? onSetThreadPinned;
  final Future<void> Function(List<String> orderedIds)? onReorderPinnedSpaces;
  final Future<void> Function(AxSpace space, List<String> orderedIds)?
      onReorderPinnedThreads;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onClearSearch;
  final VoidCallback? onOpenCommandPalette;
  final VoidCallback? onOpenNotifications;
  final VoidCallback? onToggleTheme;
  final ValueChanged<ThemeMode>? onSetThemeMode;
  final VoidCallback onLogout;
  final VoidCallback onOpenAbout;
  final ValueChanged<Uri> onOpenExternal;
  final VoidCallback? onOpenArchivedSpaces;
  final VoidCallback? onToggleCollapse;
  final bool compact;

  @override
  Widget build(BuildContext context) => TooltipVisibility(
        visible: false,
        child: Builder(builder: _buildSidebar),
      );

  Widget _buildSidebar(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (sidebarContext, constraints) {
        final width =
            constraints.hasBoundedWidth ? constraints.maxWidth : 220.0;
        final narrow = width < 160;
        final sidePadding = narrow ? 6.0 : 10.0;
        return Container(
          width: width,
          color: SyntilaColors.navigationBackground(isDark),
          padding: EdgeInsets.fromLTRB(sidePadding, 16, sidePadding, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Brand and primary actions share one compact header.
              IconButtonTheme(
                data: compact
                    ? IconButtonThemeData(
                        style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ))
                    : IconButtonTheme.of(context),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Semantics(
                      label: 'Syntila — Home',
                      child: Tooltip(
                        excludeFromSemantics: true,
                        message: 'Syntila — Home',
                        child: InkWell(
                          onTap: () {
                            onNavigateTo(const AxNavigation.home());
                            if (compact) {
                              Scaffold.maybeOf(sidebarContext)?.closeDrawer();
                            }
                          },
                          borderRadius: BorderRadius.circular(SyntilaRadius.sm),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: SyntilaBrand.logoMark(size: 28),
                          ),
                        ),
                      ),
                    ),
                    if (!compact)
                      _RailSearchMenuAnchor(
                        menuStyle: SyntilaMenuStyle.surface(isDark),
                        searchController: searchController,
                        searchFocusNode: searchFocusNode,
                        onSearchChanged: onSearchChanged,
                        onClearSearch: onClearSearch,
                        onNavigateTo: onNavigateTo,
                        isDark: isDark,
                      ),
                    Semantics(
                        label: 'New Space',
                        child: Tooltip(
                          excludeFromSemantics: true,
                          message: 'New Space',
                          child: IconButton(
                            onPressed: onCreateSpace,
                            icon: Icon(
                              Icons.add_rounded,
                              size: 18,
                              color: SyntilaColors.navigationTextMuted(isDark),
                            ),
                            splashRadius: 14,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 32, minHeight: 32),
                            style: IconButton.styleFrom(
                              hoverColor: SyntilaColors.navigationHover(isDark),
                              shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(SyntilaRadius.sm),
                              ),
                            ),
                          ),
                        )),
                    if (!compact)
                      shellContext.watchNotifications(() {
                        final count = shellContext.unreadNotificationCount;
                        return Semantics(
                          label: count > 0
                              ? '$count unread notifications'
                              : 'Notifications',
                          child: Tooltip(
                            excludeFromSemantics: true,
                            message: 'Notifications',
                            child: IconButton(
                              onPressed: onOpenNotifications,
                              icon: count > 0
                                  ? Badge.count(
                                      count: count,
                                      backgroundColor: SyntilaColors.primary,
                                      textColor: Colors.white,
                                      child: Icon(
                                        Icons.notifications_none_rounded,
                                        size: 18,
                                        color:
                                            SyntilaColors.navigationTextMuted(
                                                isDark),
                                      ),
                                    )
                                  : Icon(
                                      Icons.notifications_none_rounded,
                                      size: 18,
                                      color: SyntilaColors.navigationTextMuted(
                                          isDark),
                                    ),
                              splashRadius: 14,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 32, minHeight: 32),
                              style: IconButton.styleFrom(
                                hoverColor:
                                    SyntilaColors.navigationHover(isDark),
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(SyntilaRadius.sm),
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    Semantics(
                      label: 'Hide sidebar',
                      child: Tooltip(
                        excludeFromSemantics: true,
                        message: 'Hide sidebar',
                        child: IconButton(
                          onPressed: compact
                              ? () => Scaffold.maybeOf(sidebarContext)
                                  ?.closeDrawer()
                              : onToggleCollapse,
                          icon: Icon(Icons.menu_open_rounded,
                              size: 20,
                              color: SyntilaColors.navigationTextMuted(isDark)),
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(minWidth: 32, minHeight: 32),
                          style: IconButton.styleFrom(
                            hoverColor: SyntilaColors.navigationHover(isDark),
                            shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(SyntilaRadius.sm)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Navigation Centerpiece: Full Space Tree
              Expanded(
                child: SingleChildScrollView(
                  child: SpaceTree(
                    shellContext: shellContext,
                    onNavigateTo: onNavigateTo,
                    onNavigateToRecentThread: onNavigateToRecentThread,
                    onToggleSpaceExpanded: onToggleSpaceExpanded,
                    onCreateSpace: onCreateSpace,
                    onCreateThread: onCreateThread,
                    onEditSpace: onEditSpace,
                    onArchiveSpace: onArchiveSpace,
                    onDeleteSpace: onDeleteSpace,
                    onRenameThread: onRenameThread,
                    onSetThreadArchived: onSetThreadArchived,
                    onDeleteThread: onDeleteThread,
                    onReorderThreads: onReorderThreads,
                    onSetSpacePinned: onSetSpacePinned,
                    onSetThreadPinned: onSetThreadPinned,
                    onReorderPinnedSpaces: onReorderPinnedSpaces,
                    onReorderPinnedThreads: onReorderPinnedThreads,
                    compact: compact,
                    narrow: narrow,
                    showRecentThreads:
                        shellContext.viewPreferences.showRecentThreads,
                    recentThreadsCount:
                        shellContext.viewPreferences.recentThreadsCount,
                  ),
                ),
              ),

              const SizedBox(height: 6),

              // Bottom Profile Button + ⋯ Global Application Menu
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                        label: 'Profile & Settings',
                        child: Tooltip(
                          excludeFromSemantics: true,
                          message: 'Profile & Settings',
                          waitDuration: const Duration(milliseconds: 600),
                          child: InkWell(
                            onTap: () {
                              onNavigateTo(
                                  const AxNavigation.profileSecurity());
                              if (compact) {
                                Scaffold.maybeOf(sidebarContext)?.closeDrawer();
                              }
                            },
                            borderRadius:
                                BorderRadius.circular(SyntilaRadius.sm),
                            hoverColor: SyntilaColors.navigationHover(isDark),
                            focusColor: (isDark
                                ? SyntilaColors.navigationSelectedColor(isDark)
                                : SyntilaColors.primarySoft),
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: narrow ? 2 : 6, vertical: 6),
                              decoration: BoxDecoration(
                                color: shellContext.isNavActive(
                                        const AxNavigation.profileSecurity())
                                    ? (isDark
                                        ? SyntilaColors.navigationSelectedColor(
                                            isDark)
                                        : SyntilaColors.primarySoft)
                                    : Colors.transparent,
                                borderRadius:
                                    BorderRadius.circular(SyntilaRadius.sm),
                              ),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    radius: 13,
                                    backgroundColor: SyntilaColors.primarySoft,
                                    backgroundImage:
                                        shellContext.viewerAvatarImage,
                                    child: shellContext.viewerAvatarImage ==
                                            null
                                        ? Text(
                                            shellContext.viewerInitials,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color:
                                                  SyntilaColors.primaryPressed,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          )
                                        : null,
                                  ),
                                  if (!narrow) const SizedBox(width: 8),
                                  if (!narrow)
                                    Expanded(
                                      child: Text(
                                        shellContext.viewerDisplayName ??
                                            shellContext.viewerEmail ??
                                            'Not signed in',
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: shellContext.isNavActive(
                                                  const AxNavigation
                                                      .profileSecurity())
                                              ? SyntilaColors.navigationText(
                                                  isDark)
                                              : SyntilaColors
                                                  .navigationTextMuted(isDark),
                                          fontSize: 11.5,
                                          fontWeight: shellContext.isNavActive(
                                                  const AxNavigation
                                                      .profileSecurity())
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        )),
                  ),
                  if (!compact) ...[
                    const SizedBox(width: 4),
                    _applicationMenu(),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _applicationMenu() => GlobalAppMenu(
        shellContext: shellContext,
        onNavigateTo: onNavigateTo,
        onToggleTheme: onToggleTheme,
        onSetThemeMode: onSetThemeMode,
        onOpenAbout: onOpenAbout,
        onOpenExternal: onOpenExternal,
        onLogout: onLogout,
        onOpenArchivedSpaces: onOpenArchivedSpaces,
        compact: compact,
      );
}

/// Compact Icon Rail when shell is collapsed or on tablet.
class AppIconRail extends StatelessWidget {
  const AppIconRail({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    required this.onOpenDrawer,
    this.onCreateSpace,
    this.onCreateThread,
    this.searchController,
    this.searchFocusNode,
    this.onSearchChanged,
    this.onClearSearch,
    this.onOpenCommandPalette,
    this.onOpenNotifications,
    this.onToggleTheme,
    this.onSetThemeMode,
    required this.onLogout,
    required this.onOpenAbout,
    required this.onOpenExternal,
    this.onOpenArchivedSpaces,
    this.onToggleCollapse,
  });

  final AxShellContext shellContext;
  final ValueChanged<AxNavigation> onNavigateTo;
  final VoidCallback onOpenDrawer;
  final VoidCallback? onCreateSpace;
  final ValueChanged<AxSpace>? onCreateThread;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onClearSearch;
  final VoidCallback? onOpenCommandPalette;
  final VoidCallback? onOpenNotifications;
  final VoidCallback? onToggleTheme;
  final ValueChanged<ThemeMode>? onSetThemeMode;
  final VoidCallback onLogout;
  final VoidCallback onOpenAbout;
  final ValueChanged<Uri> onOpenExternal;
  final VoidCallback? onOpenArchivedSpaces;
  final VoidCallback? onToggleCollapse;

  Widget _railIconButton({
    required bool isDark,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Widget? iconWidget,
  }) {
    return Semantics(
        label: tooltip,
        child: Tooltip(
          excludeFromSemantics: true,
          message: tooltip,
          child: IconButton(
            onPressed: onPressed,
            icon: iconWidget ??
                Icon(icon,
                    size: 20, color: SyntilaColors.navigationTextMuted(isDark)),
            splashRadius: 16,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            style: IconButton.styleFrom(
              hoverColor: SyntilaColors.navigationHover(isDark),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(SyntilaRadius.sm),
              ),
            ),
          ),
        ));
  }

  List<AxThread> _threads(AxSpace space) =>
      shellContext.spaceThreads?.peek(space.id) ??
      shellContext.threadsBySpace[space.id] ??
      const [];

  bool _unread(AxSpace space) =>
      space.hasUnread || _threads(space).any((thread) => thread.hasUnread);

  bool _running(AxSpace space) =>
      space.hasActiveWork ||
      _threads(space).any((thread) => thread.hasActiveWork);

  @override
  Widget build(BuildContext context) => TooltipVisibility(
        visible: false,
        child: SidebarPulse(child: Builder(builder: _buildContent)),
      );

  Widget _buildContent(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // The collapsed rail shares the sidebar's fixed dark navigation surface.
    final menuStyle = SyntilaMenuStyle.surface(isDark);

    ButtonStyle itemStyle() => SyntilaMenuStyle.item(isDark).copyWith(
          foregroundColor:
              WidgetStatePropertyAll(SyntilaColors.navigationText(isDark)),
          minimumSize: const WidgetStatePropertyAll(Size(200, 36)),
        );

    return Container(
      width: 50,
      color: SyntilaColors.navigationBackground(isDark),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
      child: Column(
        children: [
          // Logo navigates to Home
          Semantics(
              label: 'Syntila — Home',
              child: Tooltip(
                excludeFromSemantics: true,
                message: 'Syntila — Home',
                child: InkWell(
                  onTap: () => onNavigateTo(const AxNavigation.home()),
                  borderRadius: BorderRadius.circular(SyntilaRadius.sm),
                  hoverColor: SyntilaColors.navigationHover(isDark),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: SyntilaBrand.logoMark(size: 28),
                  ),
                ),
              )),
          if (onToggleCollapse != null) ...[
            const SizedBox(height: 6),
            _railIconButton(
              isDark: isDark,
              icon: Icons.menu_open_rounded,
              iconWidget: Transform.flip(
                flipX: true,
                child: Icon(
                  Icons.menu_open_rounded,
                  size: 20,
                  color: SyntilaColors.navigationTextMuted(isDark),
                ),
              ),
              tooltip: 'Expand sidebar',
              onPressed: onToggleCollapse,
            ),
          ],
          const SizedBox(height: 10),

          // Search popup control that opens an input popup and closes on focus loss
          _RailSearchMenuAnchor(
            menuStyle: menuStyle,
            searchController: searchController,
            searchFocusNode: searchFocusNode,
            onSearchChanged: onSearchChanged,
            onClearSearch: onClearSearch,
            onNavigateTo: onNavigateTo,
            isDark: isDark,
          ),
          const SizedBox(height: 6),

          // Add Space icon
          if (onCreateSpace != null) ...[
            _railIconButton(
              isDark: isDark,
              icon: Icons.add_rounded,
              tooltip: 'Add Space',
              onPressed: onCreateSpace,
            ),
            const SizedBox(height: 6),
          ],

          // Notifications Alarm icon
          shellContext.watchNotifications(() {
            final count = shellContext.unreadNotificationCount;
            return _railIconButton(
              isDark: isDark,
              icon: Icons.notifications_outlined,
              tooltip: 'Notifications',
              onPressed: onOpenNotifications,
              iconWidget: count > 0
                  ? Badge.count(
                      count: count,
                      backgroundColor: SyntilaColors.primary,
                      textColor: Colors.white,
                      child: Icon(
                        Icons.notifications_outlined,
                        size: 20,
                        color: SyntilaColors.navigationTextMuted(isDark),
                      ),
                    )
                  : Icon(
                      Icons.notifications_outlined,
                      size: 20,
                      color: SyntilaColors.navigationTextMuted(isDark),
                    ),
            );
          }),
          const SizedBox(height: 6),

          // Space & Thread Switcher MenuAnchor using matching popup style
          shellContext.watchSpacesAndThreads(() {
            // Own and shared Spaces get separate rail icons, each listing its
            // pinned Spaces first, mirroring the expanded sidebar's groups.
            List<AxSpace> group(List<AxSpace> spaces) => [
                  ...spaces.where((space) => space.isPinned).toList()
                    ..sort(compareAxPins),
                  ...spaces.where((space) => !space.isPinned),
                ];
            final owned = group(shellContext.ownedSpaces);
            final shared = group(shellContext.sharedSpaces);
            Widget spaceMenu(List<AxSpace> spaces,
                    {required IconData icon,
                    required String tooltip,
                    required String key}) =>
                MenuAnchor(
                  style: menuStyle,
                  builder: (context, controller, child) {
                    return _railIconButton(
                      isDark: isDark,
                      icon: icon,
                      iconWidget: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Icon(icon,
                              size: 20,
                              color: SyntilaColors.navigationTextMuted(isDark)),
                          Positioned(
                            right: -5,
                            top: -5,
                            child: SidebarActivityIndicators(
                              key: ValueKey(key),
                              running: spaces.any(_running),
                              unread: spaces.any(_unread),
                              gap: 2,
                            ),
                          ),
                        ],
                      ),
                      tooltip: tooltip,
                      onPressed: () {
                        if (controller.isOpen) {
                          controller.close();
                        } else {
                          controller.open();
                        }
                      },
                    );
                  },
                  menuChildren: [
                    for (final space in spaces) ...[
                      MenuItemButton(
                        style: itemStyle(),
                        trailingIcon: SidebarActivityIndicators(
                          key: ValueKey('rail-space-activity-${space.id}'),
                          running: _running(space),
                          unread: _unread(space),
                        ),
                        leadingIcon: SyntilaFolderIcon(
                          isExpanded: true,
                          size: 16,
                          color: SyntilaColors.navigationTextMuted(isDark),
                        ),
                        onPressed: () =>
                            onNavigateTo(AxNavigation.space(space.id)),
                        child: Text(
                          space.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: shellContext
                                    .isNavActive(AxNavigation.space(space.id))
                                ? FontWeight.bold
                                : FontWeight.w600,
                            color: SyntilaColors.navigationTextMuted(isDark),
                          ),
                        ),
                      ),
                      for (final thread in applyAxThreadPins(
                              sortAxThreadsByLastUpdate(_threads(space)))
                          .where((thread) =>
                              !thread.archived &&
                              thread.status.toLowerCase() != 'archived'))
                        MenuItemButton(
                          style: itemStyle(),
                          trailingIcon: SidebarActivityIndicators(
                            key: ValueKey('rail-thread-activity-${thread.id}'),
                            running: thread.hasActiveWork,
                            unread: thread.hasUnread,
                          ),
                          onPressed: () => onNavigateTo(
                              AxNavigation.thread(space.id, thread.id)),
                          child: Padding(
                            padding: const EdgeInsets.only(left: 24),
                            child: Text(
                              thread.title,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: shellContext.isNavActive(
                                        AxNavigation.thread(
                                            space.id, thread.id))
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color:
                                    SyntilaColors.navigationTextMuted(isDark),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ],
                );
            return Column(mainAxisSize: MainAxisSize.min, children: [
              if (owned.isNotEmpty)
                spaceMenu(owned,
                    icon: Icons.folder_outlined,
                    tooltip: 'Your spaces',
                    key: 'rail-activity-spaces'),
              if (shared.isNotEmpty)
                spaceMenu(shared,
                    icon: Icons.folder_shared_outlined,
                    tooltip: 'Shared with you',
                    key: 'rail-activity-shared-spaces'),
            ]);
          }),

          const Spacer(),

          // Application menu icon above user avatar
          GlobalAppMenu(
            shellContext: shellContext,
            onNavigateTo: onNavigateTo,
            onToggleTheme: onToggleTheme,
            onSetThemeMode: onSetThemeMode,
            onOpenAbout: onOpenAbout,
            onOpenExternal: onOpenExternal,
            onLogout: onLogout,
            onOpenArchivedSpaces: onOpenArchivedSpaces,
          ),
          const SizedBox(height: 8),

          // User Profile & Security avatar
          Tooltip(
            message: shellContext.viewerDisplayName ??
                shellContext.viewerEmail ??
                'Profile & Security',
            child: InkWell(
              onTap: () => onNavigateTo(const AxNavigation.profileSecurity()),
              borderRadius: BorderRadius.circular(13),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: shellContext
                          .isNavActive(const AxNavigation.profileSecurity())
                      ? Border.all(
                          color: SyntilaColors.primaryForeground(isDark),
                          width: 2)
                      : null,
                ),
                child: CircleAvatar(
                  radius: 13,
                  backgroundColor: SyntilaColors.primarySoft,
                  backgroundImage: shellContext.viewerAvatarImage,
                  child: shellContext.viewerAvatarImage == null
                      ? Text(
                          shellContext.viewerInitials,
                          style: const TextStyle(
                            fontSize: 11,
                            color: SyntilaColors.primaryPressed,
                            fontWeight: FontWeight.bold,
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Popover Search field anchored to the Search icon button in collapsed rail.
class _RailSearchMenuAnchor extends StatefulWidget {
  const _RailSearchMenuAnchor({
    required this.menuStyle,
    required this.searchController,
    required this.searchFocusNode,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onNavigateTo,
    required this.isDark,
  });

  final MenuStyle menuStyle;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onClearSearch;
  final ValueChanged<AxNavigation> onNavigateTo;
  final bool isDark;

  @override
  State<_RailSearchMenuAnchor> createState() => _RailSearchMenuAnchorState();
}

class _RailSearchMenuAnchorState extends State<_RailSearchMenuAnchor> {
  final MenuController _menuController = MenuController();
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _ownsController = false;
  bool _ownsFocusNode = false;

  @override
  void initState() {
    super.initState();
    if (widget.searchController != null) {
      _controller = widget.searchController!;
    } else {
      _controller = TextEditingController();
      _ownsController = true;
    }
    if (widget.searchFocusNode != null) {
      _focusNode = widget.searchFocusNode!;
    } else {
      _focusNode = FocusNode();
      _ownsFocusNode = true;
    }
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  void _openSearchMenu() {
    if (_menuController.isOpen) {
      _menuController.close();
    } else {
      _menuController.open();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  void _handleClearAndClose() {
    _controller.clear();
    widget.onSearchChanged?.call('');
    widget.onClearSearch?.call();
    _menuController.close();
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _menuController,
      style: widget.menuStyle,
      builder: (context, controller, child) {
        return Semantics(
            label: 'Search...',
            child: Tooltip(
              excludeFromSemantics: true,
              message: 'Search...',
              child: IconButton(
                onPressed: _openSearchMenu,
                icon: Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: SyntilaColors.navigationTextMuted(widget.isDark),
                ),
                splashRadius: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                style: IconButton.styleFrom(
                  hoverColor: SyntilaColors.navigationHover(widget.isDark),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(SyntilaRadius.sm),
                  ),
                ),
              ),
            ));
      },
      menuChildren: [
        Container(
          width: 260,
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 36,
                decoration: BoxDecoration(
                  color: SyntilaColors.canvas(widget.isDark),
                  borderRadius: BorderRadius.circular(SyntilaRadius.sm),
                  border: Border.all(
                    color: SyntilaColors.border(widget.isDark),
                  ),
                ),
                child: ListenableBuilder(
                  listenable: _controller,
                  builder: (context, _) {
                    final hasText = _controller.text.isNotEmpty;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 8, right: 4),
                          child: Icon(
                            Icons.search_rounded,
                            size: 16,
                            color: SyntilaColors.textSecondary(widget.isDark),
                          ),
                        ),
                        Expanded(
                          child: CallbackShortcuts(
                            bindings: {
                              const SingleActivator(LogicalKeyboardKey.escape):
                                  _handleClearAndClose,
                            },
                            child: TextField(
                              controller: _controller,
                              focusNode: _focusNode,
                              onChanged: widget.onSearchChanged,
                              onSubmitted: (text) {
                                widget
                                    .onNavigateTo(const AxNavigation.search());
                                _menuController.close();
                              },
                              style: TextStyle(
                                fontSize: 12,
                                color: SyntilaColors.textPrimary(widget.isDark),
                              ),
                              cursorColor: SyntilaBrand.accent,
                              cursorHeight: 14,
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: Colors.transparent,
                                hoverColor: Colors.transparent,
                                focusColor: Colors.transparent,
                                hintText: 'Search or jump to...',
                                hintStyle: TextStyle(
                                  fontSize: 12,
                                  color: SyntilaColors.textSecondary(
                                      widget.isDark),
                                ),
                                isDense: true,
                                contentPadding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                border: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                errorBorder: InputBorder.none,
                                disabledBorder: InputBorder.none,
                              ),
                            ),
                          ),
                        ),
                        if (hasText)
                          Semantics(
                              label: 'Clear and close',
                              child: Tooltip(
                                  message: 'Clear and close',
                                  excludeFromSemantics: true,
                                  child: IconButton(
                                    onPressed: _handleClearAndClose,
                                    icon: Icon(
                                      Icons.close_rounded,
                                      size: 14,
                                      color: SyntilaColors.textSecondary(
                                          widget.isDark),
                                    ),
                                    splashRadius: 14,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4),
                                    constraints: const BoxConstraints(
                                        minWidth: 24, minHeight: 24),
                                  ))),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
