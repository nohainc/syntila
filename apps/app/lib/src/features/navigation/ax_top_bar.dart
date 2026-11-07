import 'app_top_hud.dart';

export 'app_top_hud.dart';
export 'breadcrumb.dart';
export 'execution_health.dart';

/// Backward-compatible subclass of [AppTopHud].
class AxTopBar extends AppTopHud {
  const AxTopBar({
    super.key,
    required super.shellContext,
    required super.onNavigateTo,
    required super.onOpenCommandPalette,
    required super.onOpenNotifications,
    super.searchController,
    super.searchFocusNode,
    super.onSearchChanged,
    super.onClearSearch,
    super.onToggleTheme,
    super.onSetThemeMode,
    super.onOpenArchivedSpaces,
    super.onMessageSupport,
    super.onOpenAbout,
    super.onLogout,
    super.onOpenExternal,
    super.compact = false,
    super.onCreateSpace,
  });
}
