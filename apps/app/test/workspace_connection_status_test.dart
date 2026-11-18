import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syntila_app/src/features/navigation/app_menu.dart';
import 'package:syntila_app/src/features/navigation/ax_shell_context.dart';
import 'package:syntila_app/src/features/workspace/workspaces_page.dart';
import 'package:syntila_app/src/navigation/ax_navigation.dart';
import 'package:syntila_app/src/ax/ax_models.dart';

void main() {
  Widget scaffold(Widget child) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: child),
        ),
      );

  const initialWorkspace = AxWorkspace(
    id: 'workspace-1',
    name: 'MacBook Pro',
    hostname: '—',
    status: 'offline',
    hasRuntimeIdentity: false,
    appVersion: '—',
    workerCount: 0,
    activeTaskCount: 0,
    platform: '—',
    architecture: '—',
  );

  group('Workspace connection status', () {
    testWidgets(
        'Workspace operational status progresses from not connected to online',
        (tester) async {
      // 1. Initial State: Not connected. AX only observes this state.
      await tester.pumpWidget(scaffold(WorkspacesPage(
        workspaces: const [initialWorkspace],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Connection status'), findsNothing);
      expect(find.byTooltip('Not connected'), findsOneWidget);
      expect(find.text('Machine'), findsNothing);
      expect(find.text('Connect Machine'), findsNothing);

      // Runtime Connected: Online with automatically populated platform facts
      const onlineWorkspace = AxWorkspace(
        id: 'workspace-1',
        name: 'MacBook Pro',
        hostname: 'Vitalii-MacBook-Pro',
        status: 'online',
        appVersion: '1.0.3',
        workerCount: 2,
        activeTaskCount: 0,
        platform: 'macos',
        architecture: 'arm64',
        runtimeCapabilities: ['dart', 'shell'],
      );

      await tester.pumpWidget(scaffold(WorkspacesPage(
        workspaces: const [onlineWorkspace],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Online'), findsOneWidget);
      expect(find.text('Machine'), findsNothing);
      expect(find.text('MacBook Pro'), findsWidgets);
      expect(find.text('macOS'), findsOneWidget);
      expect(find.textContaining('Apple Silicon'), findsNothing);
      expect(find.text('Hostname'), findsNothing);
      expect(find.text('App version'), findsNothing);
      expect(find.text('1.0.3'), findsNothing);
    });

    testWidgets('Workspace page keeps download actions out of its UI',
        (tester) async {
      await tester.pumpWidget(scaffold(WorkspacesPage(
        workspaces: const [initialWorkspace],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Download Syntila Workspace'), findsNothing);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                GlobalAppMenu(
                  shellContext: const AxShellContext(
                    navigation: AxNavigation.workspaces(),
                    workspaces: [initialWorkspace],
                    spaces: [],
                    themeMode: ThemeMode.system,
                  ),
                  onNavigateTo: (_) {},
                  onOpenAbout: () {},
                  onOpenExternal: (_) {},
                  onLogout: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      expect(find.text('Documentation'), findsNothing);
      expect(find.text('Downloads'), findsNothing);
    });

    testWidgets('Platform reporting maps runtime OS and architectures cleanly',
        (tester) async {
      final platforms = [
        ('macos', 'arm64', 'macOS'),
        ('macos', 'x64', 'macOS'),
        ('linux', 'x64', 'Linux'),
        ('windows', 'x64', 'Windows'),
        ('—', '—', 'Target Machine'),
      ];

      for (final (os, arch, expectedLabel) in platforms) {
        final workspace = AxWorkspace(
          id: 'ws-test',
          name: 'Target Machine',
          hostname: 'workspace-node-1',
          status: 'online',
          appVersion: '1.0.0',
          workerCount: 0,
          activeTaskCount: 0,
          platform: os,
          architecture: arch,
        );

        await tester.pumpWidget(scaffold(WorkspacesPage(
          workspaces: [workspace],
          onAdd: () {},
          onRename: (_) {},
          onUpdate: (_) {},
          onRevoke: (_) {},
        )));
        await tester.pumpAndSettle();
        expect(
          find.text(expectedLabel),
          findsWidgets,
        );
      }
    });
  });
}
