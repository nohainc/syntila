import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/navigation/ax_shell_context.dart';
import 'package:syntila_app/src/features/navigation/ax_sidebar.dart';
import 'package:syntila_app/src/navigation/ax_navigation.dart';

void main() {
  const own = AxSpace(
      id: 'own',
      name: 'Owned space',
      branch: '',
      lastActivity: '',
      role: 'owner');
  const shared = AxSpace(
      id: 'shared',
      name: 'Shared space',
      branch: '',
      lastActivity: '',
      role: 'collaborator');

  for (final scale in [1.15, 1.3]) {
    testWidgets('sidebar tree lays out at text scale $scale', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: const Scaffold(
                  body: SizedBox(
                      width: 260,
                      child: SpaceTree(
                        shellContext: AxShellContext(
                            navigation: AxNavigation.home(),
                            spaces: [own, shared]),
                        showRecentThreads: true,
                        onNavigateTo: _noop,
                      ))))));
      expect(tester.takeException(), isNull);
    });
  }
}

void _noop(AxNavigation _) {}
