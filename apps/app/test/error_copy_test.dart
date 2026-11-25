import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_app.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'ax_fixture_data.dart';

class _FailedReadModels extends AxFixtureDataSource {
  @override
  Future<AxSnapshot> loadBootstrapState({String? spaceId}) async =>
      throw const AxApiException(
          'Read model failed for /api/spaces/test/threads (400): ambiguous column name: updated_at');
}

void main() {
  testWidgets('copies full live-data error and recovery context',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(
        home: SyntilaAppShell(
            services: const DefaultPlatformServices(),
            dataSource: _FailedReadModels())));
    await tester.pumpAndSettle();
    expect(find.text('Syntila could not load live data'), findsOneWidget);
    await tester.tap(find.text('Copy error'));
    await tester.pump();
    expect(copied, contains('ambiguous column name: updated_at'));
    expect(copied, contains('/api/spaces/test/threads (400)'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
