import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';
import 'package:syntila_design/syntila_design.dart';
import 'package:syntila_workspace_gui/src/status_page.dart';

/// Runs only with SYNTILA_CLI pointing at a built `syntila` binary.
void main() {
  final cli = Platform.environment['SYNTILA_CLI'];

  testWidgets('renders the real syntila manifest', (tester) async {
    final runner = ProcessCliRunner(cli!);
    final manifest = await tester.runAsync(runner.loadManifest);
    expect(manifest!.cli.name, 'syntila');

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Start in the real zone so process futures created by the shell
    // complete (they never do inside the fake-async test zone).
    await tester.runAsync(
      () => tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.lightTheme(),
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
      'Logs',
      'All commands',
    ]) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(ran, findsOneWidget);

    // Generated pages still work: open Logs and run it.
    await tester.runAsync(() async {
      await tester.tap(find.text('Logs').first);
      await tester.pump();
    });
    final logs = find.textContaining(' logs --json');
    for (var i = 0; i < 100 && logs.evaluate().length < 2; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
    }
    expect(find.text('Raw output'), findsOneWidget);
  }, skip: cli == null);
}
