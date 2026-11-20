import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';
import 'package:syntila_design/syntila_design.dart';

import 'src/status_page.dart';
import 'src/syntila_themes.dart';

/// The CLI the GUI runs, in order: SYNTILA_CONNECT_CLI, the copy bundled in the
/// app (Contents/Resources/syntila-connect, see scripts/build-connect-macos.sh),
/// then `syntila-connect` on PATH.
String _resolveWorkerCli() {
  final fromEnvironment = Platform.environment['SYNTILA_CONNECT_CLI'];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
    return fromEnvironment;
  }
  final bundled = File(
    '${File(Platform.resolvedExecutable).parent.parent.path}'
    '/Resources/syntila-connect',
  );
  if (bundled.existsSync()) return bundled.path;
  return 'syntila-connect';
}

void main() {
  runApp(
    GuiManifestApp(
      runner: ProcessCliRunner(_resolveWorkerCli()),
      title: 'Syntila Connect',
      logo: const ConnectHeader(),
      theme: syntilaLightTheme(),
      darkTheme: syntilaDarkTheme(),
      preferencesStore: ViewPreferencesStore.forApp('Syntila Connect'),
      commandPages: {
        'status': (context, command, runner) =>
            ConnectStatusPage(runner: runner),
      },
    ),
  );
}

class ConnectHeader extends StatelessWidget {
  const ConnectHeader({super.key});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SyntilaBrandAssets.logoMark(size: 28),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          'Syntila Connect',
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    ],
  );
}
