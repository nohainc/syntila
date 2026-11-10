import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/navigation/ax_browser_route.dart';

void main() {
  test('detail routes hide identifiers and restore from their history entry',
      () {
    for (final entry in {
      '/spaces/space-id': '/space',
      '/spaces/space-id/members': '/space/members',
      '/spaces/space-id/threads/thread-id': '/thread',
      '/spaces/space-id/threads/thread-id/runs/run-id': '/run',
      '/spaces/space-id/runs/run-id': '/run',
      '/workspaces/workspace-id': '/workspaces',
    }.entries) {
      final route = Uri.parse(entry.key);
      final address = AxBrowserRoute.visible(route);
      expect(address.toString(), entry.value);
      expect(AxBrowserRoute.restore(address, route.toString()), route);
    }
  });

  test('history state is tied to the address and missing state falls back', () {
    expect(AxBrowserRoute.restore(Uri.parse('/thread'), null).path, '/spaces');
    expect(
        AxBrowserRoute.restore(Uri.parse('/run'), '/spaces/s/threads/t').path,
        '/spaces');
    expect(AxBrowserRoute.restore(Uri.parse('/workspaces'), null).path,
        '/workspaces');
    expect(AxBrowserRoute.restore(Uri.parse('/spaces/threads'), null).path,
        '/spaces/threads');
  });

  test('login return targets are hidden while other login parameters survive',
      () {
    final login = Uri(path: '/login', queryParameters: {
      'returnTo': '/spaces/s/threads/t',
      'error': 'failed',
    });
    final visible = AxBrowserRoute.visible(login);
    expect(visible.toString(), '/login?error=failed');
    expect(AxBrowserRoute.restore(visible, login.toString()), login);
    expect(AxBrowserRoute.visible(Uri.parse('/login?returnTo=%2Fsettings')),
        Uri.parse('/login?returnTo=%2Fsettings'));
  });
}
