import 'package:flutter/material.dart';

import '../../brand.dart';
import '../common/external_links.dart';
import '../../navigation/ax_navigation.dart';
import 'ax_shell_context.dart';

/// Global application menu anchor (⋯) providing destinations, preferences,
/// product information, and session logout.
class GlobalAppMenu extends StatelessWidget {
  const GlobalAppMenu({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    this.onToggleTheme,
    this.onSetThemeMode,
    required this.onOpenAbout,
    required this.onOpenExternal,
    required this.onLogout,
    this.onOpenArchivedSpaces,
    this.onMessageSupport,
    this.compact = false,
    this.buttonConstraints = const BoxConstraints(minWidth: 28, minHeight: 28),
    this.iconSize = 18,
  });

  final AxShellContext shellContext;
  final ValueChanged<AxNavigation> onNavigateTo;
  final VoidCallback? onToggleTheme;
  final ValueChanged<ThemeMode>? onSetThemeMode;
  final VoidCallback onOpenAbout;
  final ValueChanged<Uri> onOpenExternal;
  final VoidCallback onLogout;
  final VoidCallback? onOpenArchivedSpaces;

  /// Opens the personal support Space; the item is omitted when null.
  final VoidCallback? onMessageSupport;
  final bool compact;
  final BoxConstraints buttonConstraints;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final menuStyle = SyntilaMenuStyle.surface(isDark);
    ButtonStyle itemStyle({bool isDestructive = false}) =>
        SyntilaMenuStyle.item(isDark, isDestructive: isDestructive).copyWith(
          foregroundColor:
              WidgetStatePropertyAll(SyntilaColors.navigationText(isDark)),
        );

    Widget divider() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: Divider(
            height: 1,
            thickness: 1,
            color: SyntilaColors.navigationBorder(isDark),
          ),
        );

    final menuIconColor = SyntilaColors.textPrimary(isDark);

    return MenuAnchor(
      style: menuStyle,
      builder: (context, controller, child) {
        return Semantics(
            label: 'Application menu',
            child: Tooltip(
                message: 'Application menu',
                excludeFromSemantics: true,
                child: IconButton(
                  icon: Icon(
                    Icons.menu_rounded,
                    color: SyntilaColors.navigationTextMuted(
                        Theme.of(context).brightness == Brightness.dark),
                    size: iconSize,
                  ),
                  splashRadius: 14,
                  padding: EdgeInsets.zero,
                  constraints: buttonConstraints,
                  onPressed: () {
                    if (controller.isOpen) {
                      controller.close();
                    } else {
                      controller.open();
                    }
                  },
                )));
      },
      menuChildren: [
        // 1. Application destinations
        MenuItemButton(
            style: itemStyle(),
            leadingIcon:
                Icon(Icons.people_outline, size: 16, color: menuIconColor),
            onPressed: () {
              onNavigateTo(const AxNavigation.people());
              if (compact) Scaffold.maybeOf(context)?.closeDrawer();
            },
            child: const Text('People',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500))),
        MenuItemButton(
            key: const ValueKey('menu-my-files'),
            style: itemStyle(),
            leadingIcon:
                Icon(Icons.folder_outlined, size: 16, color: menuIconColor),
            onPressed: () {
              onNavigateTo(const AxNavigation.files());
              if (compact) Scaffold.maybeOf(context)?.closeDrawer();
            },
            child: const Text('My Files',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500))),
        MenuItemButton(
            key: const ValueKey('menu-my-notes'),
            style: itemStyle(),
            leadingIcon: Icon(Icons.sticky_note_2_outlined,
                size: 16, color: menuIconColor),
            onPressed: () {
              onNavigateTo(const AxNavigation.notes());
              if (compact) Scaffold.maybeOf(context)?.closeDrawer();
            },
            child: const Text('My Notes',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500))),
        MenuItemButton(
          style: itemStyle(),
          leadingIcon: Icon(
            Icons.grid_view_rounded,
            size: 16,
            color: menuIconColor,
          ),
          onPressed: () {
            onNavigateTo(const AxNavigation.workspaces());
            if (compact) Scaffold.maybeOf(context)?.closeDrawer();
          },
          child: const Text(
            'Workspaces',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        MenuItemButton(
          style: itemStyle(),
          leadingIcon: Icon(
            Icons.archive_outlined,
            size: 16,
            color: menuIconColor,
          ),
          onPressed: () {
            onOpenArchivedSpaces?.call();
            if (compact) Scaffold.maybeOf(context)?.closeDrawer();
          },
          child: const Text(
            'Archived Spaces',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        MenuItemButton(
          key: const ValueKey('menu-settings'),
          style: itemStyle(),
          leadingIcon: Icon(Icons.tune_rounded, size: 16, color: menuIconColor),
          onPressed: () {
            onNavigateTo(const AxNavigation.settings());
            if (compact) Scaffold.maybeOf(context)?.closeDrawer();
          },
          child: const Text('Settings',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
        ),
        divider(),

        // 2. Help and product information
        MenuItemButton(
          style: itemStyle(),
          leadingIcon: Icon(
            Icons.menu_book_rounded,
            size: 16,
            color: menuIconColor,
          ),
          onPressed: () => onOpenExternal(Uri.parse(syntilaDocumentationUrl)),
          child: const Text(
            'Documentation',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        if (onMessageSupport != null)
          MenuItemButton(
            key: const ValueKey('menu-message-syntila'),
            style: itemStyle(),
            leadingIcon: Icon(
              Icons.chat_bubble_outline_rounded,
              size: 16,
              color: menuIconColor,
            ),
            onPressed: () {
              onMessageSupport!();
              if (compact) Scaffold.maybeOf(context)?.closeDrawer();
            },
            child: const Text(
              'Message Syntila',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
            ),
          ),
        MenuItemButton(
          style: itemStyle(),
          leadingIcon: Icon(
            Icons.download_outlined,
            size: 16,
            color: menuIconColor,
          ),
          onPressed: () => onOpenExternal(Uri.parse(syntilaDownloadsUrl)),
          child: const Text(
            'Downloads',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        MenuItemButton(
          style: itemStyle(),
          leadingIcon: SyntilaBrand.logoMark(size: 16),
          onPressed: onOpenAbout,
          child: const Text(
            'About Syntila',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        divider(),
        MenuItemButton(
          style: itemStyle(isDestructive: true),
          leadingIcon: Icon(
            Icons.logout_rounded,
            size: 16,
            color: SyntilaColors.errorText(isDark),
          ),
          onPressed: onLogout,
          child: Text(
            'Log out',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: SyntilaColors.errorText(isDark),
            ),
          ),
        ),
      ],
    );
  }
}
