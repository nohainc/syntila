import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/navigation/ax_shell_context.dart';
import 'package:syntila_app/src/features/navigation/space_tree.dart';
import 'package:syntila_app/src/navigation/ax_navigation.dart';
import 'package:syntila_design/syntila_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _space = AxSpace(
  id: 'space-a',
  name: 'Space A',
  branch: '',
  lastActivity: '',
  role: 'owner',
  hasActiveWork: true,
);

Future<double> _runningIndicatorRight(
  WidgetTester tester,
  AxNavigation navigation,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 260,
        child: SpaceTree(
          shellContext: AxShellContext(
            navigation: navigation,
            spaces: const [_space],
          ),
          onNavigateTo: (_) {},
          onToggleSpaceExpanded: (_) {},
        ),
      ),
    ),
  ));
  // The running indicator pulses forever, so settle is not possible.
  await tester.pump();
  return tester
      .getTopRight(find.byKey(const ValueKey('sidebar-running-indicator')))
      .dx;
}

void main() {
  testWidgets(
      'unread is brand violet and running takes priority in light violet',
      (tester) async {
    Future<void> render({required bool running}) async {
      await tester.pumpWidget(MaterialApp(
        home: SidebarPulse(
          child: SidebarActivityIndicators(running: running, unread: true),
        ),
      ));
    }

    Color? color(String key) =>
        (tester.widget<Container>(find.byKey(ValueKey(key))).decoration
                as BoxDecoration)
            .color;

    await render(running: false);
    expect(color('sidebar-unread-indicator'), SyntilaBrand.accent);
    expect(
        find.byKey(const ValueKey('sidebar-running-indicator')), findsNothing);

    await render(running: true);
    expect(color('sidebar-running-indicator'),
        SyntilaColors.primaryRunningIndicator);
    expect(
        find.byKey(const ValueKey('sidebar-unread-indicator')), findsNothing);
  });

  testWidgets('running indicator pulses between 25 and 100 percent opacity',
      (tester) async {
    await _runningIndicatorRight(tester, const AxNavigation.home());
    expect(
        tester.getSize(find.byKey(const ValueKey('sidebar-running-indicator'))),
        const Size(9, 9));
    final fade = find.ancestor(
      of: find.byKey(const ValueKey('sidebar-running-indicator')),
      matching: find.byType(FadeTransition),
    );
    double opacity() => tester.widget<FadeTransition>(fade.first).opacity.value;
    expect(opacity(), closeTo(0.25, 0.001));
    await tester.pump(const Duration(milliseconds: 2000));
    expect(opacity(), closeTo(1, 0.001));
    await tester.pump(const Duration(milliseconds: 2000));
    expect(opacity(), closeTo(0.25, 0.001));
  });

  testWidgets('new running dots and collapsed folders share the existing pulse',
      (tester) async {
    const second = AxSpace(
      id: 'space-b',
      name: 'Space B',
      branch: '',
      lastActivity: '',
      role: 'owner',
      hasActiveWork: true,
      hasUnread: true,
    );
    Future<void> render({bool addSecond = false, bool expanded = false}) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
        width: 260,
        child: SpaceTree(
          shellContext: AxShellContext(
            navigation: const AxNavigation.home(),
            spaces: [_space, if (addSecond) second],
            expandedSpaceIds: expanded ? {'space-a'} : {},
            threadsBySpace: const {
              'space-a': [
                AxThread(
                  id: 't',
                  spaceId: 'space-a',
                  name: 'Busy',
                  lead: '',
                  status: 'running',
                  brief: '',
                  primaryWorkspace: '',
                  queueStatus: '',
                  hasActiveWork: true,
                )
              ]
            },
          ),
          onNavigateTo: (_) {},
        ),
      ))));
      await tester.pump();
    }

    List<Animation<double>> animations() => [
          for (final element in find
              .byKey(const ValueKey('sidebar-running-indicator'))
              .evaluate())
            tester
                .widget<FadeTransition>(find
                    .ancestor(
                      of: find.byWidget(element.widget),
                      matching: find.byType(FadeTransition),
                    )
                    .first)
                .opacity,
        ];

    await render();
    await tester.pump(const Duration(milliseconds: 1400));
    final original = animations().single;
    final opacity = original.value;
    expect(opacity, greaterThan(0.25));
    await render(addSecond: true);
    expect(animations(), hasLength(2));
    for (final animation in animations()) {
      expect(identical(animation, original), isTrue);
      expect(animation.value, opacity);
    }
    // Expanding replaces the folder dot with its Thread dot, on the same clock.
    await render(addSecond: true, expanded: true);
    for (final animation in animations()) {
      expect(identical(animation, original), isTrue);
    }
    expect(find.byTooltip('Running'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'reduced motion gives every running dot static 40 percent opacity',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: SpaceTree(
        shellContext: const AxShellContext(
          navigation: AxNavigation.home(),
          spaces: [_space],
        ),
        onNavigateTo: (_) {},
      ),
    ))));
    final opacity = find.ancestor(
      of: find.byKey(const ValueKey('sidebar-running-indicator')),
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(opacity.first).opacity, 0.4);
  });

  testWidgets('Space and Thread rows are 30 px in every selection state',
      (tester) async {
    const threads = [
      AxThread(
          id: 'active',
          spaceId: 'space-a',
          name: 'Active Thread',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      AxThread(
          id: 'archived',
          spaceId: 'space-a',
          name: 'Archived Thread',
          lead: '',
          status: 'archived',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
    ];
    for (final navigation in [
      const AxNavigation.home(),
      const AxNavigation.space('space-a'),
      const AxNavigation.thread('space-a', 'active'),
      const AxNavigation.thread('space-a', 'archived'),
    ]) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
        width: 260,
        child: SpaceTree(
          shellContext: AxShellContext(
            navigation: navigation,
            spaces: const [_space],
            expandedSpaceIds: const {'space-a'},
            threadsBySpace: const {'space-a': threads},
          ),
          onNavigateTo: (_) {},
          onToggleSpaceExpanded: (_) {},
        ),
      ))));
      await tester.pump();
      for (final label in ['Space A', 'Active Thread']) {
        final row = find
            .ancestor(of: find.text(label), matching: find.byType(InkWell))
            .first;
        expect(tester.getSize(row).height, 30, reason: '$label at $navigation');
      }
      expect(find.text('Archived Thread'), findsNothing);
      if (navigation.kind == AxRouteKind.space ||
          navigation.threadId == 'active') {
        final menu = find.byTooltip(
            navigation.threadId == null ? 'Space menu' : 'Thread menu');
        expect(menu, findsOneWidget);
        await tester.tap(menu);
        await tester.pump();
        expect(
            find.text(
                navigation.threadId == null ? 'Edit Space' : 'Rename Thread'),
            findsOneWidget);
        await tester.tapAt(const Offset(500, 500));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('activity indicators stay put when the Space is selected',
      (tester) async {
    final unselected =
        await _runningIndicatorRight(tester, const AxNavigation.home());
    final selected = await _runningIndicatorRight(
        tester, const AxNavigation.space('space-a'));

    expect(selected, unselected);
  });

  testWidgets('selected Space keeps the same row typography and height',
      (tester) async {
    Future<({double height, Color? color, FontWeight? weight})> render(
        AxNavigation navigation) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            child: SpaceTree(
              shellContext: AxShellContext(
                navigation: navigation,
                spaces: const [_space],
              ),
              onNavigateTo: (_) {},
              onToggleSpaceExpanded: (_) {},
            ),
          ),
        ),
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.text('Space A'));
      final paragraph =
          tester.renderObject<RenderParagraph>(find.text('Space A'));
      expect(
          tester
              .widget<SyntilaFolderIcon>(find.byType(SyntilaFolderIcon))
              .color,
          SyntilaColors.navigationTextMuted(false));
      return (
        height: tester.getSize(find.text('Space A')).height,
        color: paragraph.text.style?.color,
        weight: text.style?.fontWeight,
      );
    }

    final unselected = await render(const AxNavigation.home());
    final selected = await render(const AxNavigation.space('space-a'));
    expect(selected.height, unselected.height);
    expect(selected.color, unselected.color);
    expect(selected.weight, unselected.weight);
  });

  testWidgets(
      'Thread indicators sit left of the title, Space roll-up on folder',
      (tester) async {
    const thread = AxThread(
        id: 't',
        spaceId: 'space-a',
        name: 'Busy Thread',
        lead: '',
        status: 'active',
        brief: '',
        primaryWorkspace: '',
        queueStatus: '',
        hasUnread: true);
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
                'space-a': [thread]
              },
            ),
            onNavigateTo: (_) {},
            onToggleSpaceExpanded: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(
        tester.getSize(find.byKey(const ValueKey('sidebar-unread-indicator'))),
        const Size(9, 9));
    final dot = tester
        .getTopRight(find.byKey(const ValueKey('sidebar-unread-indicator')));
    expect(dot.dx, lessThan(tester.getTopLeft(find.text('Busy Thread')).dx));
  });
}
