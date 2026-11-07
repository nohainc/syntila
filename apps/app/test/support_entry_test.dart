import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/sync/ax_support.dart';
import 'package:syntila_app/src/features/settings/settings_page.dart';
import 'package:syntila_app/src/platform/view_preferences.dart';

class _FakeSupport implements AxSupportDataSource {
  bool hidden = true;
  String? spaceId;
  int ensureCalls = 0;
  bool failNext = false;

  @override
  Future<AxSupportSpace> loadSupportSpace() async =>
      AxSupportSpace(spaceId: spaceId, hidden: hidden);

  @override
  Future<AxSupportSpace> ensureSupportSpace() async {
    ensureCalls++;
    if (failNext) {
      failNext = false;
      throw StateError('offline');
    }
    spaceId ??= 'space-direct-support';
    return AxSupportSpace(spaceId: spaceId, hidden: hidden);
  }

  @override
  Future<void> setSpaceHidden(
      {required String spaceId, required bool hidden}) async {
    this.hidden = hidden;
  }
}

void main() {
  test('open provisions on demand and ignores sidebar visibility', () async {
    final source = _FakeSupport();
    expect(await AxSupportEntry(source).open(), 'space-direct-support');
    expect(source.hidden, isTrue);
  });

  test('open surfaces failures so callers can retry', () async {
    final source = _FakeSupport()..failNext = true;
    final entry = AxSupportEntry(source);
    await expectLater(entry.open(), throwsStateError);
    expect(await entry.open(), 'space-direct-support');
  });

  testWidgets('settings switch persists visibility and offers retry',
      (tester) async {
    final source = _FakeSupport();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: SettingsPage(
      preferences: const ViewPreferences(),
      onChanged: (_) {},
      support: AxSupportEntry(source),
    )))));
    await tester.pumpAndSettle();
    final switchFinder = find.byKey(const ValueKey('setting-show-support'));
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);

    source.failNext = true;
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('setting-show-support-error')),
        findsOneWidget);
    expect(source.hidden, isTrue);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(source.hidden, isFalse);
    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
  });

  testWidgets('settings omits the switch without a support source',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: SettingsPage(
                    preferences: const ViewPreferences(),
                    onChanged: (_) {})))));
    expect(find.byKey(const ValueKey('setting-show-support')), findsNothing);
  });
}
