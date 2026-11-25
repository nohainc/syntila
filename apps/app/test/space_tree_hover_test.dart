import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/navigation/ax_shell_context.dart';
import 'package:syntila_app/src/features/navigation/space_tree.dart';
import 'package:syntila_app/src/navigation/ax_navigation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _space = AxSpace(
  id: 'space-a',
  name: 'Space A',
  branch: '',
  lastActivity: '',
  role: 'owner',
);

const _thread = AxThread(
  id: 'thread-a',
  spaceId: 'space-a',
  name: 'Thread A',
  lead: '',
  status: 'active',
  brief: '',
  queueStatus: '',
);

void main() {
  testWidgets('archived Threads are absent from the expanded sidebar',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SpaceTree(
      shellContext: const AxShellContext(
        navigation: AxNavigation.home(),
        spaces: [_space],
        expandedSpaceIds: {'space-a'},
        threadsBySpace: {
          'space-a': [
            _thread,
            AxThread(
                id: 'archived',
                spaceId: 'space-a',
                name: 'Archived Thread',
                lead: '',
                status: 'archived',
                brief: '',
                queueStatus: ''),
          ]
        },
      ),
      onNavigateTo: (_) {},
      onToggleSpaceExpanded: (_) {},
    ))));
    expect(find.text('Thread A'), findsOneWidget);
    expect(find.text('Archived Thread'), findsNothing);
    expect(find.textContaining('Archived ('), findsNothing);
  });

  for (final isThread in [false, true]) {
    testWidgets(
        'touch hold opens ${isThread ? 'Thread' : 'Space'} actions without navigating',
        (tester) async {
      final navigations = <AxNavigation>[];
      var toggles = 0;
      final scaffoldKey = GlobalKey<ScaffoldState>();
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          key: scaffoldKey,
          drawer: Drawer(
            child: SafeArea(
              child: SingleChildScrollView(
                child: SpaceTree(
                  compact: true,
                  shellContext: const AxShellContext(
                    navigation: AxNavigation.home(),
                    spaces: [_space],
                    expandedSpaceIds: {'space-a'},
                    threadsBySpace: {
                      'space-a': [_thread]
                    },
                  ),
                  onNavigateTo: navigations.add,
                  onToggleSpaceExpanded: (_) => toggles++,
                ),
              ),
            ),
          ),
        ),
      ));
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();
      final row = find.text(isThread ? 'Thread A' : 'Space A');
      final action = find.text(isThread ? 'Rename Thread' : 'Edit Space');

      // Moving to scroll before the hold threshold cancels menu activation.
      final gesture = await tester.startGesture(tester.getCenter(row));
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(action, findsNothing);
      expect(navigations, isEmpty);

      await tester.longPress(row);
      await tester.pumpAndSettle();
      expect(action, findsOneWidget);
      expect(navigations, isEmpty);
      expect(toggles, 0);
      expect(scaffoldKey.currentState!.isDrawerOpen, isTrue);
      final semantics = tester.ensureSemantics();
      expect(
          find.byWidgetPredicate((widget) =>
              widget is Semantics &&
              (widget.properties.customSemanticsActions?.keys.any((action) =>
                      action.label ==
                      (isThread ? 'Thread actions' : 'Space actions')) ??
                  false)),
          findsOneWidget);
      semantics.dispose();

      // Dismiss the popup, then an ordinary tap still navigates and closes.
      await tester.tap(find.byTooltip(isThread ? 'Thread menu' : 'Space menu'));
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(navigations, hasLength(1));
      expect(scaffoldKey.currentState!.isDrawerOpen, isFalse);
    });
  }

  testWidgets('hovered Space and Thread rows show their menus', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 260,
          child: SpaceTree(
            shellContext: const AxShellContext(
              navigation: AxNavigation.home(),
              spaces: [_space],
              expandedSpaceIds: {'space-a'},
              threadsBySpace: {
                'space-a': [_thread]
              },
            ),
            onNavigateTo: (_) {},
            onToggleSpaceExpanded: (_) {},
          ),
        ),
      ),
    ));
    final spaceMenu = find.byTooltip('Space menu');
    final threadMenu = find.byTooltip('Thread menu');
    expect(spaceMenu, findsNothing);
    expect(threadMenu, findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Space A')));
    await tester.pump();
    expect(spaceMenu, findsOneWidget);
    expect(threadMenu, findsNothing);

    await mouse.moveTo(tester.getCenter(find.text('Thread A')));
    await tester.pump();
    expect(spaceMenu, findsNothing);
    expect(threadMenu, findsOneWidget);

    // An open menu keeps its row active after the pointer leaves.
    await tester.tap(threadMenu);
    await tester.pumpAndSettle();
    await mouse.moveTo(const Offset(250, 590));
    await tester.pump();
    expect(threadMenu, findsOneWidget);
    expect(find.text('Rename Thread'), findsOneWidget);
  });

  testWidgets('Edit Space menu item dispatches the selected Space',
      (tester) async {
    AxSpace? selectedSpace;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpaceTree(
          shellContext: const AxShellContext(
            navigation: AxNavigation.home(),
            spaces: [_space],
          ),
          onNavigateTo: (_) {},
          onEditSpace: (space) async => selectedSpace = space,
        ),
      ),
    ));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Space A')));
    await tester.pump();
    await tester.tap(find.byTooltip('Space menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit Space'));
    await tester.pumpAndSettle();

    expect(selectedSpace?.id, 'space-a');
  });

  testWidgets('Edit Space in page layout invokes edit action', (tester) async {
    AxSpace? selectedSpace;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpaceTree(
          pageLayout: true,
          shellContext: const AxShellContext(
            navigation: AxNavigation.spaces(),
            spaces: [_space],
          ),
          onNavigateTo: (_) {},
          onEditSpace: (space) async => selectedSpace = space,
        ),
      ),
    ));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Space A')));
    await tester.pump();
    await tester.tap(find.byTooltip('Space menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit Space'));
    await tester.pumpAndSettle();

    expect(selectedSpace?.id, 'space-a');
  });
}
