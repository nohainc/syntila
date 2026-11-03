import 'package:syntila_app/src/brand.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/navigation/app_sidebar.dart';
import 'package:syntila_app/src/features/navigation/ax_shell_context.dart';
import 'package:syntila_app/src/navigation/ax_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const owned = AxSpace(
    id: 'owned', name: 'My Space', branch: '', lastActivity: '', role: 'owner');
const shared = AxSpace(
    id: 'shared',
    name: 'Shared Space',
    branch: '',
    lastActivity: '',
    role: 'collaborator',
    hasUnread: true);
const thread = AxThread(
    id: 'thread',
    spaceId: 'owned',
    name: 'Busy Thread',
    lead: '',
    status: 'active',
    brief: '',
    primaryWorkspace: '',
    queueStatus: '',
    hasActiveWork: true);

Finder marker(String owner, String state) => find.descendant(
    of: find.byKey(ValueKey(owner)),
    matching: find.byKey(ValueKey('sidebar-$state-indicator')));

Widget rail(AxShellContext context,
        {bool reduceMotion = false, ValueChanged<AxNavigation>? navigate}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
            body: AppIconRail(
          shellContext: context,
          onNavigateTo: navigate ?? (_) {},
          onOpenDrawer: () {},
          onLogout: () {},
          onOpenAbout: () {},
          onOpenExternal: (_) {},
        )),
      ),
    );

