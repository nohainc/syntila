import 'app_sidebar.dart';

export 'app_menu.dart';
export 'app_sidebar.dart';
export 'space_tree.dart';

/// Backward-compatible subclass of [AppSidebar].
class AxSidebar extends AppSidebar {
  const AxSidebar({
    super.key,
    required super.shellContext,
    required super.onNavigateTo,
    super.onNavigateToRecentThread,
    super.onToggleSpaceExpanded,
    super.onCreateSpace,
    super.onCreateThread,
    super.onEditSpace,
    super.onArchiveSpace,
    super.onDeleteSpace,
    super.onRenameThread,
    super.onSetThreadArchived,
    super.onDeleteThread,
    super.onReorderThreads,
    super.onSetSpacePinned,
    super.onSetThreadPinned,
    super.onReorderPinnedSpaces,
    super.onReorderPinnedThreads,
    super.searchController,
    super.searchFocusNode,
    super.onSearchChanged,
    super.onClearSearch,
    super.onOpenCommandPalette,
    super.onOpenNotifications,
    super.onToggleTheme,
    super.onSetThemeMode,
    required super.onLogout,
    required super.onOpenAbout,
    required super.onOpenExternal,
    super.onOpenArchivedSpaces,
    super.onToggleCollapse,
    super.compact = false,
  });
}

/// Backward-compatible subclass of [AppIconRail].
class AxIconRail extends AppIconRail {
  const AxIconRail({
    super.key,
    required super.shellContext,
    required super.onNavigateTo,
    required super.onOpenDrawer,
    super.onCreateSpace,
    super.onCreateThread,
    super.searchController,
    super.searchFocusNode,
    super.onSearchChanged,
    super.onClearSearch,
    super.onOpenCommandPalette,
    super.onOpenNotifications,
    super.onToggleTheme,
    super.onSetThemeMode,
    required super.onLogout,
    required super.onOpenAbout,
    required super.onOpenExternal,
    super.onOpenArchivedSpaces,
    super.onToggleCollapse,
    super.sidebarWidth,
    super.onSidebarWidthChanged,
    super.onOpenSpaces,
  });
}
