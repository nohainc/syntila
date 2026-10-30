import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../platform/view_preferences.dart';

/// Device-local view settings. Changes apply immediately.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.preferences,
    required this.onChanged,
  });

  final ViewPreferences preferences;
  final ValueChanged<ViewPreferences> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = SyntilaColors.navigationTextMuted(isDark);
    final showRecent = preferences.showRecentThreads;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Settings',
            style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w700,
                color: SyntilaColors.textPrimary(isDark))),
        const SizedBox(height: 4),
        Text('These preferences apply to this device.',
            style: TextStyle(fontSize: 12.5, color: muted)),
        const SizedBox(height: 24),
        Text('SIDEBAR',
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
                color: SyntilaColors.neutralText(isDark))),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const ValueKey('setting-show-recent-threads'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Show recent threads'),
          subtitle: Text(
              'List your most recently active threads at the top of the sidebar.',
              style: TextStyle(fontSize: 12, color: muted)),
          value: showRecent,
          onChanged: (value) =>
              onChanged(preferences.copyWith(showRecentThreads: value)),
        ),
        const SizedBox(height: 8),
        Opacity(
          opacity: showRecent ? 1 : 0.45,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Recent threads to show',
                        style: TextStyle(fontSize: 14)),
                    const SizedBox(height: 2),
                    Text('How many threads the section lists.',
                        style: TextStyle(fontSize: 12, color: muted)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              SegmentedButton<int>(
                key: const ValueKey('setting-recent-threads-count'),
                showSelectedIcon: false,
                segments: [
                  for (final count in ViewPreferences.recentThreadsCountOptions)
                    ButtonSegment(value: count, label: Text('$count')),
                ],
                selected: {preferences.recentThreadsCount},
                onSelectionChanged: showRecent
                    ? (selection) => onChanged(preferences.copyWith(
                        recentThreadsCount: selection.first))
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
