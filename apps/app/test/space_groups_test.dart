import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/navigation/ax_sidebar.dart';
import 'package:syntila_app/src/features/navigation/ax_shell_context.dart';
import 'package:syntila_app/src/navigation/ax_navigation.dart';

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

void main() {
  testWidgets('recent Threads section stays visible when empty',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SpaceTree(
      shellContext:
          const AxShellContext(navigation: AxNavigation.home(), spaces: []),
      showRecentThreads: true,
      onNavigateTo: (_) {},
    ))));

    expect(find.text('RECENT THREADS'), findsOneWidget);
    expect(find.text('No recent threads yet'), findsOneWidget);
  });

  for (final spaces in [
    <AxSpace>[],
    [own],
    [shared],
    [shared, own]
  ]) {
    final context =
        AxShellContext(navigation: const AxNavigation.home(), spaces: spaces);
    testWidgets('expanded space groups: ${spaces.map((p) => p.id)}',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SpaceTree(
        shellContext: context,
        onNavigateTo: (_) {},
        onToggleSpaceExpanded: (_) {},
        onCreateSpace: () {},
      ))));
      expect(
          find.text('YOUR SPACES'),
          spaces.contains(own) && spaces.contains(shared)
              ? findsOneWidget
              : findsNothing);
      expect(find.text('SHARED WITH YOU'),
          spaces.contains(shared) ? findsOneWidget : findsNothing);
      if (spaces.length == 2) {
        expect(tester.getTopLeft(find.text(own.name)).dy,
            lessThan(tester.getTopLeft(find.text(shared.name)).dy));
      }
    });
    testWidgets('collapsed space selectors: ${spaces.map((p) => p.id)}',
        (tester) async {
      AxNavigation? selected;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: AxIconRail(
        shellContext: context,
        onNavigateTo: (nav) => selected = nav,
        onOpenDrawer: () {},
        onLogout: () {},
        onOpenAbout: () {},
        onOpenExternal: (_) {},
      ))));
      expect(find.byTooltip('Your spaces'),
          spaces.isNotEmpty ? findsOneWidget : findsNothing);
      expect(find.byTooltip('Shared with you'), findsNothing);
      expect(find.byTooltip('PINNED SPACES'), findsNothing);
      if (spaces.isNotEmpty) {
        await tester.tap(find.byTooltip('Your spaces'));
        await tester.pumpAndSettle();
        for (final space in spaces) {
          expect(find.text(space.name), findsOneWidget);
        }
        await tester.tap(find.text(spaces.first.name));
        await tester.pumpAndSettle();
        expect(selected?.spaceId, spaces.first.id);
      }
    });
  }
}
