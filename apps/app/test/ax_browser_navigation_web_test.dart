@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/navigation/ax_browser_navigation.dart';

void main() {
  test('browser history restores different resources with the same address',
      () async {
    final nav = createAxBrowserNavigation();
    final first = Uri.parse('/spaces/s/threads/one');
    final second = Uri.parse('/spaces/s/threads/two');
    nav.replace(first);
    expect(html.window.location.pathname, '/thread');
    expect(nav.current, first);
    nav.push(second);
    expect(html.window.location.pathname, '/thread');
    expect(nav.current, second);
    final previous = nav.changes.first.timeout(const Duration(seconds: 5));
    html.window.history.back();
    expect(await previous, first);
    final next = nav.changes.first.timeout(const Duration(seconds: 5));
    html.window.history.forward();
    expect(await next, second);
    nav.dispose();
  });

  test('old links and login return targets are cleaned and restored', () {
    final nav = createAxBrowserNavigation();
    html.window.history.replaceState(null, '', '/spaces/s/threads/t');
    expect(nav.current.path, '/spaces/s/threads/t');
    expect(html.window.location.pathname, '/thread');
    nav.replaceWithLogin(Uri.parse('/spaces/s/threads/t'));
    expect(html.window.location.href, isNot(contains('/spaces/s/threads/t')));
    expect(nav.current.queryParameters['returnTo'], '/spaces/s/threads/t');
    nav.dispose();
  });

  test('OAuth return restores a saved route and persists it in history', () {
    final nav = createAxBrowserNavigation();
    html.window.sessionStorage['syntila-oauth-return-v1'] =
        '/spaces/s/threads/t';
    html.window.history.replaceState(null, '', '/thread');
    expect(nav.current.path, '/spaces/s/threads/t');
    expect(html.window.sessionStorage['syntila-oauth-return-v1'], isNull);
    expect(nav.current.path, '/spaces/s/threads/t');
    nav.dispose();
  });
}
