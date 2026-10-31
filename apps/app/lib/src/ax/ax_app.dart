import '../features/profile/account_plan.dart';
import '../features/profile/read_receipt_privacy.dart';
import '../features/people/people_page.dart';
import '../features/notes/notes_page.dart';
import '../features/files/files_page.dart';
import '../features/common/quiet_notices.dart';
import '../features/common/thread_dialogs.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import '../navigation/ax_browser_navigation.dart';
import '../navigation/ax_navigation.dart';
import '../notifications/browser_alerts.dart';
import '../notifications/notification_models.dart';
import '../platform/platform_services.dart';
import '../platform/theme_preference.dart';
import '../platform/view_preferences.dart';
import '../features/settings/settings_page.dart';
import '../realtime/realtime_client.dart';
import '../brand.dart';
import '../features/common/toast_overlay.dart';
import '../features/common/diff_viewer.dart';
import '../features/execution/task_pipeline_dag.dart';
import '../features/home/home_page.dart';
import '../features/invitations/invitation_card.dart';
import '../features/navigation/ax_shell_context.dart';
import '../features/navigation/ax_sidebar.dart';
import '../features/common/space_color.dart';
import '../features/navigation/resizable_sidebar.dart';
import '../features/navigation/ax_top_bar.dart';
import '../features/spaces/spaces_pages.dart';
import '../features/spaces/archived_spaces_page.dart';
import '../features/search/search_page.dart';
import '../features/workspace/workspaces_page.dart';
import 'ax_models.dart';
import 'account_dialogs.dart';
import 'account_session_label.dart';
import 'ax_data.dart';
import 'ax_render_diagnostics.dart';
import 'avatar_file_picker_stub.dart'
    if (dart.library.html) 'avatar_file_picker_web.dart';
import 'ax_stores.dart';
import 'sync/ax_query_builder.dart';
import 'sync/ax_space_threads.dart';
import 'sync/ax_workflow_configurations.dart';
import 'sync/ax_sync_scope.dart';

part 'ax_app_state.dart';
part 'ax_app_shell_views.dart';
part 'ax_app_views.dart';
part 'ax_app_run_details.dart';
part 'ax_app_controller.dart';

class SyntilaAppShell extends StatefulWidget {
  const SyntilaAppShell(
      {super.key,
      required this.services,
      required this.dataSource,
      this.initialUri,
      this.browserNavigation,
      this.realtimeClient,
      this.themePreference,
      this.viewPreferencesStore});
  final ThemePreference? themePreference;
  final ViewPreferencesStore? viewPreferencesStore;
  final PlatformServices services;
  final AxDataSource dataSource;
  final Uri? initialUri;
  final AxBrowserNavigation? browserNavigation;
  final RealtimeClient? realtimeClient;
  @override
  State<SyntilaAppShell> createState() => _AxAppState();
}

class _RecoveryPanel extends StatelessWidget {
  const _RecoveryPanel({
    required this.icon,
    required this.title,
    required this.happened,
    required this.safe,
    required this.nextStep,
    required this.retrying,
    required this.onRetry,
  });
  final IconData icon;
  final String title;
  final String happened;
  final String safe;
  final String nextStep;
  final bool retrying;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 42, color: colors.error),
              const SizedBox(height: 16),
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 18),
              _RecoveryLine(label: 'What happened', value: happened),
              const SizedBox(height: 10),
              _RecoveryLine(label: 'Is my work safe?', value: safe),
              const SizedBox(height: 10),
              _RecoveryLine(label: 'What can I do?', value: nextStep),
              const SizedBox(height: 22),
              Wrap(spacing: 12, runSpacing: 8, children: [
                FilledButton.icon(
                  onPressed: retrying ? null : onRetry,
                  icon: retrying
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(retrying ? 'Retrying…' : 'Try again'),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy error'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(
                        text: '$title\n$happened\n$safe\n$nextStep'));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showNotice(
                          const SnackBar(content: Text('Error copied')));
                    }
                  },
                )
              ]),
              const SizedBox(height: 8),
              Text(
                retrying
                    ? 'Syntila is retrying automatically.'
                    : 'If an active run exists, Syntila will keep checking for updates.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecoveryLine extends StatelessWidget {
  const _RecoveryLine({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label: $value',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          SelectableText(value),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
