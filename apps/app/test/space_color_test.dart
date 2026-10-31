import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/features/common/space_color.dart';

void main() {
  testWidgets('Space color can be selected and cleared', (tester) async {
    String? color;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
      builder: (context, setState) => SpaceColorSelector(
        value: color,
        onChanged: (value) => setState(() => color = value),
      ),
    ))));
    expect(find.text('No color'), findsOneWidget);
    expect(spaceIdentityColor(color, isDark: false), isNull);
    await tester.tap(find.byKey(const ValueKey('space-color-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Blue').last);
    await tester.pumpAndSettle();
    expect(color, 'Blue');
    expect(spaceIdentityColor(color, isDark: false), isNotNull);
    await tester.tap(find.byKey(const ValueKey('space-color-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No color').last);
    await tester.pumpAndSettle();
    expect(color, isNull);
    expect(spaceIdentityColor(color, isDark: true), isNull);
  });
}