void main() {
  testWidgets('collapsed switcher orders active Thread pins before activity',
      (tester) async {
    AxNavigation? destination;
    AxThread item(String id, {int? pin, bool archived = false}) =>
        AxThread.fromJson({
          'id': id,
          'spaceId': 'owned',
          'name': id,
          'status': archived ? 'archived' : 'active',
          'archived': archived,
          'pinnedAt': pin == null ? null : '2026-10-01T00:00:00Z',
          'pinPosition': pin ?? 0,
          'updatedAt':
              id == 'Recent' ? '2026-10-25T00:00:00Z' : '2026-10-01T00:00:00Z',
        });
    await tester.pumpWidget(rail(
        AxShellContext(navigation: const AxNavigation.home(), spaces: const [
          owned
        ], threadsBySpace: {
          'owned': [
            item('Older'),
            item('Second pin', pin: 1),
            item('Recent'),
            item('First pin', pin: 0),
            item('Archived pin', pin: -1, archived: true),
          ]
        }),
        navigate: (value) => destination = value));
    await tester.tap(find.byTooltip('Your spaces'));
    await tester.pumpAndSettle();
    final titles = ['First pin', 'Second pin', 'Recent', 'Older'];
    for (var i = 1; i < titles.length; i++) {
      expect(tester.getTopLeft(find.text(titles[i])).dy,
          greaterThan(tester.getTopLeft(find.text(titles[i - 1])).dy));
    }
    expect(find.text('Archived pin'), findsNothing);
    await tester.tap(find.text('First pin'));
    await tester.pumpAndSettle();
    expect(destination?.threadId, 'First pin');
    expect(destination?.spaceId, 'owned');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'collapsed spaces on rail list pins first without separate shared icon',
      (tester) async {
    AxSpace item(String id, String role, {int? pin}) => AxSpace.fromJson({
          'id': id,
          'name': id,
          'role': role,
          'pinnedAt': pin == null ? null : '2026-10-01T00:00:00Z',
          'pinPosition': pin ?? 0,
        });
    final spaces = ValueNotifier<List<AxSpace>>([
      item('Owned pin', 'owner', pin: 1),
      item('Shared pin', 'collaborator', pin: 0),
      owned,
      shared,
    ]);
    addTearDown(spaces.dispose);
    AxNavigation? destination;
    await tester.pumpWidget(rail(
        AxShellContext(
            navigation: const AxNavigation.home(),
            spaces: const [],
            spaceListenable: spaces),
        navigate: (value) => destination = value));
    expect(find.byTooltip('Your spaces'), findsOneWidget);
    expect(find.byTooltip('Shared with you'), findsNothing);
    expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
    await tester.tap(find.byTooltip('Your spaces'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('My Space')).dy,
        greaterThan(tester.getTopLeft(find.text('Owned pin')).dy));
    expect(find.text('Shared pin'), findsOneWidget);
    await tester.tap(find.text('Shared pin'));
    await tester.pumpAndSettle();
    expect(destination?.spaceId, 'Shared pin');
    spaces.value = [item('Owned pin', 'owner'), owned, shared];
    await tester.pumpAndSettle();
    expect(find.byTooltip('Your spaces'), findsOneWidget);
    expect(find.byTooltip('Shared with you'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('logo and avatar keep their size when the sidebar collapses',
      (tester) async {
    const context = AxShellContext(
      navigation: AxNavigation.home(),
      spaces: [],
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 220,
          child: AppSidebar(
            shellContext: context,
            onNavigateTo: (_) {},
            onLogout: () {},
            onOpenAbout: () {},
            onOpenExternal: (_) {},
          ),
        ),
      ),
    ));
    final expandedLogoSize = tester.getSize(find.byType(Image));
    final expandedAvatarSize = tester.getSize(find.byType(CircleAvatar));
    expect(expandedLogoSize, const Size(28, 28));
    expect(expandedAvatarSize, const Size(26, 26));

    await tester.pumpWidget(rail(context));
    expect(tester.getSize(find.byType(Image)), expandedLogoSize);
    expect(tester.getSize(find.byType(CircleAvatar)), expandedAvatarSize);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapsed notification badge uses the premium brand color',
      (tester) async {
    final unread = ValueNotifier<int>(5);
    addTearDown(unread.dispose);
    await tester.pumpWidget(rail(AxShellContext(
      navigation: const AxNavigation.home(),
      spaces: const [],
      unreadNotifications: unread,
    )));
    final badge = tester.widget<Badge>(find.byType(Badge));
    expect(badge.backgroundColor, SyntilaColors.primary);
    expect(badge.textColor, Colors.white);
    expect(find.text('5'), findsOneWidget);
    unread.value = 0;
    await tester.pump();
    expect(find.byType(Badge), findsNothing);
  });

  testWidgets(
      'collapsed selector rolls up cached Thread activity and Space unread',
      (tester) async {
    final spaces = ValueNotifier<List<AxSpace>>([owned, shared]);
    addTearDown(spaces.dispose);
    final context = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: const [],
        spaceListenable: spaces,
        threadsBySpace: const {
          'owned': [thread]
        });
    await tester.pumpWidget(rail(context));
    await tester.pump();
    expect(marker('rail-activity-spaces', 'running'), findsOneWidget);
    expect(marker('rail-activity-spaces', 'unread'), findsNothing);
    final running = marker('rail-activity-spaces', 'running');
    expect(tester.getSize(running), const Size(9, 9));
    final fade =
        find.ancestor(of: running, matching: find.byType(FadeTransition)).first;
    expect(tester.widget<FadeTransition>(fade).opacity.value,
        closeTo(0.25, 0.001));
    await tester.pump(const Duration(milliseconds: 2000));
    expect(
        tester.widget<FadeTransition>(fade).opacity.value, closeTo(1, 0.001));
    spaces.value = [
      owned,
      AxSpace.fromJson({
        'id': 'shared',
        'name': 'Shared Space',
        'role': 'collaborator',
        'hasUnread': false
      })
    ];
    await tester.pump();
    expect(marker('rail-activity-spaces', 'unread'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'collapsed switcher shows individual activity and still navigates',
      (tester) async {
    AxNavigation? destination;
    await tester.pumpWidget(rail(
        const AxShellContext(navigation: AxNavigation.home(), spaces: [
          owned,
          shared
        ], threadsBySpace: {
          'owned': [thread]
        }),
        navigate: (value) => destination = value));
    await tester.pump();
    await tester.tap(find.byTooltip('Your spaces'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(marker('rail-space-activity-owned', 'running'), findsOneWidget);
    expect(marker('rail-thread-activity-thread', 'running'), findsOneWidget);
    final groupFade = tester.widget<FadeTransition>(find
        .ancestor(
            of: marker('rail-activity-spaces', 'running'),
            matching: find.byType(FadeTransition))
        .first);
    final threadFade = tester.widget<FadeTransition>(find
        .ancestor(
            of: marker('rail-thread-activity-thread', 'running'),
            matching: find.byType(FadeTransition))
        .first);
    expect(threadFade.opacity.value, groupFade.opacity.value);
    await tester.tap(find.text('Busy Thread'));
    await tester.pump();
    expect(destination?.threadId, 'thread');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'collapsed indicators respect reduced motion and clear idle groups',
      (tester) async {
    final spaces = ValueNotifier<List<AxSpace>>([
      AxSpace.fromJson({
        'id': 'owned',
        'name': 'My Space',
        'role': 'owner',
        'hasActiveWork': true,
        'hasUnread': true
      })
    ]);
    addTearDown(spaces.dispose);
    await tester.pumpWidget(rail(
        AxShellContext(
            navigation: const AxNavigation.home(),
            spaces: const [],
            spaceListenable: spaces),
        reduceMotion: true));
    await tester.pump();
    final running = marker('rail-activity-spaces', 'running');
    expect(running, findsOneWidget);
    expect(marker('rail-activity-spaces', 'unread'), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('rail-activity-spaces')),
            matching: find.byType(FadeTransition)),
        findsNothing);
    expect(
        tester
            .widget<Opacity>(find
                .ancestor(of: running, matching: find.byType(Opacity))
                .first)
            .opacity,
        0.4);
    spaces.value = [owned];
    await tester.pump();
    expect(
        find.byKey(const ValueKey('sidebar-running-indicator')), findsNothing);
    expect(
        find.byKey(const ValueKey('sidebar-unread-indicator')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
