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
  final bool compact;
  final BoxConstraints buttonConstraints;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final activeThemeMode = shellContext.themeMode;
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
        divider(),

        // 2. Preferences
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
        SubmenuButton(
          style: itemStyle(),
          menuStyle: menuStyle,
          leadingIcon: Icon(
            Icons.contrast_rounded,
            size: 16,
            color: menuIconColor,
          ),
          menuChildren: [
            MenuItemButton(
              style: itemStyle(),
              leadingIcon: Icon(
                activeThemeMode == ThemeMode.system
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
                size: 15,
                color: activeThemeMode == ThemeMode.system
                    ? (SyntilaColors.textPrimary(isDark))
                    : (SyntilaColors.neutral),
              ),
              onPressed: () {
                if (onSetThemeMode != null) {
                  onSetThemeMode!(ThemeMode.system);
                } else {
                  onToggleTheme?.call();
                }
              },
              child: const Text(
                'System',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ),
            MenuItemButton(
              style: itemStyle(),
              leadingIcon: Icon(
                activeThemeMode == ThemeMode.light
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
                size: 15,
                color: activeThemeMode == ThemeMode.light
                    ? (SyntilaColors.textPrimary(isDark))
                    : (SyntilaColors.neutral),
              ),
              onPressed: () {
                if (onSetThemeMode != null) {
                  onSetThemeMode!(ThemeMode.light);
                } else if (shellContext.isDarkTheme) {
                  onToggleTheme?.call();
                }
              },
              child: const Text(
                'Light',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ),
            MenuItemButton(
              style: itemStyle(),
              leadingIcon: Icon(
                activeThemeMode == ThemeMode.dark
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
                size: 15,
                color: activeThemeMode == ThemeMode.dark
                    ? (SyntilaColors.textPrimary(isDark))
                    : (SyntilaColors.neutral),
              ),
              onPressed: () {
                if (onSetThemeMode != null) {
                  onSetThemeMode!(ThemeMode.dark);
                } else if (!shellContext.isDarkTheme) {
                  onToggleTheme?.call();
                }
              },
              child: const Text(
                'Dark',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ),
          ],
          child: const Text(
            'Appearance',
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
