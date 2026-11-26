import 'package:flutter_test/flutter_test.dart';

import 'package:syntila_app/src/navigation/ax_navigation.dart';

void main() {
  test('retired product deep links do not masquerade as renamed routes', () {
    for (final path in [
      '/projects/S',
      '/projects/S/workstreams/T',
      '/spaces/S/workstreams/T'
    ]) {
      expect(AxNavigation.fromUri(Uri.parse(path)).kind, AxRouteKind.home);
    }
    expect(AxNavigation.fromUri(Uri.parse('/spaces/S/threads/T')).toUri().path,
        '/spaces/S/threads/T');
  });
  test('parses and serializes space, Thread, and run deep links', () {
    final thread =
        AxNavigation.fromUri(Uri.parse('/spaces/space-1/threads/thread-2'));
    expect(thread.kind, AxRouteKind.thread);
    expect(thread.threadId, 'thread-2');
    expect(thread.toUri().path, '/spaces/space-1/threads/thread-2');

    final legacyRun =
        AxNavigation.fromUri(Uri.parse('/spaces/space-1/runs/run-3'));
    expect(legacyRun.kind, AxRouteKind.run);
    expect(legacyRun.toUri().path, '/spaces/space-1/runs/run-3');

    final canonicalRun = AxNavigation.fromUri(
        Uri.parse('/spaces/space-1/threads/thread-2/runs/run-3'));
    expect(canonicalRun.kind, AxRouteKind.run);
    expect(canonicalRun.spaceId, 'space-1');
    expect(canonicalRun.threadId, 'thread-2');
    expect(canonicalRun.runId, 'run-3');
    expect(canonicalRun.toUri().path,
        '/spaces/space-1/threads/thread-2/runs/run-3');

    final profile = AxNavigation.fromUri(Uri.parse('/settings/profile'));
    expect(profile.kind, AxRouteKind.profileSecurity);
    expect(profile.toUri().path, '/settings/profile');
  });

  test('parses and serializes space resource pages', () {
    final workflows =
        AxNavigation.fromUri(Uri.parse('/spaces/space-1/workflows'));
    final members = AxNavigation.fromUri(Uri.parse('/spaces/space-1/members'));

    // Space-level Workflow settings were removed; the old link opens the Space.
    expect(workflows, const AxNavigation.space('space-1'));
    expect(workflows.toUri().path, '/spaces/space-1');
    expect(members, const AxNavigation.spaceMembers('space-1'));
    expect(members.toUri().path, '/spaces/space-1/members');
  });

  test('has stable routes for every major application section', () {
    final routes = <AxNavigation>[
      const AxNavigation.home(),
      const AxNavigation.spaces(),
      const AxNavigation.archivedSpaces(),
      const AxNavigation.workers(),
      const AxNavigation.profileSecurity(),
    ];

    for (final route in routes) {
      expect(AxNavigation.fromUri(route.toUri()), route);
    }
    expect(AxNavigation.fromUri(Uri.parse('/archived-spaces')).kind,
        AxRouteKind.archivedSpaces);
    // Old links open Workers.
    expect(AxNavigation.fromUri(Uri.parse('/workflows')),
        const AxNavigation.workers());
    expect(AxNavigation.fromUri(Uri.parse('/workers')),
        const AxNavigation.workers());
    expect(const AxNavigation.workers().toUri().path, '/workers');
    expect(const AxNavigation.workers(workerId: 'abc').toUri().path,
        '/workers/abc');
  });

  test('preserves desktop auth approval through the browser sign-in route', () {
    final approval = AxNavigation.fromUri(
      Uri.parse('/desktop-auth/approve?intentId=intent-123'),
    );
    expect(approval.kind, AxRouteKind.desktopAuthApproval);
    expect(approval.desktopAuthIntentId, 'intent-123');
    final login = AxNavigation.login(returnTo: approval.toUri().toString());
    final restored = AxNavigation.fromUri(Uri.parse(login.toUri().toString()));
    expect(AxNavigation.fromUri(Uri.parse(restored.loginReturnTo!)), approval);
  });

  test('preserves login reset token and OAuth error parameters without loops',
      () {
    final resetRoute = AxNavigation.fromUri(
      Uri.parse('/login?token=reset-tok-99&returnTo=%2Fspaces%2Fs1'),
    );
    expect(resetRoute.kind, AxRouteKind.login);
    expect(resetRoute.loginToken, 'reset-tok-99');
    expect(resetRoute.loginReturnTo, '/spaces/s1');
    expect(
      AxNavigation.fromUri(resetRoute.toUri()),
      resetRoute,
    );

    final errorRoute = AxNavigation.fromUri(
      Uri.parse('/login?error=account_not_linked&returnTo=%2Flogin'),
    );
    expect(errorRoute.kind, AxRouteKind.login);
    expect(errorRoute.loginError, 'account_not_linked');
    // Self-referential /login returnTo is normalized away.
    expect(errorRoute.loginReturnTo, isNull);
    expect(
      errorRoute.toUri().toString(),
      '/login?error=account_not_linked',
    );
  });
}
