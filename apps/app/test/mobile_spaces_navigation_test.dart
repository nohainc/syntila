import 'package:syntila_app/src/app_shell.dart';
import 'package:syntila_app/src/features/navigation/space_tree.dart';
import 'package:syntila_app/src/features/navigation/app_top_hud.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'ax_fixture_data.dart';
import 'ax_fixture_snapshot.dart';
import 'package:syntila_app/src/ax/ax_models.dart';

class LongListSource extends AxFixtureDataSource {
  List<AxThread> get threads => [
        for (var i = 0; i < 30; i++)
          AxThread(
              id: 'thread-$i',
              spaceId: 'space-auth',
              name: 'Thread $i',
              lead: '',
              status: 'active',
              brief: '',
              primaryWorkspace: '',
              queueStatus: ''),
      ];
  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async =>
      threads;
  @override
  Future<AxSnapshot> loadBootstrapState(
      {String? spaceId, String? workspaceId}) async {
    final snapshot = axFixtureSnapshot();
    return snapshot
        .copyWith(spaces: [snapshot.spaces.first.copyWith(threads: threads)]);
  }
}

class PersonalNameSource extends AxFixtureDataSource {
  AxSpace person = axFixtureSnapshot().spaces.first.copyWith(
    kind: 'direct',
    role: 'collaborator',
    name: 'Alex',
    settings: {'originalName': 'Alex', 'personalName': null},
  );
  final updates = <Map<String, dynamic>>[];

  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async =>
      [person];

  @override
  Future<AxSnapshot> loadBootstrapState(
          {String? spaceId, String? workspaceId}) async =>
      axFixtureSnapshot().copyWith(spaces: [person]);

  @override
  Future<AxSpace> updateSpace(
      {required String spaceId,
      String? name,
      String? description,
      String? instructions,
      Map<String, dynamic>? settings}) async {
    updates.add(Map.of(settings!));
    final personal = settings['personalName'] as String?;
    person = person.copyWith(name: personal ?? 'Alex', settings: {
      'originalName': 'Alex',
      'personalName': personal,
    });
    return person;
  }
}

