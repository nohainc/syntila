import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/features/profile/account_plan.dart';

class _Plans implements AxAccountPlanDataSource {
  _Plans(this.result);
  Object result;

  @override
  Future<AxAccountPlan> loadAccountPlan() async {
    final value = result;
    if (value is AxAccountPlan) return value;
    throw value;
  }
}

void main() {
  test('parses Cloud plans and keeps unknown tiers free', () {
    final paid = AxAccountPlan.fromJson({
      'tier': 'paid',
      'status': 'active',
      'currentPeriodEnd': '2026-11-30T00:00:00Z',
      'features': ['workflows.custom', 7],
    });
    expect(paid.isPaid, isTrue);
    expect(paid.has('workflows.custom'), isTrue);
    expect(paid.features, {'workflows.custom'});
    expect(paid.currentPeriodEnd, DateTime.utc(2026, 11, 30));
    expect(AxAccountPlan.fromJson({'tier': 'gold'}).isPaid, isFalse);
  });

  testWidgets('gates features by name and treats load failures as free',
      (tester) async {
    final source = _Plans(
        const AxAccountPlan(isPaid: true, features: {'workflows.custom'}));
    final controller = AccountPlanController(source);
    Widget gate(String feature) => PaidFeatureGate(
        controller: controller,
        feature: feature,
        locked: Text('locked $feature'),
        child: Text('open $feature'));
    await tester.pumpWidget(MaterialApp(
        home: Column(children: [gate('workflows.custom'), gate('other')])));
    expect(find.text('locked workflows.custom'), findsOneWidget);
    await controller.refresh();
    await tester.pump();
    expect(find.text('open workflows.custom'), findsOneWidget);
    expect(find.text('locked other'), findsOneWidget);
    source.result = Exception('offline');
    await controller.refresh();
    await tester.pump();
    expect(find.text('locked workflows.custom'), findsOneWidget);
  });

  testWidgets('profile shows Free or the paid plan name', (tester) async {
    Future<void> pump(AxAccountPlan plan) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body:
                  AccountPlanSummary(key: UniqueKey(), source: _Plans(plan)))));
      await tester.pumpAndSettle();
    }

    await pump(AxAccountPlan.free);
    expect(find.text('Free'), findsOneWidget);
    await pump(AxAccountPlan(
        isPaid: true,
        status: 'active',
        currentPeriodEnd: DateTime.utc(2026, 11, 30, 12)));
    expect(find.text(paidPlanName), findsOneWidget);
    expect(find.textContaining('Renews'), findsOneWidget);
  });

  test('parses the Workspace allowance, with null meaning unlimited', () {
    final free = AxAccountPlan.fromJson({
      'tier': 'free',
      'workspaces': {'owned': 3, 'limit': 1},
    });
    expect(free.ownedWorkspaces, 3);
    expect(free.workspaceLimit, 1);
    final plus = AxAccountPlan.fromJson({
      'tier': 'paid',
      'workspaces': {'owned': 4, 'limit': null},
    });
    expect(plus.workspaceLimit, isNull);
    expect(AxAccountPlan.fromJson({'tier': 'free'}).ownedWorkspaces, isNull);
  });

  testWidgets('allowance note explains the Free limit, and Plus is unlimited',
      (tester) async {
    Future<void> pump(AxAccountPlan plan) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: WorkspaceAllowanceNote(
                  key: UniqueKey(), source: _Plans(plan)))));
      await tester.pumpAndSettle();
    }

    await pump(const AxAccountPlan(
        isPaid: false, ownedWorkspaces: 0, workspaceLimit: 1));
    expect(find.text('0 of 1 personal Workspace used (Free)'), findsOneWidget);
    expect(find.textContaining('Upgrade to Syntila Plus'), findsNothing);

    await pump(const AxAccountPlan(
        isPaid: false, ownedWorkspaces: 1, workspaceLimit: 1));
    expect(
        find.text(
            'Free includes one personal Workspace. Upgrade to Syntila Plus to connect more machines.'),
        findsOneWidget);

    // Grandfathered over-limit accounts see their real count.
    await pump(const AxAccountPlan(
        isPaid: false, ownedWorkspaces: 3, workspaceLimit: 1));
    expect(find.text('3 of 1 personal Workspace used (Free)'), findsOneWidget);

    await pump(const AxAccountPlan(isPaid: true, ownedWorkspaces: 4));
    expect(find.text('4 personal Workspaces (Syntila Plus, no limit)'),
        findsOneWidget);
    expect(find.textContaining('Upgrade'), findsNothing);
  });
}
