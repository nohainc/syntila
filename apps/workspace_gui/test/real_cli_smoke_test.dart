import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';
import 'package:syntila_design/syntila_design.dart';

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
          home: GuiManifestShell(runner: runner, title: 'Syntila Workspace'),
        ),
      ),
    );

    // Real processes finish outside fake time; poll until Status has run
    // (its command line shows in the preview and in the result).
    final ran = find.textContaining(' status --json');
    for (var i = 0; i < 100 && ran.evaluate().length < 2; i++) {
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
    expect(ran, findsNWidgets(2));
    expect(find.text('Raw output'), findsOneWidget);
  }, skip: cli == null);
}
