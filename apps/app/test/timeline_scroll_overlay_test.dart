import 'package:syntila_app/src/features/spaces/timeline_scroll_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_design/syntila_design.dart';

void main() {
  testWidgets('lazy variable-height history ends with last row above composer',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Column(children: [
      Expanded(
          child: TimelineScrollOverlay(
        controller: controller,
        onFollowLatest: () {},
        child: ListView.builder(
          controller: controller,
          itemCount: 100,
          itemBuilder: (_, index) => SizedBox(
            key: ValueKey('row-$index'),
            height: index < 50 ? 200 : 30,
            child: Text('Row $index'),
          ),
        ),
      )),
      const SizedBox(key: ValueKey('composer'), height: 100),
    ]))));
    final history = find.byType(ListView);
    await tester.drag(history, const Offset(0, -100));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('scroll-to-latest')));
    await tester.pumpAndSettle();
    expect(controller.position.pixels,
        closeTo(controller.position.maxScrollExtent, 1));
    expect(tester.getRect(find.byKey(const ValueKey('row-99'))).bottom,
        closeTo(tester.getRect(find.byKey(const ValueKey('composer'))).top, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'latest arrow follows reading direction and smoothly reaches bottom',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var follows = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: TimelineScrollOverlay(
              controller: controller,
              onFollowLatest: () => follows++,
              child: ListView(
                controller: controller,
                children: const [SizedBox(height: 3000)],
              ),
            ),
          ),
        ),
      ),
    ));
    final history = find.byType(ListView);
    final arrow = find.byKey(const ValueKey('scroll-to-latest'));
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(arrow, findsNothing);
    await tester.drag(history, const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(arrow, findsNothing);
    await tester.drag(history, const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(arrow, findsOneWidget);
    final surface = find.ancestor(of: arrow, matching: find.byType(Material));
    expect(tester.widget<Material>(surface.first).shape,
        SyntilaRadius.buttonShape);
    expect(tester.getCenter(arrow).dx, tester.getCenter(history).dx);
    expect(
        tester.getRect(arrow).bottom, lessThan(tester.getRect(history).bottom));
    await tester.drag(history, const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(arrow, findsNothing);
    await tester.drag(history, const Offset(0, -80));
    await tester.pumpAndSettle();
    await tester.tap(arrow);
    await tester.pump(const Duration(milliseconds: 100));
    expect(follows, 1);
    expect(controller.position.extentAfter, greaterThan(0));
    await tester.pumpAndSettle();
    expect(controller.position.extentAfter, closeTo(0, 1));
    expect(arrow, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
