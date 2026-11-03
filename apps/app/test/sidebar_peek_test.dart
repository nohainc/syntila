import 'package:syntila_app/src/app_shell.dart';
import 'package:syntila_app/src/features/navigation/ax_sidebar.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'package:syntila_app/src/platform/view_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ax_fixture_data.dart';

void main() {
  testWidgets(
      'collapsed sidebar opens on folder icon press and collapses on outside tap',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? stored = '{"sidebarCollapsed":true,"sidebarWidth":240}';
    final preferences = ViewPreferencesStore(
      read: () => stored,
      write: (value) => stored = value,
    );

    await tester.pumpWidget(SyntilaAppShell(
      services: const DefaultPlatformServices(),
      dataSource: const AxFixtureDataSource(),
      initialUri: Uri.parse('/'),
      viewPreferencesStore: preferences,
    ));
    await tester.pumpAndSettle();

    // Starts collapsed into rail
    expect(find.byType(AxIconRail), findsOneWidget);
    expect(find.byType(AxSidebar), findsNothing);
    expect(find.byTooltip('Shared with you'), findsNothing);

    // Tapping folder icon opens peeking sidebar
    await tester.tap(find.byTooltip('Your spaces'));
    await tester.pumpAndSettle();

    expect(find.byType(AxSidebar), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-peek-barrier')), findsOneWidget);

    // Clicking outside the sidebar on the barrier collapses it
    await tester.tap(find.byKey(const ValueKey('sidebar-peek-barrier')));
    await tester.pumpAndSettle();

    expect(find.byType(AxSidebar), findsNothing);
    expect(find.byKey(const ValueKey('sidebar-peek-barrier')), findsNothing);
  });

  testWidgets('peeking sidebar collapses when pressing Escape', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? stored = '{"sidebarCollapsed":true,"sidebarWidth":240}';
    final preferences = ViewPreferencesStore(
      read: () => stored,
      write: (value) => stored = value,
    );

    await tester.pumpWidget(SyntilaAppShell(
      services: const DefaultPlatformServices(),
      dataSource: const AxFixtureDataSource(),
      initialUri: Uri.parse('/'),
      viewPreferencesStore: preferences,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Your spaces'));
    await tester.pumpAndSettle();
    expect(find.byType(AxSidebar), findsOneWidget);

    // Press Escape
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(AxSidebar), findsNothing);
  });

  testWidgets(
      'peeking sidebar allows tree navigation and collapses after selecting a space/thread',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? stored = '{"sidebarCollapsed":true,"sidebarWidth":240}';
    final preferences = ViewPreferencesStore(
      read: () => stored,
      write: (value) => stored = value,
    );

    await tester.pumpWidget(SyntilaAppShell(
      services: const DefaultPlatformServices(),
      dataSource: const AxFixtureDataSource(),
      initialUri: Uri.parse('/'),
      viewPreferencesStore: preferences,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Your spaces'));
    await tester.pumpAndSettle();
    expect(find.byType(AxSidebar), findsOneWidget);

    // User can see spaces and threads in sidebar
    expect(find.byKey(const ValueKey('sidebar-space-row-space-auth')),
        findsOneWidget);

    // Selecting a space navigates and collapses the sidebar
    await tester
        .tap(find.byKey(const ValueKey('sidebar-space-row-space-auth')));
    await tester.pumpAndSettle();

    expect(find.byType(AxSidebar), findsNothing);
    expect(find.byType(AxIconRail), findsOneWidget);

    // Re-open peeking sidebar
    await tester.tap(find.byTooltip('Your spaces'));
    await tester.pumpAndSettle();
    expect(find.byType(AxSidebar), findsOneWidget);

    // Select a thread in the tree
    final threadFinder =
        find.byKey(const ValueKey('sidebar-thread-row-thread-auth'));
    expect(threadFinder, findsOneWidget);
    await tester.tap(threadFinder);
    await tester.pumpAndSettle();
    expect(find.byType(AxSidebar), findsNothing);
  });

  testWidgets('peeking sidebar collapses when tapping Hide sidebar button',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? stored = '{"sidebarCollapsed":true,"sidebarWidth":240}';
    final preferences = ViewPreferencesStore(
      read: () => stored,
      write: (value) => stored = value,
    );

    await tester.pumpWidget(SyntilaAppShell(
      services: const DefaultPlatformServices(),
      dataSource: const AxFixtureDataSource(),
      initialUri: Uri.parse('/'),
      viewPreferencesStore: preferences,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Your spaces'));
    await tester.pumpAndSettle();
    expect(find.byType(AxSidebar), findsOneWidget);

    // Tapping Hide sidebar in the peeking sidebar
    await tester.tap(find.byTooltip('Hide sidebar'));
    await tester.pumpAndSettle();

    expect(find.byType(AxSidebar), findsNothing);
    expect(find.byType(AxIconRail), findsOneWidget);
  });
}
