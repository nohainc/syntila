import 'package:flutter/material.dart';

import '../../navigation/ax_navigation.dart';
import 'ax_shell_context.dart';

/// Route-aware breadcrumb widget for Syntila HUD.
class AppBreadcrumb extends StatelessWidget {
  const AppBreadcrumb({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    required this.inkColor,
    required this.mutedInk,
    this.compact = false,
  });

  final AxShellContext shellContext;
  final ValueChanged<AxNavigation> onNavigateTo;
  final Color inkColor;
  final Color mutedInk;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final nav = shellContext.navigation;
    final space = shellContext.selectedSpace;
    final thread = shellContext.selectedThread;

    final children = switch (nav.kind) {
      AxRouteKind.home => [
          if (compact)
            _accountLink()
          else
            _breadcrumbText('Home', isCurrent: true),
        ],
      AxRouteKind.spaces => [
          if (compact)
            _accountLink()
          else
            _breadcrumbText('Spaces', isCurrent: true),
        ],
      AxRouteKind.space => [
          _breadcrumbText(space?.name ?? 'Space', isCurrent: true),
        ],
      AxRouteKind.spaceMembers => [
          if (space != null) ...[
            _breadcrumbLink(
              space.name,
              () => onNavigateTo(AxNavigation.space(space.id)),
            ),
            _divider(),
          ],
          _breadcrumbText('Members', isCurrent: true),
        ],
      AxRouteKind.thread => [
          if (space != null) ...[
            _breadcrumbLink(
              space.name,
              () => onNavigateTo(AxNavigation.space(space.id)),
            ),
            _divider(),
          ] else ...[
            _breadcrumbLink(
              'Home',
              () => onNavigateTo(const AxNavigation.home()),
            ),
            _divider(),
          ],
          _breadcrumbText(thread?.title ?? 'Thread', isCurrent: true),
        ],
      AxRouteKind.run => [
          if (space != null) ...[
            _breadcrumbLink(
              space.name,
              () => onNavigateTo(AxNavigation.space(space.id)),
            ),
            _divider(),
          ] else ...[
            _breadcrumbLink(
              'Spaces',
              () => onNavigateTo(const AxNavigation.spaces()),
            ),
            _divider(),
          ],
          if (nav.threadId != null && space != null) ...[
            _breadcrumbLink(
              thread?.title ?? 'Thread',
              () => onNavigateTo(AxNavigation.thread(space.id, nav.threadId!)),
            ),
            _divider(),
          ],
          _breadcrumbText('Run', isCurrent: true),
        ],
      AxRouteKind.people => [_breadcrumbText('People', isCurrent: true)],
      AxRouteKind.notes => [_breadcrumbText('My Notes', isCurrent: true)],
      AxRouteKind.files => [_breadcrumbText('My Files', isCurrent: true)],
      AxRouteKind.archivedSpaces => [
          _breadcrumbText('Archived Spaces', isCurrent: true)
        ],
      AxRouteKind.workspaces => nav.workspaceId != null
          ? [
              _breadcrumbLink(
                'Workspaces',
                () => onNavigateTo(const AxNavigation.workspaces()),
              ),
              _divider(),
              _breadcrumbText(
                shellContext.workspaces
                        .where((w) => w.id == nav.workspaceId)
                        .firstOrNull
                        ?.name ??
                    'Workspace',
                isCurrent: true,
              ),
            ]
          : [
              _breadcrumbText('Workspaces', isCurrent: true),
            ],
      AxRouteKind.profileSecurity => [
          _breadcrumbText(compact ? 'Profile' : 'Profile & Security',
              isCurrent: true),
        ],
      AxRouteKind.settings => [_breadcrumbText('Settings', isCurrent: true)],
      AxRouteKind.search => [
          _breadcrumbText('Search', isCurrent: true),
        ],
      AxRouteKind.login || AxRouteKind.desktopAuthApproval => [
          _breadcrumbText('Syntila', isCurrent: true),
        ],
    };

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  Widget _accountLink() => KeyedSubtree(
        key: const ValueKey('mobile-account-name'),
        child: _breadcrumbLink(
          shellContext.viewerDisplayName?.trim().isNotEmpty == true
              ? shellContext.viewerDisplayName!
              : shellContext.viewerEmail ?? 'Account',
          () => onNavigateTo(const AxNavigation.profileSecurity()),
          tooltip: 'Account',
          isCurrent: true,
        ),
      );

  Widget _breadcrumbText(String text, {required bool isCurrent}) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 14.5,
        fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
        color: inkColor,
      ),
    );
  }

  Widget _breadcrumbLink(String text, VoidCallback onTap,
      {String? tooltip, bool isCurrent = false}) {
    final link = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: isCurrent ? 14.5 : 14,
            fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
            color: isCurrent ? inkColor : mutedInk,
          ),
        ),
      ),
    );
    if (tooltip != null) {
      return Tooltip(message: tooltip, child: link);
    }
    return link;
  }

  Widget _divider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        '/',
        style: TextStyle(fontSize: 13, color: mutedInk),
      ),
    );
  }
}
