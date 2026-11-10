import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/app_shell.dart';
import 'package:syntila_app/src/features/navigation/ax_top_bar.dart';
import 'package:syntila_app/src/platform/platform_services.dart';

import 'ax_fixture_data.dart';

void main() {
  testWidgets('mobile shell keeps its header below the system inset',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const SyntilaAppShell(
      services: DefaultPlatformServices(),
      dataSource: AxFixtureDataSource(),
    ));
    await tester.pumpAndSettle();

    final header = find.byType(AxTopBar);
    expect(header, findsOneWidget);
    expect(tester.getTopLeft(header).dy, greaterThanOrEqualTo(59));
    final search = find.byTooltip('Search');
    expect(search, findsOneWidget);
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
