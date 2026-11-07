import 'package:flutter/gestures.dart';
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

    expect(find.text('RECENT'), findsOneWidget);
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
          findsOneWidget);
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

  testWidgets(
      'direct spaces render under PEOPLE group after owned and shared',
      (tester) async {
    final context = const AxShellContext(
      navigation: AxNavigation.home(),
      spaces: [shared, own, direct],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpaceTree(
          shellContext: context,
          onNavigateTo: (_) {},
        ),
      ),
    ));

    expect(find.text('PEOPLE'), findsOneWidget);
    expect(find.text('YOUR SPACES'), findsOneWidget);
    expect(find.text('SHARED WITH YOU'), findsOneWidget);

    final personalY = tester.getTopLeft(find.text(direct.name)).dy;
    final ownY = tester.getTopLeft(find.text(own.name)).dy;
    final sharedY = tester.getTopLeft(find.text(shared.name)).dy;

    expect(ownY, lessThan(sharedY));
    expect(sharedY, lessThan(personalY));
  });

  testWidgets('pinned direct spaces appear before unpinned direct spaces',
      (tester) async {
    final context = const AxShellContext(
      navigation: AxNavigation.home(),
      spaces: [direct, directPinned],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpaceTree(
          shellContext: context,
          onNavigateTo: (_) {},
        ),
      ),
    ));

    expect(find.text('PEOPLE'), findsOneWidget);
    final pinnedY = tester.getTopLeft(find.text(directPinned.name)).dy;
    final unpinnedY = tester.getTopLeft(find.text(direct.name)).dy;

    expect(pinnedY, lessThan(unpinnedY));
  });

  testWidgets(
      'direct space context menu matches a regular space: Edit, Archive and Delete',
      (tester) async {
    final context = const AxShellContext(
      navigation: AxNavigation.space('direct-1'),
      spaces: [direct],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpaceTree(
          shellContext: context,
          onNavigateTo: (_) {},
          pageLayout: true,
          onEditSpace: (_) async {},
          onArchiveSpace: (_) async {},
          onDeleteSpace: (_) async {},
        ),
      ),
    ));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text(direct.name)));
    await tester.pump();

    await tester.tap(find.byTooltip('Space menu'));
    await tester.pumpAndSettle();

    expect(find.text('Edit Space'), findsOneWidget);
    expect(find.text('Archive Space'), findsOneWidget);
    expect(find.text('Delete Space'), findsOneWidget);
  });

  testWidgets(
      'personal threads appear in RECENT section with peer name',
      (tester) async {
    const generalThread = AxThread(
      id: 'gen-1',
      spaceId: 'direct-1',
      name: 'General',
      isGeneral: true,
      lead: '',
      brief: '',
      primaryWorkspace: '',
      queueStatus: '',
      status: 'active',
      updatedAt: '2026-11-06T10:00:00Z',
    );
    const subThread = AxThread(
      id: 'sub-1',
      spaceId: 'direct-1',
      name: 'Project Discussion',
      isGeneral: false,
      lead: '',
      brief: '',
      primaryWorkspace: '',
      queueStatus: '',
      status: 'active',
      updatedAt: '2026-11-06T09:00:00Z',
    );

    final context = const AxShellContext(
      navigation: AxNavigation.home(),
      spaces: [direct],
      threadsBySpace: {
        'direct-1': [generalThread, subThread],
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpaceTree(
          shellContext: context,
          showRecentThreads: true,
          onNavigateTo: (_) {},
        ),
      ),
    ));

    expect(find.text('RECENT'), findsOneWidget);
    // General thread shows peer name ('Alice Cooper')
    expect(find.text('Alice Cooper'), findsWidgets);
    // Sub-thread shows 'Alice Cooper · Project Discussion'
    expect(find.text('Alice Cooper · Project Discussion'), findsOneWidget);
  });
}