void main() {
  testWidgets('People Space rename and reset are personal settings',
      (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = PersonalNameSource();
    await tester.pumpWidget(SyntilaAppShell(
      services: const DefaultPlatformServices(),
      dataSource: source,
      initialUri: Uri.parse('/spaces'),
    ));
    await tester.pumpAndSettle();

    Future<void> openEditor() async {
      final row = find.byKey(const ValueKey('sidebar-space-row-space-auth'));
      await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('Space menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit Space'));
      await tester.pumpAndSettle();
    }

    await openEditor();
    final dialog = find.byKey(const ValueKey('personal-space-name-dialog'));
    expect(dialog, findsOneWidget);
    await tester.enterText(
        find.descendant(of: dialog, matching: find.byType(TextField)),
        'Alex at work');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(source.updates.last, {'personalName': 'Alex at work'});
    expect(find.text('Alex at work'), findsWidgets);

    await openEditor();
    await tester.tap(find.text('Reset to person’s name'));
    await tester.pumpAndSettle();
    expect(source.updates.last, {'personalName': null});
    expect(find.text('Alex'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Edit Space menu opens the Space edit dialog on mobile',
      (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(SyntilaAppShell(
      services: const DefaultPlatformServices(),
      dataSource: const AxFixtureDataSource(),
      initialUri: Uri.parse('/spaces'),
    ));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('sidebar-space-row-space-auth'));
    await tester
        .tap(find.descendant(of: row, matching: find.byTooltip('Space menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit Space'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('space-edit-dialog')), findsOneWidget);
    expect(find.text('Space Name'), findsOneWidget);
    expect(find.text('Description'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mobile list preserves scroll across Thread navigation',
      (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(SyntilaAppShell(
      services: const DefaultPlatformServices(),
      dataSource: LongListSource(),
      initialUri: Uri.parse('/spaces'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Authentication').last);
    await tester.pumpAndSettle();
    final list = find.byKey(const PageStorageKey('mobile-spaces-list'));
    await tester.drag(list, const Offset(0, -500));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('sidebar-thread-row-thread-10'));
    final before = tester.getTopLeft(row).dy;
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Syntila — Spaces'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(row).dy, closeTo(before, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('mobile list opens Threads and returns with state at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: const AxFixtureDataSource(),
        initialUri: Uri.parse('/spaces'),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
      expect(find.byTooltip('Open menu'), findsNothing);
      expect(find.byType(SpaceTree), findsOneWidget);
      expect(find.byTooltip('New Space'), findsOneWidget);
      final appMenuButton = find.descendant(
          of: find.byTooltip('Application menu'),
          matching: find.byType(IconButton));
      // Tooltip can be inside or around IconButton depending on Material version.
      final search = find.widgetWithIcon(IconButton, Icons.search_rounded);
      expect(tester.getSize(appMenuButton), tester.getSize(search));

      expect(find.byType(CircleAvatar), findsNothing);
      final accountText = tester.widget<Text>(find.descendant(
          of: find.byKey(const ValueKey('mobile-account-name')),
          matching: find.byType(Text)));
      expect(accountText.style!.fontWeight, FontWeight.w700);
      expect(accountText.style!.fontSize, 14.5);

      final row = find.byKey(const ValueKey('sidebar-space-row-space-auth'));
      expect(tester.getSize(row).height, 52);
      for (final icon in [
        Icons.search_rounded,
        Icons.notifications_none_rounded,
        Icons.menu_rounded
      ]) {
        expect(tester.widget<Icon>(find.byIcon(icon)).size, 20);
      }
      await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('Space menu')));
      await tester.pumpAndSettle();
      final labels = tester
          .widgetList<MenuItemButton>(find.byType(MenuItemButton))
          .map((button) => button.child)
          .whereType<Text>()
          .map((text) => text.data)
          .toList();
      expect(labels.indexOf('Open Space') + 1, labels.indexOf('Edit Space'));
      await tester.tapAt(const Offset(5, 500));
      await tester.pumpAndSettle();

      final otherRow = find.byKey(const ValueKey('sidebar-space-row-atlas'));
      expect(
          find.descendant(of: otherRow, matching: find.byTooltip('Space menu')),
          findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(0, 0));
      await mouse.moveTo(tester.getCenter(otherRow));
      await tester.pump();
      expect(
          find.descendant(of: otherRow, matching: find.byTooltip('Space menu')),
          findsOneWidget);
      await mouse.removePointer();
      await tester.pump();

      if (find
          .byKey(const ValueKey('sidebar-thread-row-thread-auth'))
          .evaluate()
          .isEmpty) {
        await tester.tap(find.text('Authentication').last);
        await tester.pumpAndSettle();
      }
      final thread =
          find.byKey(const ValueKey('sidebar-thread-row-thread-auth'));
      expect(thread, findsOneWidget);
      expect(find.byTooltip('New Thread'), findsWidgets);
      await tester.tap(thread);
      await tester.pumpAndSettle();
      expect(find.byType(ThreadPage), findsOneWidget);
      await tester.tap(find.descendant(
          of: find.byWidgetPredicate((widget) => widget is AppTopHud),
          matching: find.text('Authentication')));
      await tester.pumpAndSettle();
      expect(find.byType(SpacePage), findsNothing);
      expect(
          find.byKey(const PageStorageKey('mobile-space-threads-space-auth')),
          findsOneWidget);
      expect(
          find.byKey(const ValueKey('sidebar-space-row-atlas')), findsNothing);
      expect(thread, findsOneWidget);
      await tester.tap(thread);
      await tester.pumpAndSettle();
      expect(find.byType(ThreadPage), findsOneWidget);

      await tester.tap(find.byTooltip('Syntila — Spaces'));
      await tester.pumpAndSettle();
      expect(thread, findsOneWidget);
      expect(find.byType(ThreadPage), findsNothing);
      expect(find.byKey(const ValueKey('sidebar-space-row-atlas')),
          findsOneWidget);
      await tester.tap(find.byTooltip('New Space'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(MenuItemButton, 'Account'), findsNothing);
      await tester.tapAt(const Offset(5, 500));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mobile-account-name')));
      await tester.pumpAndSettle();
      expect(
          find.descendant(
              of: find.byWidgetPredicate((widget) => widget is AppTopHud),
              matching: find.text('Profile')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byWidgetPredicate((widget) => widget is AppTopHud),
              matching: find.text('Profile & Security')),
          findsNothing);

      expect(find.byTooltip('Syntila — Spaces'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
