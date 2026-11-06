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
const direct = AxSpace(
    id: 'direct-1',
    name: 'Alice Cooper',
    branch: '',
    lastActivity: '2026-11-06T12:00:00Z',
    kind: 'direct',
    role: 'member');
const directPinned = AxSpace(
    id: 'direct-2',
    name: 'Bob Marley',
    branch: '',
    lastActivity: '2026-11-05T12:00:00Z',
    kind: 'direct',
    pinnedAt: '2026-11-06T00:00:00Z',
    role: 'member');

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

  testWidgets('direct spaces render under PERSONAL group before owned and shared',
      (tester) async {
    final context = AxShellContext(
      navigation: const AxNavigation.home(),
      spaces: const [shared, own, direct],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpaceTree(
          shellContext: context,
          onNavigateTo: (_) {},
        ),
      ),
    ));

    expect(find.text('PERSONAL'), findsOneWidget);
    expect(find.text('YOUR SPACES'), findsOneWidget);
    expect(find.text('SHARED WITH YOU'), findsOneWidget);

    final personalY = tester.getTopLeft(find.text(direct.name)).dy;
    final ownY = tester.getTopLeft(find.text(own.name)).dy;
    final sharedY = tester.getTopLeft(find.text(shared.name)).dy;

    expect(personalY, lessThan(ownY));
    expect(ownY, lessThan(sharedY));
  });

  testWidgets('pinned direct spaces appear before unpinned direct spaces',
      (tester) async {
    final context = AxShellContext(
      navigation: const AxNavigation.home(),
      spaces: const [direct, directPinned],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpaceTree(
          shellContext: context,
          onNavigateTo: (_) {},
        ),
      ),
    ));

    expect(find.text('PERSONAL'), findsOneWidget);
    final pinnedY = tester.getTopLeft(find.text(directPinned.name)).dy;
    final unpinnedY = tester.getTopLeft(find.text(direct.name)).dy;

    expect(pinnedY, lessThan(unpinnedY));
  });
}
