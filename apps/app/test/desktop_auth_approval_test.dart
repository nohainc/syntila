import 'package:flutter/material.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'package:syntila_app/src/ax/ax_app.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ax_fixture_data.dart';

class _SignedInDesktopAuthFixture extends AxFixtureDataSource {
  const _SignedInDesktopAuthFixture();

  @override
  Future<AxSession> loadSession() async => const AxSession(
        authenticated: true,
        viewer: AxViewer(
          id: 'user-1',
          displayName: 'Ada Lovelace',
          email: 'ada@example.test',
        ),
      );
}

class _CanceledDesktopAuthFixture extends _SignedInDesktopAuthFixture {
  @override
  Future<AxDesktopAuthIntentStatus> loadDesktopAuthIntentStatus(
          {required String intentId}) async =>
      const AxDesktopAuthIntentStatus(
        status: 'denied',
        clientName: 'Syntila Connect',
        audience: 'syntila.desktop.management',
      );
}

class _ProfileLabDesktopAuthFixture extends _SignedInDesktopAuthFixture {
  const _ProfileLabDesktopAuthFixture();

  @override
  Future<AxDesktopAuthIntentStatus> loadDesktopAuthIntentStatus(
          {required String intentId}) async =>
      const AxDesktopAuthIntentStatus(
        status: 'pending',
        clientName: 'untrusted caller label',
        audience: 'syntila.profile-lab.management',
      );
}

void main() {
  testWidgets('desktop approval uses the signed-in account without a code',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: const _SignedInDesktopAuthFixture(),
        initialUri: Uri(
          path: '/desktop-auth/approve',
          queryParameters: {'intentId': 'intent-1'},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Ada Lovelace'), findsOneWidget);
    expect(find.text('Approve sign-in'), findsOneWidget);
    expect(find.textContaining('code'), findsNothing);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('Approve sign-in'));
    await tester.pumpAndSettle();

    expect(find.text('Sign-in approved'), findsOneWidget);
    expect(find.text('Return to Syntila Connect to finish signing in.'),
        findsOneWidget);
    expect(
        find.text('You can close this page, window, or tab.'), findsOneWidget);
    expect(find.text('Close tab'), findsNothing);
  });

  testWidgets('approval names and returns to Profile Lab for its audience',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: const _ProfileLabDesktopAuthFixture(),
        initialUri: Uri(
          path: '/desktop-auth/approve',
          queryParameters: {'intentId': 'intent-profile-lab'},
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text('Sign in to Syntila Profile Lab'), findsOneWidget);
    expect(find.textContaining('Approve sign-in to Syntila Profile Lab'),
        findsOneWidget);
    expect(find.textContaining('Workspace'), findsNothing);

    await tester.tap(find.text('Approve sign-in'));
    await tester.pumpAndSettle();

    expect(find.text('Return to Syntila Profile Lab to finish signing in.'),
        findsOneWidget);
  });

  testWidgets('a remotely canceled intent explains how to close the page',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: _CanceledDesktopAuthFixture(),
        initialUri: Uri(
          path: '/desktop-auth/approve',
          queryParameters: {'intentId': 'intent-1'},
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('Sign-in canceled'), findsOneWidget);
    expect(
        find.text('You can close this page, window, or tab.'), findsOneWidget);
    expect(find.text('Close tab'), findsNothing);
  });

  testWidgets(
      'desktop approval view allows switching accounts and preserves approval return target',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: const _SignedInDesktopAuthFixture(),
        initialUri: Uri(
          path: '/desktop-auth/approve',
          queryParameters: {'intentId': 'intent-switch'},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Switch account'), findsOneWidget);
    await tester.tap(find.text('Switch account'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Syntila'), findsOneWidget);
    expect(
      find.text('Sign in to continue approving Syntila Connect.'),
      findsOneWidget,
    );
  });
}
