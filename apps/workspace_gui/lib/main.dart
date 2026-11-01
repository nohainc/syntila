import 'package:flutter/material.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';
import 'package:syntila_design/syntila_design.dart';

import 'src/status_page.dart';
import 'src/syntila_cli_location.dart';
import 'src/syntila_themes.dart';

void main() {
  runApp(
    GuiManifestApp(
      runner: ProcessCliRunner(locateSyntilaCli()),
      title: 'Syntila Workspace',
      logo: const WorkspaceHeader(),
      theme: syntilaLightTheme(),
      darkTheme: syntilaDarkTheme(),
      preferencesStore: ViewPreferencesStore.forApp('Syntila Workspace'),
      commandPages: {
        'status': (context, command, runner) => StatusPage(runner: runner),
      },
    ),
  );
}

class WorkspaceHeader extends StatelessWidget {
  const WorkspaceHeader({super.key});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SyntilaBrandAssets.logoMark(size: 28),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          'Syntila Workspace',
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    ],
  );
}
