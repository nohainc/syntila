import 'package:flutter/material.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';

import 'src/status_page.dart';
import 'src/syntila_cli_location.dart';
import 'src/syntila_themes.dart';

void main() {
  runApp(
    GuiManifestApp(
      runner: ProcessCliRunner(locateSyntilaCli()),
      title: 'Syntila Workspace',
      theme: syntilaLightTheme(),
      darkTheme: syntilaDarkTheme(),
      preferencesStore: ViewPreferencesStore.forApp('Syntila Workspace'),
      commandPages: {
        'status': (context, command, runner) => StatusPage(runner: runner),
      },
    ),
  );
}
