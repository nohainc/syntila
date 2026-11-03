import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/features/profile/account_plan.dart';
import 'package:syntila_app/src/features/profile/subscription_page.dart';

class _PlanSource implements AxAccountPlanDataSource {
  @override
  Future<AxAccountPlan> loadAccountPlan() async =>
      const AxAccountPlan(isPaid: true);
}

class _FailedPlanSource implements AxAccountPlanDataSource {
  @override
  Future<AxAccountPlan> loadAccountPlan() async => throw StateError('offline');
}

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
    expect(find.text('Your current plan: Syntila Plus'), findsOneWidget);
    expect(find.text('1 week'), findsOneWidget);
    expect(find.text('1 month'), findsOneWidget);
    expect(find.text('1 year'), findsOneWidget);
    expect(find.text('Pricing coming soon'), findsNWidgets(3));
    for (final button
        in tester.widgetList<FilledButton>(find.byType(FilledButton))) {
      expect(button.onPressed, isNull);
    }
  });

  testWidgets('comparison remains accessible on a narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
        const MaterialApp(home: SubscriptionPage(plan: AxAccountPlan.free)));
    await tester.scrollUntilVisible(find.text('Uploaded storage'), 300);
    expect(find.text('Uploaded storage'), findsOneWidget);
    expect(find.text('25 GB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
