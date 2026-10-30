import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/features/navigation/ax_shell_context.dart';
import 'package:syntila_app/src/features/navigation/ax_sidebar.dart';
import 'package:syntila_app/src/features/settings/settings_page.dart';
import 'package:syntila_app/src/navigation/ax_navigation.dart';
import 'package:syntila_app/src/platform/view_preferences.dart';

void main() {
  test('settings route round-trips', () {
    expect(AxNavigation.fromUri(Uri(path: '/settings')).kind,
        AxRouteKind.settings);
    expect(const AxNavigation.settings().toUri().path, '/settings');
    expect(AxNavigation.fromUri(Uri(path: '/settings/profile')).kind,
        AxRouteKind.profileSecurity);
  });

  test('view preferences default, clamp, and survive bad storage', () {
    expect(ViewPreferences.decode(null), const ViewPreferences());
    expect(ViewPreferences.decode('not json'), const ViewPreferences());
    expect(
        ViewPreferences.decode('{"recentThreadsCount":500}').recentThreadsCount,
        10);
    expect(
        ViewPreferences.decode('{"recentThreadsCount":0}').recentThreadsCount,
        4);
    final saved =
        const ViewPreferences(showRecentThreads: false, recentThreadsCount: 4)
            .encode();
    expect(ViewPreferences.decode(saved).showRecentThreads, isFalse);
    expect(ViewPreferences.decode(saved).recentThreadsCount, 4);
    expect(
        ViewPreferences.decode('{"recentThreadsCount":8}').recentThreadsCount,
        7);
  });

  test('store persists preferences', () {
    String? raw;
    final store = ViewPreferencesStore(read: () => raw, write: (v) => raw = v);
    store.save(const ViewPreferences(recentThreadsCount: 10));
    expect(store.load().recentThreadsCount, 10);
  });

  testWidgets('settings page edits both options', (tester) async {
    var prefs = const ViewPreferences();
    late StateSetter set;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
      set = setState;
      return SettingsPage(
          preferences: prefs, onChanged: (next) => set(() => prefs = next));
    }))));

    await tester.tap(find.text('4'));
    await tester.pump();
    expect(prefs.recentThreadsCount, 4);

    await tester.tap(find.byKey(const ValueKey('setting-show-recent-threads')));
    await tester.pump();
    expect(prefs.showRecentThreads, isFalse);

    // The count is disabled while the section is hidden.
    await tester.tap(find.text('10'));
    await tester.pump();
    expect(prefs.recentThreadsCount, 4);
  });

  testWidgets('hidden recent threads leave the sidebar', (tester) async {
    Future<void> pump(ViewPreferences p) => tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: SpaceTree(
          shellContext: AxShellContext(
              navigation: const AxNavigation.home(),
              spaces: const [],
              viewPreferences: p),
          showRecentThreads: p.showRecentThreads,
          recentThreadsCount: p.recentThreadsCount,
          onNavigateTo: (_) {},
        ))));
    await pump(const ViewPreferences());
    expect(find.text('RECENT THREADS'), findsOneWidget);
    await pump(const ViewPreferences(showRecentThreads: false));
    expect(find.text('RECENT THREADS'), findsNothing);
  });
}
