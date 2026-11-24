import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../navigation/ax_navigation.dart';
import '../../ax/ax_models.dart';
import 'ax_shell_context.dart';

/// Compact popover showing execution workspace statuses, ready worker counts,
/// and connection health.
class ExecutionStatusPopover extends StatelessWidget {
  const ExecutionStatusPopover({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
  });

  final AxShellContext shellContext;
  final ValueChanged<AxNavigation> onNavigateTo;

  @override
  Widget build(BuildContext context) =>
      shellContext.watchExecution(() => _body(context));

  Widget _body(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = isDark ? SyntilaBrand.darkLine : SyntilaBrand.lightLine;
    final cardBg = isDark ? SyntilaBrand.darkPaper : SyntilaBrand.lightPaper;
    final inkColor = isDark ? SyntilaBrand.darkInk : SyntilaBrand.lightInk;
    final mutedInk =
        isDark ? SyntilaBrand.darkInkMuted : SyntilaBrand.lightInkMuted;

    final workspaces = shellContext.workspaces;
    final onlineCount = shellContext.onlineWorkspaceCount;
    final totalCount = workspaces.length;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      shape: const RoundedRectangleBorder(),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      alignment: Alignment.topRight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 380,
          margin: const EdgeInsets.only(top: 52, right: 12),
          decoration: BoxDecoration(
            color: SyntilaMenuStyle.background(isDark),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: SyntilaColors.navigationBorder(isDark)),
            boxShadow: [
              BoxShadow(
                color: SyntilaMenuStyle.shadow(isDark),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
                child: Row(
                  children: [
                    const Icon(
                      Icons.bolt_rounded,
                      size: 18,
                      color: SyntilaBrand.accent,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Workers',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: inkColor,
                      ),
                    ),
                    const Spacer(),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: borderColor),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.circle,
                              size: 7,
                              color: shellContext.executionStatusTone
                                  .color(isDark),
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                '$onlineCount / $totalCount Online',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: mutedInk,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: () {
                        if (Navigator.of(context).canPop()) {
                          Navigator.of(context).pop();
                        }
                      },
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(Icons.close_rounded,
                            size: 18, color: mutedInk),
                      ),
                    ),
                  ],
                ),
              ),

              // Realtime degraded notice
              if (shellContext.realtimeStale) ...[
                Container(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: isDark
                        ? SyntilaBrand.warningWashDark
                        : SyntilaBrand.warningWash,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: SyntilaBrand.warning.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.sync_problem_rounded,
                        size: 15,
                        color: SyntilaBrand.warning,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          shellContext.realtimeNotice ??
                              'Live connection degraded. Reconnecting...',
                          style: const TextStyle(
                            fontSize: 12,
                            color: SyntilaBrand.warning,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              Divider(height: 1, color: borderColor),

              // Workspace List
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: workspaces.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 32, horizontal: 16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.devices_outlined,
                                size: 32,
                                color: mutedInk,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'No Workers connected.',
                                style: TextStyle(fontSize: 13, color: mutedInk),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(
                              vertical: 8, horizontal: 10),
                          itemCount: workspaces.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 4),
                          itemBuilder: (context, index) {
                            final ws = workspaces[index];
                            return _buildWorkspaceRow(
                              ws: ws,
                              isDark: isDark,
                              inkColor: inkColor,
                              mutedInk: mutedInk,
                              cardBg: cardBg,
                              borderColor: borderColor,
                            );
                          },
                        ),
                ),
              ),

              Divider(height: 1, color: borderColor),

              // Footer
              InkWell(
                onTap: () {
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                  onNavigateTo(const AxNavigation.workspaces());
                },
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(12),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Manage Workers',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: SyntilaBrand.accent,
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_rounded,
                        size: 15,
                        color: SyntilaBrand.accent,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWorkspaceRow({
    required AxWorkspace ws,
    required bool isDark,
    required Color inkColor,
    required Color mutedInk,
    required Color cardBg,
    required Color borderColor,
  }) {
    final statusLower = ws.status.toLowerCase();
    final isOnline = statusLower == 'online';
    final isDegraded =
        statusLower == 'degraded' || statusLower == 'reconnecting';
    final dotColor = isOnline
        ? SyntilaBrand.success
        : isDegraded
            ? SyntilaBrand.warning
            : SyntilaColors.neutral;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Icon(Icons.circle, size: 8, color: dotColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ws.name,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: inkColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isOnline
                      ? 'Online'
                      : isDegraded
                          ? 'Degraded'
                          : 'Offline',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: isOnline
                        ? SyntilaBrand.success
                        : isDegraded
                            ? SyntilaBrand.warning
                            : mutedInk,
                  ),
                ),
                if (isOnline && ws.workerCount > 0) ...[
                  const SizedBox(height: 2),
                  Text(
                    '${ws.workerCount} Workers ready',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: mutedInk,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
