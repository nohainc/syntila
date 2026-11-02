import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/features/spaces/space_member_usage.dart';

class _Usage implements AxSpaceMemberUsageDataSource {
  _Usage(this.usage);
  AxSpaceMemberUsage usage;

  @override
  Future<AxSpaceMemberUsage> loadSpaceMemberUsage(
          {required String spaceId}) async =>
      usage;
}

Future<void> _pump(
  WidgetTester tester,
  AxSpaceMemberUsage usage, {
  required bool isOwner,
  required int members,
  required int pending,
}) async {
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SpaceMemberUsageNote(
    key: UniqueKey(),
    source: _Usage(usage),
    spaceId: 'S',
    isOwner: isOwner,
    members: members,
    pendingInvitations: pending,
  ))));
  await tester.pumpAndSettle();
}

void main() {
  test('summarizes members, pending reservations and the allowance', () {
    expect(
        SpaceMemberUsageNote.summary(
            members: 3, pendingInvitations: 1, limit: 4),
        '3 members · 1 pending invitation · 4 people allowed.');
    expect(
        SpaceMemberUsageNote.summary(
            members: 1, pendingInvitations: 0, limit: 4),
        '1 member · 4 people allowed.');
  });

  test('parses usage, where a null limit means no member cap', () {
    final plus = AxSpaceMemberUsage.fromJson(
        {'members': 6, 'pendingInvitations': 2, 'limit': null});
    expect(plus.limit, isNull);
    expect(plus.atLimit, isFalse);
    expect(
        const AxSpaceMemberUsage(members: 3, pendingInvitations: 1, limit: 4)
            .atLimit,
        isTrue);
  });

  testWidgets('explains the limit to the owner and to other members',
      (tester) async {
    const usage =
        AxSpaceMemberUsage(members: 3, pendingInvitations: 1, limit: 4);
    await _pump(tester, usage, isOwner: true, members: 3, pending: 1);
    expect(find.text('3 members · 1 pending invitation · 4 people allowed.'),
        findsOneWidget);
    expect(find.textContaining('Upgrade to Syntila Plus'), findsOneWidget);
    expect(find.textContaining('Free includes up to 4 people in each Space'),
        findsOneWidget);

    await _pump(tester, usage, isOwner: false, members: 3, pending: 1);
    expect(find.textContaining('owner needs to upgrade or free a slot'),
        findsOneWidget);
    expect(find.textContaining('Upgrade to Syntila Plus'), findsNothing);
  });

  testWidgets(
      'shows nothing below the limit message, and nothing when uncapped',
      (tester) async {
    await _pump(tester,
        const AxSpaceMemberUsage(members: 2, pendingInvitations: 0, limit: 4),
        isOwner: true, members: 2, pending: 0);
    expect(find.text('2 members · 4 people allowed.'), findsOneWidget);
    expect(find.textContaining('Free includes'), findsNothing);

    await _pump(
        tester, const AxSpaceMemberUsage(members: 9, pendingInvitations: 0),
        isOwner: true, members: 9, pending: 0);
    expect(find.byKey(const ValueKey('space-member-usage')), findsNothing);
    expect(find.textContaining('nlimited'), findsNothing);
  });
}
