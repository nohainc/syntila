import 'package:syntila_app/src/app_shell.dart';
import 'package:syntila_app/src/features/home/home_page.dart';
import 'package:syntila_app/src/features/people/people_page.dart';
import 'package:syntila_app/src/features/spaces/archived_spaces_page.dart';
import 'package:syntila_app/src/features/workspace/workspaces_page.dart';
import 'package:syntila_app/src/features/settings/settings_page.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ax_fixture_data.dart';

void main() {
  testWidgets('changing text size updates the page width immediately',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: const AxFixtureDataSource(),
        initialUri: Uri.parse('/settings'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(SettingsPage)).width, 500);
    await tester.tap(find.text('Large'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(SettingsPage)).width, 600);
    await tester.tap(find.text('Extra large'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(SettingsPage)).width, 700);
  });

  testWidgets('Workspaces uses the wider content limit', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: const AxFixtureDataSource(),
        initialUri: Uri.parse('/workspaces'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(WorkspacesPage)).width, 900);
    expect(tester.takeException(), isNull);
  });

  for (final width in [650.0, 1200.0, 1800.0]) {
    testWidgets('People and Archived Spaces match Home width at $width',
        (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Rect? homeBounds;
      for (final entry in <String, Type>{
        '/': HomePage,
        '/people': PeoplePage,
        '/archived-spaces': ArchivedSpacesPage,
      }.entries) {
        await tester.pumpWidget(MaterialApp(
          home: SyntilaAppShell(
            key: ValueKey(entry.key),
            services: const DefaultPlatformServices(),
            dataSource: const AxFixtureDataSource(),
            initialUri: Uri.parse(entry.key),
          ),
        ));
        await tester.pumpAndSettle();
        final bounds = tester.getRect(find.byType(entry.value));
        if (homeBounds == null) {
          homeBounds = bounds;
          if (width == 1800) expect(bounds.width, 500);
        } else {
          expect(bounds.left, closeTo(homeBounds.left, 0.1));
          expect(bounds.width, closeTo(homeBounds.width, 0.1));
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
