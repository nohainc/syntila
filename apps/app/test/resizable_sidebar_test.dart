import 'package:syntila_app/src/app_shell.dart';
import 'package:syntila_app/src/features/navigation/ax_sidebar.dart';
import 'package:syntila_app/src/features/navigation/resizable_sidebar.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'package:syntila_app/src/platform/view_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ax_fixture_data.dart';

void main() {
  testWidgets('resize line is visible only while the mouse is over the handle',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ResizableSidebar(
          width: 180,
          onWidthChanged: (_) {},
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    ));
    expect(tester.getSize(find.byType(ResizableSidebar)).width, 200);
    final handle = find.byKey(const ValueKey('sidebar-resize-handle'));
    final line = find.byKey(const ValueKey('sidebar-resize-line'));
    Color? lineColor() => tester.widget<Container>(line).color;
    expect(lineColor(), Colors.transparent);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(400, 100));
    await mouse.moveTo(tester.getCenter(handle));
    await tester.pump();
    expect(lineColor(), Colors.white24);
    expect(
        find.descendant(
            of: find.byType(ResizableSidebar), matching: find.byType(Tooltip)),
        findsNothing);
    await mouse.down(tester.getCenter(handle));
    await mouse.up();
    await tester.pump();
    expect(lineColor(), Colors.white24);
    await mouse.moveTo(const Offset(400, 100));
    await tester.pump();
    expect(lineColor(), Colors.transparent);
    // Keyboard focus remains usable without keeping the line visible.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(lineColor(), Colors.transparent);
  });

  testWidgets('sidebar resizes within bounds and retains width after collapse',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(SyntilaAppShell(
      services: const DefaultPlatformServices(),
      dataSource: const AxFixtureDataSource(),
      initialUri: Uri.parse('/'),
    ));
    await tester.pumpAndSettle();
    final sidebar = find.byType(ResizableSidebar);
    final handle = find.byKey(const ValueKey('sidebar-resize-handle'));
    expect(tester.getSize(sidebar).width, 200);

    await tester.drag(handle, const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 200);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('New Space'), findsOneWidget);
    expect(find.byTooltip('Notifications'), findsOneWidget);
    expect(find.byTooltip('Application menu'), findsOneWidget);

    await tester.tap(handle);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 210);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 300);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 200);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 200);

    await tester.drag(handle, const Offset(30, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 230);
    await tester.tap(find.byTooltip('Hide sidebar'));
    await tester.pumpAndSettle();
    expect(sidebar, findsNothing);
    await tester.tap(find.byTooltip('Expand sidebar'));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 230);

    await tester.tap(find.byTooltip('Profile & Settings'));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 230);
    await tester.drag(handle, const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 300);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(400, 900);
    await tester.pumpAndSettle();
    expect(sidebar, findsNothing);
    expect(handle, findsNothing);
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pumpAndSettle();
    expect(find.byType(AxSidebar), findsOneWidget);
    expect(tester.getSize(sidebar).width, 300);
  });

  testWidgets('sidebar collapsed state and width survive shell recreation',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? stored;
    final preferences = ViewPreferencesStore(
      read: () => stored,
      write: (value) => stored = value,
    );

    Future<void> pumpShell(Key key) => tester.pumpWidget(SyntilaAppShell(
          key: key,
          services: const DefaultPlatformServices(),
          dataSource: const AxFixtureDataSource(),
          initialUri: Uri.parse('/'),
          viewPreferencesStore: preferences,
        ));

    await pumpShell(const ValueKey('first-shell'));
    await tester.pumpAndSettle();
    final handle = find.byKey(const ValueKey('sidebar-resize-handle'));
    await tester.drag(handle, const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ResizableSidebar)).width, 240);
    await tester.tap(find.byTooltip('Hide sidebar'));
    await tester.pumpAndSettle();
    expect(find.byType(ResizableSidebar), findsNothing);
    expect(preferences.load().sidebarCollapsed, isTrue);
    expect(preferences.load().sidebarWidth, 240);
    await tester.tap(find.byTooltip('Your spaces'));
    await tester.pumpAndSettle();
    expect(find.byType(AxSidebar), findsOneWidget);
    final peekHandle = find.byKey(const ValueKey('sidebar-resize-handle'));
    expect(peekHandle, findsOneWidget);
    await tester.drag(peekHandle, const Offset(30, 0));
    await tester.pumpAndSettle();
    expect(preferences.load().sidebarWidth, 270);
    // Tapping outside dismisses peeking sidebar
    await tester.tap(find.byKey(const ValueKey('sidebar-peek-barrier')));
    await tester.pumpAndSettle();
    expect(find.byType(AxSidebar), findsNothing);

    await pumpShell(const ValueKey('second-shell'));
    await tester.pumpAndSettle();
    expect(find.byType(ResizableSidebar), findsNothing);
    await tester.tap(find.byTooltip('Expand sidebar'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ResizableSidebar)).width, 270);
    expect(preferences.load().sidebarCollapsed, isFalse);
  });
}
