import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../brand.dart';
import '../../navigation/ax_navigation.dart';
import 'breadcrumb.dart';
import 'execution_health.dart';
import 'app_menu.dart';
import 'ax_shell_context.dart';

/// Canonical Top Application Header Bar (HUD) for Syntila.
class AppTopHud extends StatefulWidget implements PreferredSizeWidget {
  const AppTopHud({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    required this.onOpenCommandPalette,
    required this.onOpenNotifications,
    this.searchController,
    this.searchFocusNode,
    this.onSearchChanged,
    this.onClearSearch,
    this.onToggleTheme,
    this.onSetThemeMode,
    this.onOpenArchivedSpaces,
    this.onOpenAbout,
    this.onLogout,
    this.onOpenExternal,
    this.compact = false,
    this.onCreateSpace,
  });

  final AxShellContext shellContext;
  final ValueChanged<AxNavigation> onNavigateTo;
  final VoidCallback onOpenCommandPalette;
  final VoidCallback onOpenNotifications;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onClearSearch;
  final VoidCallback? onToggleTheme;
  final ValueChanged<ThemeMode>? onSetThemeMode;
  final VoidCallback? onOpenArchivedSpaces;
  final VoidCallback? onOpenAbout;
  final VoidCallback? onLogout;
  final ValueChanged<Uri>? onOpenExternal;
  final bool compact;
  final VoidCallback? onCreateSpace;

  @override
  Size get preferredSize => const Size.fromHeight(60);

  @override
  State<AppTopHud> createState() => _AppTopHudState();
}

