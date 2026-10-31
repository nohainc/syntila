import 'package:syntila_design/syntila_design.dart';
import 'package:syntila_protocol/syntila_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const worker = WorkerSelectionCapability(id: 'worker', name: 'Worker', models: [
  ExecutionModelCapability(id: 'one', name: 'One', efforts: ['deep', 'brief']),
  ExecutionModelCapability(id: 'two', name: 'Two', efforts: ['deep']),
  ExecutionModelCapability(id: 'fast', name: 'Fast'),
]);
Finder picker(String label) => find.byWidgetPredicate((w) =>
    w is DropdownButtonFormField<String> &&
        (w.key as ValueKey<String>).value.startsWith('execution-$label-') ||
    w is MenuAnchor && w.key == ValueKey('execution-$label-menu'));
Future<void> choose(WidgetTester tester, String label, String text) async {
  await tester.tap(picker(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'unset combined effort accepts first point and model initializes effort',
      (tester) async {
    const combined =
        WorkerSelectionCapability(id: 'combined', name: 'Combined', models: [
      ExecutionModelCapability(
          id: 'model',
          name: 'Model',
          selectionMode: 'combined',
          efforts: ['low', 'high']),
      ExecutionModelCapability(id: 'plain', name: 'Plain'),
    ]);
    var selection =
        const ExecutionSelection(worker: 'combined', model: 'model');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
      alignment: Alignment.bottomLeft,
      child: StatefulBuilder(
          builder: (context, update) => ModelEffortSelector(
                compact: true,
                immediatePopup: true,
                catalog: const ExecutionSelectionCatalog([combined]),
                value: selection,
                onChanged: (next) => update(() => selection = next),
              )),
    ))));
    final open = find.byKey(const ValueKey('execution-open'));
    await tester.tap(open);
    await tester.pumpAndSettle();
    await tester
        .tapAt(tester.getTopLeft(find.byType(Slider)) + const Offset(24, 24));
    await tester.pumpAndSettle();
    expect(selection.effort, 'low');
    expect(find.byKey(const ValueKey('execution-popup')), findsNothing);
    await tester.tap(open);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plain'));
    await tester.pumpAndSettle();
    expect(selection.effort, isNull);
    await tester.tap(find.text('Model'));
    await tester.pumpAndSettle();
    expect(selection.effort, 'low');
    expect(find.text('Effort · Low'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('effort gesture applies selection and closes Work popup',
      (tester) async {
    var selection = const ExecutionSelection(
        worker: 'worker', model: 'one', effort: 'deep');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: StatefulBuilder(builder: (context, update) {
            return ModelEffortSelector(
              compact: true,
              immediatePopup: true,
              catalog: const ExecutionSelectionCatalog([worker]),
              value: selection,
              onChanged: (next) => update(() => selection = next),
            );
          }),
        ),
      ),
    ));
    final trigger = find.byKey(const ValueKey('execution-open'));
    final popup = find.byKey(const ValueKey('execution-popup'));
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    final slider = find.byType(Slider);
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveTo(tester.getTopRight(slider) + const Offset(-24, 24));
    await tester.pump();
    expect(popup, findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selection.effort, 'brief');
    expect(popup, findsNothing);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    expect(find.text('Effort · Brief'), findsOneWidget);
    await tester
        .tapAt(tester.getTopLeft(find.byType(Slider)) + const Offset(24, 24));
    await tester.pumpAndSettle();
    expect(selection.effort, isNull);
    expect(popup, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('usage and restore follow the wrapped worker layout',
      (tester) async {
    Future<void> open(int count) async {
      final workers = List.generate(
          count,
          (i) => WorkerSelectionCapability(
              id: 'w$i', name: 'Worker $i', state: CapabilityState.ready));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Align(
        alignment: Alignment.bottomLeft,
        child: ModelEffortSelector(
          compact: true,
          immediatePopup: true,
          catalog: ExecutionSelectionCatalog(workers),
          value: const ExecutionSelection(worker: 'w0'),
          onChanged: (_) {},
          onShowUsage: () {},
        ),
      ))));
      await tester.tap(find.byKey(const ValueKey('execution-open')));
      await tester.pumpAndSettle();
    }

    final usage = find.byKey(const ValueKey('execution-usage'));
    final restore = find.byKey(const ValueKey('execution-restore'));
    final separator = find.byKey(const ValueKey('execution-usage-separator'));
    await open(2);
    for (final button in [
      find.byKey(const ValueKey('execution-worker-w0')),
      usage,
      restore,
    ]) {
      expect(tester.getSize(button), const Size.square(32));
      final theme = IconButtonTheme.of(tester.element(button));
      expect(theme.style!.shape!.resolve({}), SyntilaRadius.buttonShape);
    }
    expect(tester.getCenter(usage).dy, tester.getCenter(restore).dy);
    expect(
        tester.getCenter(separator).dx, lessThan(tester.getCenter(usage).dx));
    expect(tester.getSize(separator).height, 24);
    await tester.tapAt(const Offset(790, 30));
    await tester.pumpAndSettle();
    await open(8);
    expect(
        tester.getCenter(find.byKey(const ValueKey('execution-worker-w7'))).dy,
        greaterThan(tester
            .getCenter(find.byKey(const ValueKey('execution-worker-w0')))
            .dy));
    expect(tester.getCenter(usage).dx, tester.getCenter(restore).dx);
    expect(tester.getCenter(usage).dy, lessThan(tester.getCenter(restore).dy));
    expect(
        tester.getCenter(separator).dx, lessThan(tester.getCenter(usage).dx));
    expect(tester.getSize(separator).height, 48);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Work popup applies effort model and worker choices immediately',
      (tester) async {
    const other =
        WorkerSelectionCapability(id: 'other', name: 'Other', models: [
      ExecutionModelCapability(
          id: 'other-model', name: 'Other model', efforts: ['low', 'high']),
    ]);
    final changes = <ExecutionSelection>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
      alignment: Alignment.bottomLeft,
      child: ModelEffortSelector(
        compact: true,
        immediatePopup: true,
        catalog: const ExecutionSelectionCatalog([
          worker,
          other,
          WorkerSelectionCapability(
              id: 'offline',
              name: 'Offline',
              state: CapabilityState.unavailable)
        ]),
        value: const ExecutionSelection(
            worker: 'worker', model: 'one', effort: 'deep'),
        onChanged: changes.add,
      ),
    ))));
    final trigger = find.byKey(const ValueKey('execution-open'));
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Done'), findsNothing);
    final surface = find.byKey(const ValueKey('execution-popup'));
    expect(tester.widget<Material>(surface).color,
        SyntilaColors.composerBackground(false));
    expect(tester.getBottomLeft(surface).dy,
        closeTo(tester.getTopLeft(trigger).dy - 8, 1));
    expect(tester.getTopLeft(find.byType(Slider)).dy,
        lessThan(tester.getTopLeft(find.text('One')).dy));
    expect(
        tester.getTopLeft(find.text('One')).dy,
        lessThan(tester
            .getTopLeft(find.byKey(const ValueKey('execution-worker-worker')))
            .dy));
    expect(
        find.byKey(const ValueKey('execution-worker-offline')), findsNothing);
    tester.widget<Slider>(find.byType(Slider)).onChanged!(2);
    await tester.pumpAndSettle();
    expect(changes.last.effort, 'brief');
    await tester.tap(find.text('Two'));
    await tester.pumpAndSettle();
    expect(changes.last.model, 'two');
    expect(
        tester
            .widget<Opacity>(find.descendant(
                of: find.byKey(const ValueKey('execution-worker-worker')),
                matching: find.byType(Opacity)))
            .opacity,
        1.0);
    expect(
        tester
            .widget<Opacity>(find.descendant(
                of: find.byKey(const ValueKey('execution-worker-other')),
                matching: find.byType(Opacity)))
            .opacity,
        0.45);
    await tester.tap(find.byKey(const ValueKey('execution-worker-other')));
    await tester.pumpAndSettle();
    expect(changes.last.worker, 'other');
    expect(
        tester
            .widget<Opacity>(find.descendant(
                of: find.byKey(const ValueKey('execution-worker-other')),
                matching: find.byType(Opacity)))
            .opacity,
        1.0);
    expect(
        tester
            .widget<Opacity>(find.descendant(
                of: find.byKey(const ValueKey('execution-worker-worker')),
                matching: find.byType(Opacity)))
            .opacity,
        0.45);
    expect(find.text('One'), findsNothing);
    await tester.tap(find.text('Other model'));
    await tester.pumpAndSettle();
    expect(changes.last.model, 'other-model');
    final restore = find.byKey(const ValueKey('execution-restore'));
    expect(
        tester.getCenter(restore).dx,
        greaterThan(tester
            .getCenter(find.byKey(const ValueKey('execution-worker-other')))
            .dx));
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(changes.last.worker, 'worker');
    expect(changes.last.model, 'one');
    expect(changes.last.effort, 'deep');
    expect(find.byKey(const ValueKey('execution-popup')), findsNothing);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('execution-worker-other')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other model'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(790, 5));
    await tester.pumpAndSettle();
    expect(changes.last.model, 'other-model');
    expect(tester.takeException(), isNull);
  });

  testWidgets('restore snapshots each opening including catalog metadata',
      (tester) async {
    var selection = const ExecutionSelection(
        worker: 'worker',
        model: 'one',
        effort: 'deep',
        catalogRevision: 'saved');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
      alignment: Alignment.bottomLeft,
      child: StatefulBuilder(
          builder: (context, update) => ModelEffortSelector(
                compact: true,
                immediatePopup: true,
                catalog: const ExecutionSelectionCatalog([worker]),
                value: selection,
                onChanged: (next) => update(() => selection = next),
              )),
    ))));
    final open = find.byKey(const ValueKey('execution-open'));
    final restore = find.byKey(const ValueKey('execution-restore'));
    await tester.tap(open);
    await tester.pumpAndSettle();
    tester.widget<Slider>(find.byType(Slider)).onChanged!(2);
    await tester.pumpAndSettle();
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(selection.catalogRevision, 'saved');
    expect(selection.effort, 'deep');
    expect(find.byKey(const ValueKey('execution-popup')), findsNothing);
    await tester.tap(open);
    await tester.pumpAndSettle();
    tester.widget<Slider>(find.byType(Slider)).onChanged!(2);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(790, 5));
    await tester.pumpAndSettle();
    expect(selection.effort, 'brief');
    await tester.tap(open);
    await tester.pumpAndSettle();
    tester.widget<Slider>(find.byType(Slider)).onChanged!(1);
    await tester.pumpAndSettle();
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(selection.effort, 'brief');
    expect(selection.catalogRevision, isNull);
    expect(find.byKey(const ValueKey('execution-popup')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Work popup respects field permissions', (tester) async {
    final changes = <ExecutionSelection>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
      alignment: Alignment.bottomLeft,
      child: ModelEffortSelector(
          compact: true,
          immediatePopup: true,
          allowWorkerChange: false,
          allowModelChange: false,
          allowEffortChange: false,
          catalog: const ExecutionSelectionCatalog([worker]),
          value: const ExecutionSelection(worker: 'worker', model: 'one'),
          onChanged: changes.add),
    ))));
    await tester.tap(find.byKey(const ValueKey('execution-open')));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(
        tester
            .widget<IconButton>(
                find.byKey(const ValueKey('execution-worker-worker')))
            .onPressed,
        isNull);
    for (final row
        in tester.widgetList<MenuItemButton>(find.byType(MenuItemButton))) {
      expect(row.onPressed, isNull);
    }
    expect(changes, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'catalog refresh preserves supported choices and exposes removed efforts',
    (tester) async {
      const selection = ExecutionSelection(
        worker: 'worker',
        model: 'one',
        effort: 'deep',
        catalogRevision: 'old',
      );
      final changes = <ExecutionSelection>[];
      Future<void> render(List<String> efforts) => tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ModelEffortSelector(
                  catalog: ExecutionSelectionCatalog([
                    WorkerSelectionCapability(
                      id: 'worker',
                      name: 'Worker',
                      catalogRevision: 'current',
                      models: [
                        ExecutionModelCapability(
                          id: 'one',
                          name: 'One',
                          efforts: efforts,
                        ),
                      ],
                    ),
                  ]),
                  value: selection,
                  onChanged: changes.add,
                ),
              ),
            ),
          );
      await render(['deep', 'brief']);
      expect(
        find.text('Worker catalog changed; refresh and confirm the selection.'),
        findsNothing,
      );
      expect(changes, isEmpty);
      await render(['brief']);
      expect(
        find.text(
          'The selected effort is not supported for this Worker and model.',
        ),
        findsOneWidget,
      );
      expect(changes, isEmpty);
      expect(selection.effort, 'deep');
      expect(selection.catalogRevision, 'old');
    },
  );

  test('effort labels agree for selectors and historical summaries', () {
    expect(executionEffortDisplayName('xhigh'), 'Extra High');
    expect(executionEffortDisplayName('medium'), 'Medium');
    expect(executionEffortDisplayName('provider-special'), 'Provider-special');
    expect(executionEffortDisplayName(null), '');
  });

  testWidgets('combined provider models require explicit model and effort',
      (tester) async {
    const gemini = WorkerSelectionCapability(
      id: 'gemini',
      name: 'Gemini',
      models: [
        ExecutionModelCapability(
          id: 'gemini-3.8-flash',
          name: 'Gemini 3.8 Flash',
          efforts: ['low', 'high'],
          selectionMode: 'combined',
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ModelEffortSelector(
          catalog: const ExecutionSelectionCatalog([gemini]),
          value: const ExecutionSelection(worker: 'gemini'),
          onChanged: (_) {},
        ),
      ),
    ));
    expect(find.text('Auto'), findsNothing);
    expect(find.text('Auto / Provider default'), findsNothing);
    expect(
        find.text('Select an explicit model for this Worker.'), findsOneWidget);
    await tester.tap(picker('Model'));
    await tester.pumpAndSettle();
    expect(find.text('Select Model...'), findsNWidgets(2));
    expect(find.text('Gemini 3.8 Flash'), findsOneWidget);
  });
  testWidgets('resolved summaries preserve field permissions and inheritance',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
      catalog: const ExecutionSelectionCatalog([worker]),
      value: const ExecutionSelection(),
      inherited: const ExecutionSelection(
          worker: 'worker', model: 'one', effort: 'deep'),
      allowWorkerChange: false,
      allowModelChange: false,
      helperMessage: 'A model change requires a new session.',
      onChanged: (_) {},
    ))));
    expect(
        find.text('Effective selection: Worker · One · Deep'), findsOneWidget);
    expect(find.text('Inherited: One'), findsOneWidget);
    expect(find.text('A model change requires a new session.'), findsOneWidget);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(picker('Worker'))
            .onChanged,
        isNull);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(picker('Model'))
            .onChanged,
        isNull);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(picker('Effort'))
            .onChanged,
        isNotNull);
  });
  testWidgets('model changes retain supported efforts and explain a reset',
      (tester) async {
    var value = const ExecutionSelection(
        worker: 'worker', model: 'one', effort: 'deep');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
                builder: (context, setState) => ModelEffortSelector(
                    catalog: const ExecutionSelectionCatalog([worker]),
                    value: value,
                    onChanged: (next) => setState(() => value = next))))));
    await choose(tester, 'Model', 'Two');
    expect(value.effort, 'deep');
    await choose(tester, 'Model', 'Fast');
    expect(value.effort, isNull);
    expect(find.textContaining('Effort reset to Auto'), findsOneWidget);
  });
  testWidgets(
      'refresh preserves unavailable saved selections without emitting changes',
      (tester) async {
    var changes = 0;
    const value = ExecutionSelection(
        worker: 'worker', model: 'removed', effort: 'retired');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                catalog: const ExecutionSelectionCatalog([worker]),
                value: value,
                onChanged: (_) => changes++))));
    expect(find.text('removed · Unavailable'), findsOneWidget);
    expect(find.text('retired · Unavailable'), findsOneWidget);
    expect(changes, 0);
    await choose(tester, 'Model', 'One');
    expect(changes, 1);
  });
  testWidgets('read-only mode exposes the matrix and disables editing',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                showWorker: false,
                readOnly: true,
                catalog: ExecutionSelectionCatalog([worker]),
                value: ExecutionSelection(worker: 'worker')))));
    expect(find.text('One · Deep, Brief · Listed'), findsOneWidget);
    for (final dropdown in tester.widgetList<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>))) {
      expect(dropdown.onChanged, isNull);
    }
  });
  testWidgets('loading, stale, unavailable and unsupported states are explicit',
      (tester) async {
    for (final state in CapabilityState.values) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ModelEffortSelector(
                  catalog: ExecutionSelectionCatalog([
                    WorkerSelectionCapability(
                        id: 'worker', name: 'Worker', state: state)
                  ]),
                  value: const ExecutionSelection(worker: 'worker'),
                  onChanged: (_) {}))));
      if (state == CapabilityState.loading)
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
      if (state == CapabilityState.stale)
        expect(find.textContaining('capabilities are stale'), findsOneWidget);
      if (state == CapabilityState.unavailable)
        expect(find.textContaining('options are unavailable'), findsOneWidget);
      if (state == CapabilityState.unsupported)
        expect(find.textContaining('Model selection is unsupported'),
            findsOneWidget);
    }
  });
  testWidgets(
      'inheritance is visible and Auto is never a guessed concrete choice',
      (tester) async {
    ExecutionSelection? result;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                catalog: const ExecutionSelectionCatalog([worker]),
                value: const ExecutionSelection(),
                inherited: const ExecutionSelection(
                    worker: 'worker', model: 'one', effort: 'deep'),
                onChanged: (next) => result = next))));
    expect(find.text('Inherited: One'), findsOneWidget);
    await choose(tester, 'Model', 'Two');
    expect(result!.worker, isNull);
    expect(result!.effort, isNull);
  });
  testWidgets(
      'native dropdowns support keyboard focus, selection and semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();

    ExecutionSelection? result;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                showWorker: false,
                catalog: const ExecutionSelectionCatalog([worker]),
                value: const ExecutionSelection(worker: 'worker'),
                onChanged: (next) => result = next))));
    expect(find.bySemanticsLabel(RegExp('Model')), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result?.model, 'one');
    semantics.dispose();
  });
  testWidgets('compact host opens the same accessible selector',
      (tester) async {
    ExecutionSelection? result;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                compact: true,
                catalog: const ExecutionSelectionCatalog([worker]),
                value: const ExecutionSelection(worker: 'worker'),
                onChanged: (next) => result = next))));
    await tester.tap(find.byKey(const ValueKey('execution-open')));
    await tester.pumpAndSettle();
    expect(find.byType(ModelEffortSelector), findsNWidgets(2));
    expect(picker('Model'), findsOneWidget);
    expect(find.text('Explicit selection'), findsNothing);
    expect(find.text('Auto / Provider default'), findsNothing);
    expect(find.text('Effort choices depend on the model.'), findsNothing);
    await choose(tester, 'Model', 'Two');
    expect(result, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);

    await tester.tap(find.byKey(const ValueKey('execution-open')));
    await tester.pumpAndSettle();
    await choose(tester, 'Model', 'Two');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(result?.model, 'two');
  });
  for (final brightness in Brightness.values) {
    testWidgets('compact popup uses composer surface in $brightness',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: ModelEffortSelector(
              compact: true,
              catalog: const ExecutionSelectionCatalog([worker]),
              value: const ExecutionSelection(
                  worker: 'worker', model: 'one', effort: 'deep'),
              onChanged: (_) {},
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('execution-open')));
      await tester.pumpAndSettle();
      final isDark = brightness == Brightness.dark;
      expect(
        find.byWidgetPredicate((widget) =>
            widget is Material &&
            widget.color == SyntilaColors.composerBackground(isDark) &&
            widget.shape == SyntilaMenuStyle.shape(isDark) &&
            widget.elevation == 12 &&
            widget.surfaceTintColor == Colors.transparent),
        findsOneWidget,
      );
      final surface = find.byWidgetPredicate((widget) =>
          widget is Material && widget.shape == SyntilaMenuStyle.shape(isDark));
      expect(
          tester.getBottomLeft(surface).dy,
          closeTo(
              tester
                      .getTopLeft(find.byKey(const ValueKey('execution-open')))
                      .dy -
                  8,
              1));
      for (final label in ['Worker', 'Model', 'Effort']) {
        await tester.tap(picker(label));
        await tester.pumpAndSettle();
        final anchor = tester.widget<MenuAnchor>(picker(label));
        expect(
            anchor.style?.shape?.resolve({}), SyntilaMenuStyle.shape(isDark));
        expect(anchor.style?.backgroundColor?.resolve({}),
            SyntilaColors.composerBackground(isDark));
        final option = anchor.menuChildren.whereType<MenuItemButton>().last;
        expect(option.style?.overlayColor?.resolve({WidgetState.hovered}),
            SyntilaColors.navigationHover(isDark));
        // Escape closes the option menu while keeping settings open.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Done'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('composer prompts for a Worker when saved Worker is removed',
      (tester) async {
    const saved =
        ExecutionSelection(worker: 'worker', model: 'one', effort: 'deep');
    final changes = <ExecutionSelection>[];
    Future<void> render(List<WorkerSelectionCapability> workers) =>
        tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: Align(
                    alignment: Alignment.bottomLeft,
                    child: ModelEffortSelector(
                      compact: true,
                      immediatePopup: true,
                      showWorkerInCompactSummary: false,
                      catalog: ExecutionSelectionCatalog(workers),
                      value: saved,
                      onChanged: changes.add,
                    )))));

    await render([worker]);
    expect(find.text('One · Deep'), findsOneWidget);
    await render([]);
    expect(find.text('Select a Worker'), findsOneWidget);
    expect(find.textContaining('Unavailable'), findsNothing);
    expect(find.text('One · Deep'), findsNothing);
    expect(changes, isEmpty);

    // The placeholder still opens the picker, including after inventory returns.
    await tester.tap(find.byKey(const ValueKey('execution-open')));
    await tester.pumpAndSettle();
    expect(find.text('No models available'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await render([worker]);
    expect(find.text('One · Deep'), findsOneWidget);
    expect(changes, isEmpty);
  });

  testWidgets('composer with no saved selection prompts for a Worker',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                compact: true,
                showWorkerInCompactSummary: false,
                catalog: const ExecutionSelectionCatalog([]),
                value: const ExecutionSelection(),
                onChanged: (_) {}))));
    expect(find.text('Select a Worker'), findsOneWidget);
    expect(find.textContaining('Select model'), findsNothing);
  });

  testWidgets('compact result can show only model and effort', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                compact: true,
                showWorkerInCompactSummary: false,
                workerIconBuilder: (selected) => Icon(Icons.smart_toy_outlined,
                    key: ValueKey('selected-icon-${selected.id}')),
                catalog: const ExecutionSelectionCatalog([worker]),
                value: const ExecutionSelection(
                    worker: 'worker', model: 'one', effort: 'deep'),
                onChanged: (_) {}))));
    expect(find.text('One · Deep'), findsOneWidget);
    expect(find.textContaining('Worker'), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('execution-open')),
            matching: find.byKey(const ValueKey('selected-icon-worker'))),
        findsOneWidget);
    final icon = tester.widget<Semantics>(
        find.byKey(const ValueKey('execution-selected-worker-icon')));
    expect(icon.properties.label, 'Worker');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'compact result uses modelIconBuilder and compactModelLabelBuilder',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                compact: true,
                showWorkerInCompactSummary: false,
                workerIconBuilder: (selected) =>
                    const Icon(Icons.smart_toy_outlined),
                modelIconBuilder: (selectedWorker, modelId, modelName) => Icon(
                    Icons.auto_awesome,
                    key: ValueKey('model-icon-$modelId')),
                compactModelLabelBuilder: (modelId, modelName) =>
                    'Short-$modelName',
                catalog: const ExecutionSelectionCatalog([worker]),
                value: const ExecutionSelection(
                    worker: 'worker', model: 'one', effort: 'deep'),
                onChanged: (_) {}))));
    expect(find.text('Short-One · Deep'), findsOneWidget);
    expect(find.textContaining('Worker'), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('execution-open')),
            matching: find.byKey(const ValueKey('model-icon-one'))),
        findsOneWidget);
    final icon = tester.widget<Semantics>(
        find.byKey(const ValueKey('execution-selected-model-icon')));
    expect(icon.properties.label, 'Short-One');
    expect(tester.takeException(), isNull);
  });
  testWidgets('compact combined selections never render Auto', (tester) async {
    const gemini = WorkerSelectionCapability(
      id: 'gemini',
      name: 'Gemini',
      models: [
        ExecutionModelCapability(
          id: 'gemini-3.8-flash',
          name: 'Gemini 3.8 Flash',
          efforts: ['low', 'high'],
          selectionMode: 'combined',
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                compact: true,
                catalog: const ExecutionSelectionCatalog([gemini]),
                value: const ExecutionSelection(worker: 'gemini'),
                onChanged: (_) {}))));
    expect(find.textContaining('Auto'), findsNothing);
    expect(find.textContaining('Select model'), findsOneWidget);
    expect(find.textContaining('Select effort'), findsOneWidget);
  });

  testWidgets('compact popup height hugs its content', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: ModelEffortSelector(
            compact: true,
            catalog: const ExecutionSelectionCatalog([worker]),
            value: const ExecutionSelection(
                worker: 'worker', model: 'one', effort: 'deep'),
            onChanged: (_) {},
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('execution-open')));
    await tester.pumpAndSettle();
    final surface = find.byWidgetPredicate(
        (w) => w is Material && w.shape == SyntilaMenuStyle.shape(false));
    final done = tester.getBottomLeft(find.text('Done')).dy;
    final bottom = tester.getBottomLeft(surface).dy;
    // Done button + 16 padding + 6 menu padding, with small slack.
    expect(bottom - done, lessThan(40));
  });
}
