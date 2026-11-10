import 'package:syntila_app/src/app_shell.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'package:syntila_app/src/platform/theme_preference.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ax_fixture_data.dart';
import 'ax_fixture_realtime.dart';

void main() {
  test('missing, invalid and unavailable storage fall back to System', () {
    for (final value in [null, '', 'invalid']) {
      expect(ThemePreference(read: () => value, write: (_) {}).load(),
          ThemeMode.system);
    }
    final unavailable = ThemePreference(
        read: () => throw StateError('unavailable'),
        write: (_) => throw StateError('unavailable'));
    expect(unavailable.load(), ThemeMode.system);
    expect(() => unavailable.save(ThemeMode.light), returnsNormally);
  });

  testWidgets('latest appearance choice survives shell recreation',
      (tester) async {
    String? stored;
    ThemePreference preference() =>
        ThemePreference(read: () => stored, write: (value) => stored = value);
    Future<void> mount() async {
      await tester.pumpWidget(SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: const AxFixtureDataSource(),
        realtimeClient: TestRealtime(),
        initialUri: Uri.parse('/settings'),
        themePreference: preference(),
      ));
      await tester.pumpAndSettle();
    }

    await mount();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.system);
    for (final mode in [ThemeMode.light, ThemeMode.dark, ThemeMode.system]) {
      await tester.tap(find.text(switch (mode) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'System',
      }));
      await tester.pumpAndSettle();
      expect(stored, mode.name);
      expect(
          tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, mode);
      await tester.pumpWidget(const SizedBox.shrink());
      await mount();
      expect(
          tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, mode);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