class _AppTopHudState extends State<AppTopHud> {
  bool _isSearchExpanded = false;
  final TextEditingController _fallbackController = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.searchFocusNode?.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(AppTopHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchFocusNode != widget.searchFocusNode) {
      oldWidget.searchFocusNode?.removeListener(_onFocusChange);
      widget.searchFocusNode?.addListener(_onFocusChange);
    }
    if (widget.shellContext.navigation.kind != AxRouteKind.search) {
      if (_isSearchExpanded) {
        _isSearchExpanded = false;
      }
    }
  }

  void _onFocusChange() {
    if (widget.searchFocusNode != null && !widget.searchFocusNode!.hasFocus) {
      if (widget.shellContext.navigation.kind != AxRouteKind.search ||
          (widget.searchController?.text.isEmpty ?? true)) {
        if (_isSearchExpanded && mounted) {
          setState(() => _isSearchExpanded = false);
        }
      }
    }
  }

  @override
  void dispose() {
    widget.searchFocusNode?.removeListener(_onFocusChange);
    _fallbackController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = isDark ? SyntilaBrand.darkLine : SyntilaBrand.lightLine;
    final inkColor = isDark ? SyntilaBrand.darkInk : SyntilaBrand.lightInk;
    final mutedInk =
        isDark ? SyntilaBrand.darkInkMuted : SyntilaBrand.lightInkMuted;

    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = SyntilaBrand.isDesktop(screenWidth) && !widget.compact;

    final controller = widget.searchController ?? _fallbackController;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final isSearchRoute =
            widget.shellContext.navigation.kind == AxRouteKind.search;
        final showInlineSearch =
            _isSearchExpanded || (isSearchRoute && controller.text.isNotEmpty);

        return Container(
          height: 60,
          padding: EdgeInsets.symmetric(horizontal: widget.compact ? 12 : 24),
          decoration: BoxDecoration(
            color:
                isDark ? SyntilaBrand.darkSurface : SyntilaBrand.lightSurface,
            border: Border(bottom: BorderSide(color: borderColor)),
          ),
          child: IconButtonTheme(
            data: widget.compact
                ? IconButtonThemeData(
                    style: IconButton.styleFrom(
                    minimumSize: const Size(36, 40),
                    maximumSize: const Size(36, 40),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: SyntilaRadius.buttonShape,
                  ))
                : IconButtonTheme.of(context),
            child: Row(
              children: [
                if (widget.compact)
                  IconButton(
                    tooltip: 'Syntila — Spaces',
                    onPressed: () =>
                        widget.onNavigateTo(const AxNavigation.spaces()),
                    icon: SyntilaBrand.logoMark(size: 28),
                  ),
                if (widget.compact) const SizedBox(width: 8),

                // Route-Aware Breadcrumbs or Expanded Search Input
                if (showInlineSearch) ...[
                  Expanded(
                    child: Container(
                      height: 34,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: SyntilaColors.navigationRaised(isDark),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: SyntilaColors.navigationBorder(isDark),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 8, right: 6),
                            child: Icon(
                              Icons.search_rounded,
                              size: 16,
                              color: mutedInk,
                            ),
                          ),
                          Expanded(
                            child: CallbackShortcuts(
                              bindings: {
                                const SingleActivator(
                                    LogicalKeyboardKey.escape): () {
                                  widget.onClearSearch?.call();
                                  widget.searchController?.clear();
                                  setState(() => _isSearchExpanded = false);
                                  widget.searchFocusNode?.unfocus();
                                },
                              },
                              child: TextField(
                                controller: widget.searchController,
                                focusNode: widget.searchFocusNode,
                                onChanged: widget.onSearchChanged,
                                autofocus: true,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: inkColor,
                                ),
                                cursorColor: SyntilaBrand.accent,
                                cursorHeight: 14,
                                decoration: InputDecoration(
                                  filled: true,
                                  fillColor: Colors.transparent,
                                  hoverColor: Colors.transparent,
                                  focusColor: Colors.transparent,
                                  hintText: 'Search...',
                                  hintStyle: TextStyle(
                                    fontSize: 13,
                                    color: mutedInk,
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
                          InkWell(
                            onTap: () {
                              widget.onClearSearch?.call();
                              widget.searchController?.clear();
                              setState(() => _isSearchExpanded = false);
                              widget.searchFocusNode?.unfocus();
                            },
                            borderRadius: BorderRadius.circular(10),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 6),
                              child: Icon(
                                Icons.close_rounded,
                                size: 16,
                                color: mutedInk,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: AppBreadcrumb(
                      shellContext: widget.shellContext,
                      onNavigateTo: widget.onNavigateTo,
                      inkColor: inkColor,
                      mutedInk: mutedInk,
                      compact: widget.compact,
                    ),
                  ),

                  // Search affordance
                  if (isDesktop) ...[
                    InkWell(
                      onTap: widget.onOpenCommandPalette,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: isDark
                              ? SyntilaBrand.darkPaper
                              : SyntilaBrand.lightPaper,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: borderColor),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search_rounded,
                              size: 16,
                              color: mutedInk,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Search or jump to...',
                              style: TextStyle(
                                fontSize: 12,
                                color: mutedInk,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                  ] else ...[
                    IconButton(
                      icon:
                          Icon(Icons.search_rounded, size: 20, color: mutedInk),
                      tooltip: 'Search',
                      onPressed: () {
                        if (widget.searchController != null ||
                            widget.searchFocusNode != null) {
                          setState(() => _isSearchExpanded = true);
                          widget.searchFocusNode?.requestFocus();
                        } else {
                          widget.onOpenCommandPalette();
                        }
                      },
                      splashRadius: 20,
                    ),
                  ],
                ],

                // Operational Execution Status Popover Trigger (desktop/expanded only)
                if (!widget.compact) ...[
                  OutlinedButton.icon(
                    onPressed: () => _openExecutionStatusPopover(context),
                    icon: Icon(
                      Icons.circle,
                      size: 7,
                      color:
                          widget.shellContext.executionStatusTone.color(isDark),
                    ),
                    label: Text(
                      widget.shellContext.executionStatusLabel,
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: inkColor,
                      side: BorderSide(color: borderColor),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      minimumSize: Size.zero,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],

                if (widget.compact && widget.onCreateSpace != null)
                  IconButton(
                    tooltip: 'New Space',
                    onPressed: widget.onCreateSpace,
                    icon: Icon(Icons.add_rounded, size: 20, color: mutedInk),
                  ),
                // Notifications Bell
                widget.shellContext.watchNotifications(() => Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconButton(
                          tooltip: 'Notifications',
                          onPressed: widget.onOpenNotifications,
                          icon: Icon(Icons.notifications_none_rounded,
                              size: 20, color: mutedInk),
                          splashRadius: 20,
                        ),
                        if (widget.shellContext.unreadNotificationCount > 0)
                          Positioned(
                            right: 6,
                            top: 6,
                            child: Semantics(
                              label:
                                  '${widget.shellContext.unreadNotificationCount} unread notifications',
                              child: Container(
                                constraints: const BoxConstraints(
                                    minWidth: 16, minHeight: 16),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                decoration: const BoxDecoration(
                                  color: SyntilaBrand.accent,
                                  shape: BoxShape.circle,
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  widget.shellContext.unreadNotificationCount >
                                          9
                                      ? '9+'
                                      : '${widget.shellContext.unreadNotificationCount}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    )),
                if (widget.compact)
                  GlobalAppMenu(
                    shellContext: widget.shellContext,
                    buttonConstraints:
                        const BoxConstraints.tightFor(width: 36, height: 40),
                    iconSize: 20,
                    onNavigateTo: widget.onNavigateTo,
                    onToggleTheme: widget.onToggleTheme,
                    onSetThemeMode: widget.onSetThemeMode,
                    onOpenArchivedSpaces: widget.onOpenArchivedSpaces,
                    onOpenAbout: widget.onOpenAbout ?? () {},
                    onOpenExternal: widget.onOpenExternal ?? (_) {},
                    onLogout: widget.onLogout ?? () {},
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openExecutionStatusPopover(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black26,
      builder: (dialogContext) => ExecutionStatusPopover(
        shellContext: widget.shellContext,
        onNavigateTo: widget.onNavigateTo,
      ),
    );
  }
}
