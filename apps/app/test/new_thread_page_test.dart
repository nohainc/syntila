import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/sync/ax_discussion_cache.dart';
import 'package:syntila_app/src/ax/sync/ax_work_history.dart';
import 'package:syntila_app/src/ax/sync/persistence/ax_thread_view_state_store.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'ax_fixture_data.dart';

const space = AxSpace(id: 'S', name: 'Space', branch: '', lastActivity: '');
const thread = AxThread(
    id: 'T',
    spaceId: 'S',
    name: 'Existing',
    lead: '',
    status: 'archived',
    brief: '',
    primaryWorkspace: '',
    queueStatus: '');

class Source extends AxFixtureDataSource {
  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async =>
      [thread];
}

Future<void> pump(WidgetTester tester,
    {required Future<AxThread> Function(String) create,
    required ValueChanged<AxThread> open}) async {
  final source = Source();
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: NewThreadPage(
    space: space.copyWith(description: 'Description'),
    dataSource: source,
    createThread: create,
    onOpenThread: open,
    discussionCache: AxDiscussionCache.forSource(source),
    workHistoryCache: AxWorkHistoryCache.forSource(source),
    threadViewStateStore: MemoryAxThreadViewStateStore(),
  ))));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Space landing shows only archived Threads in a collapsed area',
      (tester) async {
    await pump(tester, create: (_) async => thread, open: (_) {});
    final title = find.text('Archived Threads');
    expect(tester.getRect(find.text('Members')).bottom,
        lessThan(tester.getRect(title).top));
    expect(find.byKey(const ValueKey('space-thread-filter')), findsNothing);
    expect(find.text('Existing'), findsNothing);
    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(find.text('Existing'), findsOneWidget);
    expect(
        tester
            .getSize(find.byKey(const ValueKey('space-landing-threads')))
            .width,
        500);
    expect(find.widgetWithText(TextButton, 'Restore'), findsNothing);
    await tester.tap(find.byIcon(Icons.more_vert).last);
    await tester.pumpAndSettle();
    expect(find.text('Restore'), findsOneWidget);
  });

  for (final width in [600.0, 1200.0]) {
    testWidgets('Space has only named creation and members at width $width',
        (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? name;
      AxThread? opened;
      await pump(tester,
          create: (value) async {
            name = value;
            return thread;
          },
          open: (value) => opened = value);
      expect(find.byType(TabBar), findsNothing);
      expect(find.byType(ThreadPage), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      final field = find.byKey(const ValueKey('new-thread-name'));
      expect(tester.widget<TextField>(field).decoration!.labelText,
          'Create a new thread');
      expect(tester.widget<TextField>(field).decoration!.hintText,
          'Enter a unique name');
      expect(tester.getRect(field).width, 500);
      expect(tester.getRect(find.text('Description')).bottom,
          lessThan(tester.getRect(field).top));
      expect(tester.getRect(field).bottom,
          lessThan(tester.getRect(find.text('Members')).top));
      final membersTitle = find.text('Members');
      final arrow = find.byKey(const ValueKey('space-members-arrow'));
      expect(
          tester.getRect(arrow).left - tester.getRect(membersTitle).right, 4);
      expect(find.byType(AnimatedRotation), findsNothing);
      expect(tester.widget<Icon>(arrow).icon, Icons.expand_more);
      final tile =
          find.ancestor(of: membersTitle, matching: find.byType(ExpansionTile));
      expect(tester.widget<ExpansionTile>(tile).expansionAnimationStyle,
          AnimationStyle.noAnimation);
      final sectionTheme =
          find.ancestor(of: tile, matching: find.byType(Theme));
      final sectionThemeData = tester.widget<Theme>(sectionTheme.first).data;
      expect(sectionThemeData.hoverColor, Colors.transparent);
      expect(sectionThemeData.highlightColor, Colors.transparent);
      expect(sectionThemeData.splashColor, Colors.transparent);
      expect(sectionThemeData.splashFactory, NoSplash.splashFactory);

      for (final content in [
        find.byKey(const ValueKey('space-landing-name')),
        find.text('Description'),
        field,
      ]) {
        expect(tester.getRect(content).left, tester.getRect(membersTitle).left);
      }
      final memberDescription =
          find.text('Choose what each member can do in this Space.');
      expect(memberDescription, findsNothing);
      await tester.tap(membersTitle);
      await tester.pumpAndSettle();
      expect(memberDescription, findsOneWidget);
      expect(tester.widget<Icon>(arrow).icon, Icons.expand_less);
      expect(find.byType(DataTable), findsOneWidget);
      await tester.tap(membersTitle);
      await tester.pumpAndSettle();
      expect(memberDescription, findsNothing);
      expect(tester.widget<Icon>(arrow).icon, Icons.expand_more);
      await tester.enterText(field, '  New name  ');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Create Thread'));
      await tester.pumpAndSettle();
      expect(name, 'New name');
      expect(opened, thread);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'duplicate names including archived Threads show a red inline error and block creation',
      (tester) async {
    var calls = 0;
    await pump(tester, create: (_) async {
      calls++;
      return thread;
    }, open: (_) {});
    final field = find.byKey(const ValueKey('new-thread-name'));
    await tester.enterText(field, '  EXISTING  ');
    await tester.pumpAndSettle();
    final error =
        find.text('A Thread with this name already exists in this Space.');
    expect(error, findsOneWidget);
    final errorText = tester.widget<Text>(error);
    expect(errorText.style!.color,
        Theme.of(tester.element(field)).colorScheme.error);
    expect(
        tester
            .widget<TextButton>(
                find.widgetWithText(TextButton, 'Create Thread'))
            .onPressed,
        isNull);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.enterText(field, 'Different');
    await tester.pumpAndSettle();
    expect(error, findsNothing);
    expect(
        tester
            .widget<TextButton>(
                find.widgetWithText(TextButton, 'Create Thread'))
            .onPressed,
        isNotNull);
  });
  testWidgets(
      'server creation failure stays below the field and preserves the name',
      (tester) async {
    await pump(tester,
        create: (_) async =>
            throw StateError('This Space already has a Thread with this name'),
        open: (_) {});
    final field = find.byKey(const ValueKey('new-thread-name'));
    await tester.enterText(field, 'New');
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Create Thread'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('This Space already has a Thread with this name'),
        findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, 'New');
  });
}
