import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/features/profile/account_plan.dart';
import 'package:syntila_app/src/features/profile/subscription_page.dart';
import 'package:syntila_app/src/features/workspace/workspace_sharing_section.dart';

import 'workspace_sharing_test.dart' show PlanSource, SharingSource;

class _PlanSource implements AxAccountPlanDataSource {
  @override
  Future<AxAccountPlan> loadAccountPlan() async =>
      const AxAccountPlan(isPaid: true);
}

class _FailedPlanSource implements AxAccountPlanDataSource {
  @override
  Future<AxAccountPlan> loadAccountPlan() async => throw StateError('offline');
}

Future<void> _pumpPage(
  WidgetTester tester,
  AxAccountPlan plan, {
  Size size = const Size(1280, 900),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: SubscriptionPage(plan: plan)));
  await tester.pumpAndSettle();
}

String _currentPlanText(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(
        of: find.byKey(const ValueKey('subscription-current-plan')),
        matching: find.byType(Text)))
    .map((text) => text.data)
    .join('\n');

void main() {
  testWidgets('an unavailable account plan is not presented as Free',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AccountPlanSummary(source: _FailedPlanSource()))));
    await tester.pumpAndSettle();
    expect(find.text('Plan unavailable'), findsOneWidget);
    expect(find.text('Free'), findsNothing);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'View plans'))
            .onPressed,
        isNull);
  });

  testWidgets('profile opens plans with the current server plan',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AccountPlanSummary(source: _PlanSource()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View plans'));
    await tester.pumpAndSettle();
    expect(_currentPlanText(tester), contains('Syntila Plus'));
  });

  testWidgets('Free sees the prices and no purchase action', (tester) async {
    await _pumpPage(
        tester,
        const AxAccountPlan(
            isPaid: false,
            ownedWorkspaces: 1,
            workspaceLimit: 1,
            attachmentStorageBytes: 1000000000,
            attachmentMaxFileBytes: 25000000));
    final current = _currentPlanText(tester);
    expect(current, contains('Free'));
    expect(current, contains('1 of 1 personal Workspace used'));
    expect(current, contains('1 GB upload storage'));
    expect(find.textContaining('week'), findsNothing);
    expect(find.textContaining(r'$9'), findsOneWidget);
    expect(find.textContaining(r'$81'), findsOneWidget);
    expect(find.textContaining('Save 25%'), findsOneWidget);
    expect(find.textContaining('not available yet'), findsOneWidget);
    // Nothing can be bought, so nothing looks like it can be.
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    // Removed and unlimited-sounding features are not advertised.
    expect(find.textContaining('plugin'), findsNothing);
    expect(find.textContaining('nlimited'), findsNothing);
  });

  testWidgets('Plus shows how long access lasts, without a renewal promise',
      (tester) async {
    await _pumpPage(
        tester,
        AxAccountPlan(
            isPaid: true,
            status: 'active',
            currentPeriodEnd: DateTime.utc(2027, 3, 15, 12)));
    expect(_currentPlanText(tester), contains('Active until'));
    expect(find.textContaining('Renews'), findsNothing);
    expect(
        find.textContaining('Your account has Syntila Plus'), findsOneWidget);

    await _pumpPage(
        tester,
        AxAccountPlan(
            isPaid: true,
            status: 'past_due',
            currentPeriodEnd: DateTime.utc(2027, 3, 15, 12)));
    expect(_currentPlanText(tester), contains('Payment needs attention'));

    // An open-ended grant has no end date to show.
    await _pumpPage(tester, const AxAccountPlan(isPaid: true));
    expect(_currentPlanText(tester), contains('Active'));
    expect(_currentPlanText(tester), isNot(contains('until')));
  });

  testWidgets('the comparison reads row by row for screen readers',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpPage(tester, const AxAccountPlan(isPaid: true));
    expect(find.text('Your plan'), findsOneWidget); // the plan card only
    expect(
        find.bySemanticsLabel(RegExp(
            r'People per Space\. Free: 4\. Syntila Plus: No plan limit\. Including the owner')),
        findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'1 year: 81 US dollars')),
        findsOneWidget);
    // Icons stand in for the repeated words; the words stay for screen readers.
    expect(find.text('Included'), findsNothing);
    expect(find.text('No plan limit'), findsNothing);
    expect(find.byTooltip('Not included'), findsNWidgets(3));
    expect(
        find.bySemanticsLabel(RegExp(
            r'Share Workers with Space members\. Free: Included\. Syntila Plus: Included\.')),
        findsOneWidget);
    expect(
        find.bySemanticsLabel(RegExp(
            r'Share a Workspace with a person\. Free: Not included\. Syntila Plus: Included\.')),
        findsOneWidget);
    handle.dispose();
  });

  for (final (size, scale) in const [
    (Size(320, 640), 1.0),
    (Size(360, 800), 1.3),
    (Size(360, 800), 2.0),
    (Size(1280, 900), 1.3),
  ]) {
    testWidgets('lays out at ${size.width.toInt()} wide, text scale $scale',
        (tester) async {
      await _pumpPage(tester, AxAccountPlan.free, size: size, textScale: scale);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('If your plan changes'), 300,
          scrollable: find.byType(Scrollable).first);
      expect(tester.takeException(), isNull);
      expect(find.text('25 GB'), findsOneWidget);
      expect(find.text('100 MB'), findsOneWidget);
      // Every line of text stays inside the screen.
      for (final element in find.byType(RichText).evaluate()) {
        final box = element.renderObject! as RenderBox;
        final right = box.localToGlobal(Offset(box.size.width, 0)).dx;
        expect(right, lessThanOrEqualTo(size.width + 0.5));
      }
    });
  }

  testWidgets('a locked Plus feature links to the plans', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkspaceSharingSection(
                    workspaceId: 'w',
                    source: SharingSource(),
                    planSource: PlanSource(AxAccountPlan.free))))));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('sharing-requires-paid')),
        matching: find.text('View plans')));
    await tester.pumpAndSettle();
    expect(find.text('Compare plans'), findsOneWidget);
    expect(_currentPlanText(tester), contains('Free'));
  });
}
