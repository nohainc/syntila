import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';
import 'package:syntila_workspace_gui/src/status_page.dart';
import 'package:syntila_workspace_gui/src/syntila_themes.dart';

/// Runs only with SYNTILA_CLI pointing at a built `syntila` binary.
void main() {
  final cli = Platform.environment['SYNTILA_CLI'];

  testWidgets('renders the real syntila manifest', (tester) async {
    final runner = ProcessCliRunner(cli!);
    final manifest = await tester.runAsync(runner.loadManifest);
    expect(manifest!.cli.name, 'syntila');

    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Start in the real zone so process futures created by the shell
    // complete (they never do inside the fake-async test zone).
    await tester.runAsync(
      () => tester.pumpWidget(
        MaterialApp(
          theme: syntilaLightTheme(),
          home: GuiManifestShell(
            runner: runner,
            title: 'Syntila Workspace',
            commandPages: {
              'status': (context, command, runner) =>
                  StatusPage(runner: runner),
            },
          ),
        ),
      ),
    );

    // Real processes finish outside fake time; poll until the Status page
    // shows either live cards or the service-down state.
    final ran = find.byWidgetPredicate(
      (w) =>
          w is Text &&
          (w.data == 'Cloud' ||
              w.data == 'The Workspace service is not available.'),
    );
    for (var i = 0; i < 100 && ran.evaluate().isEmpty; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
    }
    for (final label in [
      'Status',
      'Workers',
      'Folders',
      'Assignments',
      'Logs',
      'Service',
      'WORKSPACE',
      'ACCOUNT & CLOUD',
      'DIAGNOSTICS',
      'Config',
    ]) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    final workspaceY = tester.getTopLeft(find.text('WORKSPACE')).dy;
    final accountY = tester.getTopLeft(find.text('ACCOUNT & CLOUD')).dy;
    final diagnosticsY = tester.getTopLeft(find.text('DIAGNOSTICS')).dy;
    expect(workspaceY, lessThan(accountY));
    expect(accountY, lessThan(diagnosticsY));
    expect(diagnosticsY, lessThan(tester.getTopLeft(find.text('Logs')).dy));
    expect(find.text('Config'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Config')).dy, greaterThan(workspaceY));
    expect(tester.getTopLeft(find.text('Config')).dy, lessThan(accountY));
    expect(tester.getTopLeft(find.text('Slots')).dy, greaterThan(diagnosticsY));
    await tester.runAsync(() async {
      await tester.tap(find.text('Config'));
      await tester.pump();
    });
    for (final label in ['Create config', 'Validate config', 'Config path']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    // A group is one expandable row: its commands show after expanding it.
    expect(find.text('Add Worker'), findsNothing);
    await tester.runAsync(() async {
      // The Status page has a "Workers" card too, so address the sidebar row.
      await tester.tap(find.byKey(const ValueKey('sidebar-row-nav:workers')));
      await tester.pump();
    });
    expect(find.text('Add Worker'), findsOneWidget);
    expect(find.text('Catalog'), findsNothing);
    expect(find.text('Worker catalog'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sidebar-row-cmd:workers.remove')),
        matching: find.byType(Icon),
      ),
      findsNothing,
    );

    // Generated pages still work: open Logs and run it.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sidebar-row-cmd:logs')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Run'));
      await tester.pump();
    });
    final logs = find.textContaining(' syntila logs');
    for (var i = 0; i < 100 && logs.evaluate().length < 2; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
    }
    expect(find.textContaining('Failed (exit'), findsOneWidget);
    expect(find.textContaining(r'$ syntila logs'), findsWidgets);

    // Login presents a password field without invoking the CLI or a network call.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('sidebar-row-cmd:login')));
      await tester.pump();
    });
    expect(find.widgetWithText(TextField, 'Email'), findsOneWidget);
    final password = find.widgetWithText(TextField, 'Password *');
    expect(password, findsOneWidget);
    expect(tester.widget<TextField>(password).obscureText, isTrue);
  }, skip: cli == null);
}
