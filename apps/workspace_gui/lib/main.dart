import 'package:flutter/material.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';
import 'package:syntila_design/syntila_design.dart';

import 'src/syntila_cli_location.dart';

void main() {
  runApp(
    GuiManifestApp(
      runner: ProcessCliRunner(locateSyntilaCli()),
      title: 'Syntila Workspace',
      theme: SyntilaBrand.lightTheme(),
      darkTheme: SyntilaBrand.darkTheme(),
    ),
  );
}
