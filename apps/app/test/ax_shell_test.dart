import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/brand.dart';
import 'package:syntila_app/src/features/navigation/ax_shell_context.dart';
import 'package:syntila_app/src/features/navigation/ax_sidebar.dart';
import 'package:syntila_app/src/features/navigation/ax_top_bar.dart';
import 'package:syntila_app/src/navigation/ax_navigation.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'package:syntila_app/src/platform/theme_preference.dart';
import 'package:syntila_app/src/app_shell.dart';
import 'package:syntila_app/src/ax/ax_models.dart';

import 'ax_fixture_data.dart';
import 'ax_fixture_realtime.dart';

void main() {
  for (final width in [140.0, 200.0, 220.0, 320.0]) {
    testWidgets('sidebar icon header opens search at width $width',
        (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      var query = '';
      var created = false;
      var notified = false;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
            width: width,
            child: AxSidebar(
              shellContext: const AxShellContext(
                  navigation: AxNavigation.home(), spaces: []),
              onNavigateTo: (_) {},
              onCreateSpace: () => created = true,
              onOpenNotifications: () => notified = true,
              searchController: controller,
              searchFocusNode: focus,
              onSearchChanged: (value) => query = value,
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            )),
      ))));
      await tester.pumpAndSettle();
      expect(find.text('Syntila'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      final home = find.byTooltip('Syntila — Home');
      final search = find.byTooltip('Search...');
      final add = find.byTooltip('New Space');
      final alarm = find.byTooltip('Notifications');
      if (width >= 220) {
        for (final action in [search, add, alarm]) {
          expect(tester.getCenter(action).dy, tester.getCenter(home).dy);
        }
        expect(tester.getCenter(search).dx,
            greaterThan(tester.getCenter(home).dx));
        expect(
            tester.getCenter(add).dx, greaterThan(tester.getCenter(search).dx));
        expect(
            tester.getCenter(alarm).dx, greaterThan(tester.getCenter(add).dx));
      }
      await tester.tap(add);
      await tester.tap(alarm);
      expect(created, isTrue);
      expect(notified, isTrue);
      await tester.tap(search);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(focus.hasFocus, isTrue);
      await tester.enterText(find.byType(TextField), 'design');
      expect(query, 'design');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(controller.text, isEmpty);
      expect(query, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });
  }

  for (final theme in [SyntilaBrand.lightTheme(), SyntilaBrand.darkTheme()]) {
    testWidgets(
        'login presentation uses matching branded buttons in ${theme.brightness}',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: const SyntilaAppShell(
          services: DefaultPlatformServices(),
          dataSource: AxFixtureDataSource(authenticated: false),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('Sign in securely'), findsNothing);
      final forgot = find.text('Forgot password?');
      final email = find.widgetWithText(TextField, 'Email');
      final emailInput = tester.widget<EditableText>(
        find.descendant(of: email, matching: find.byType(EditableText)),
      );
      expect(emailInput.focusNode.hasFocus, isTrue);
      expect(tester.getCenter(forgot).dx, tester.getCenter(email).dx);
      for (final provider in ['github', 'google']) {
        final label = provider == 'github' ? 'GitHub' : 'Google';
        final button =
            find.widgetWithText(OutlinedButton, 'Continue with $label');
        expect(button, findsOneWidget);
        expect(
            find.descendant(
                of: button,
                matching: find.byWidgetPredicate((widget) =>
                    widget is Image &&
                    widget.image is AssetImage &&
                    (widget.image as AssetImage).assetName ==
                        'assets/auth/$provider.png')),
            findsOneWidget);
      }
      expect(
          tester.getSize(
              find.widgetWithText(OutlinedButton, 'Continue with GitHub')),
          tester.getSize(
              find.widgetWithText(OutlinedButton, 'Continue with Google')));
      await tester.tap(forgot);
      await tester.pumpAndSettle();
      expect(find.text('Restore your password'), findsOneWidget);
      expect(
          find.textContaining('Enter your email and we will send a reset link'),
          findsOneWidget);
      expect(find.text('Continue with Google'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final collapsed in [false, true]) {
    testWidgets('sidebar suppresses hover hints collapsed=$collapsed',
        (tester) async {
      const shell = AxShellContext(navigation: AxNavigation.home(), spaces: []);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
        body: collapsed
            ? AxIconRail(
                shellContext: shell,
                onNavigateTo: (_) {},
                onOpenDrawer: () {},
                onLogout: () {},
                onOpenAbout: () {},
                onOpenExternal: (_) {})
            : SizedBox(
                width: 250,
                child: AxSidebar(
                    shellContext: shell,
                    onNavigateTo: (_) {},
                    onLogout: () {},
                    onOpenAbout: () {},
                    onOpenExternal: (_) {})),
      )));
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(799, 599));
      final applicationMenu = find.byTooltip('Application menu');
      expect(TooltipVisibility.of(tester.element(applicationMenu)), isFalse);
      await mouse.moveTo(tester.getCenter(applicationMenu));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Application menu'), findsNothing);
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Application menu'), findsOneWidget);
      semantics.dispose();
      await tester.tap(applicationMenu);
      await tester.pumpAndSettle();
      expect(find.text('Workspaces'), findsOneWidget);
      for (final tooltip in find.byType(Tooltip).evaluate()) {
        expect(TooltipVisibility.of(tooltip), isFalse);
      }
      await mouse.removePointer();
    });
  }

  for (final dark in [false, true]) {
    testWidgets('collapsed sidebar menu surfaces follow theme dark=$dark',
        (tester) async {
      const testSpace = AxSpace(
          id: 'menu-space',
          name: 'Menu Space',
          branch: '',
          lastActivity: '',
          role: 'owner');
      await tester.pumpWidget(MaterialApp(
        theme: dark ? SyntilaBrand.darkTheme() : SyntilaBrand.lightTheme(),
        home: Scaffold(
            body: AxIconRail(
          shellContext: AxShellContext(
            navigation: const AxNavigation.home(),
            spaces: [testSpace],
            threadsBySpace: {
              testSpace.id: const [
                AxThread(
                    id: 'menu-thread',
                    spaceId: 'menu-space',
                    name: 'Menu Thread',
                    lead: '',
                    status: 'active',
                    brief: '',
                    primaryWorkspace: '',
                    queueStatus: '')
              ]
            },
          ),
          onNavigateTo: (_) {},
          onOpenDrawer: () {},
          onLogout: () {},
          onOpenAbout: () {},
          onOpenExternal: (_) {},
        )),
      ));
      await tester.pumpAndSettle();
      final anchors = tester.widgetList<MenuAnchor>(find.byType(MenuAnchor));
      expect(anchors.length, greaterThan(1));
      for (final anchor in anchors) {
        expect(anchor.style?.backgroundColor?.resolve({}),
            SyntilaColors.navigationBackground(dark));
        expect(anchor.style?.surfaceTintColor?.resolve({}), Colors.transparent);
      }
      await tester.tap(find.byTooltip('Your spaces'));
      await tester.pumpAndSettle();
      final spaceColor =
          tester.widget<Text>(find.text('Menu Space')).style?.color;
      final threadColor =
          tester.widget<Text>(find.text('Menu Thread')).style?.color;
      expect(spaceColor, threadColor);
      expect(spaceColor, SyntilaColors.navigationTextMuted(dark));
      expect(
          find.byWidgetPredicate((widget) =>
              widget is Material &&
              widget.elevation == 12 &&
              widget.color == SyntilaColors.navigationBackground(dark)),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    // Layout/menu tests settle finite transitions; pulse timing is tested separately.
    binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
  });
  tearDown(
      () => binding.platformDispatcher.clearAccessibilityFeaturesTestValue());

  testWidgets('shell initializes its store before registering listeners',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: const AxFixtureDataSource(),
        initialUri: Uri.parse('/settings/profile'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(SyntilaAppShell), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile page uses sections without passkey controls',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: SyntilaBrand.lightTheme(),
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: const AxFixtureDataSource(),
        initialUri: Uri.parse('/settings/profile'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Profile & Security'), findsNothing);
    expect(
        find.text(
            'Manage your Syntila identity, linked login methods, and active sessions.'),
        findsNothing);
    expect(find.text('Profile'), findsNothing);
    expect(find.text('Your stable Syntila identity'), findsNothing);
    expect(find.textContaining('Link another verified provider'), findsNothing);
    expect(find.textContaining('Revoke access from a device'), findsNothing);
    expect(find.byType(Divider), findsNothing);
    expect(find.text('Passkeys'), findsNothing);
    expect(find.text('Add passkey'), findsNothing);
    expect(find.text('Linked account gh-1'), findsNothing);
    expect(find.text('Revoke all'), findsOneWidget);
    expect(find.text('Current'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Current'), findsNothing);
    expect(find.text('Expires 7 Oct 2026, 10:00 UTC'), findsOneWidget);
    expect(find.text('Change avatar'), findsNothing);
    final avatar = find.byKey(const ValueKey('profile-avatar-upload'));
    expect(tester.widget<IconButton>(avatar).onPressed, isNotNull);
    await tester.tap(avatar);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Account'), findsNothing);
    expect(find.text('Linked login methods'), findsNothing);
    expect(find.text('No linked methods loaded.'), findsNothing);
    expect(
        find.byKey(const ValueKey('profile-delete-account')), findsOneWidget);
    expect(find.text('Rename'), findsNothing);
    expect(find.text('Update email'), findsNothing);
    // The name is edited in a dialog.
    for (final entry in [
      ('Edit name', 'Rename profile'),
      ('Edit email', 'Update email'),
    ]) {
      final edit = find.byTooltip(entry.$1);
      expect(edit, findsOneWidget);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, entry.$2), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Fixture browser'),
        matching: find.byTooltip('Revoke'),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
          of: find.text('Linked login methods'), matching: find.byType(Card)),
      findsNothing,
    );

    final revoke = find.byTooltip('Revoke').last;
    await tester.ensureVisible(revoke);
    await tester.tap(revoke);
    await tester.pumpAndSettle();
    expect(find.text('Fixture browser'), findsOneWidget);
    expect(find.text('Other browser'), findsNothing);
  });

  testWidgets(
      'linked Google and GitHub can be unlinked and failures preserve links',
      (tester) async {
    final source = _LinkedProvidersFixture(['google', 'github']);
    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: source,
        initialUri: Uri.parse('/settings/profile'),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Unlink Google'));
    await tester.pumpAndSettle();
    expect(find.text('Unlink Google?'), findsOneWidget);
    expect(source.unlinkedIds, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(source.unlinkedIds, isEmpty);
    expect(find.byTooltip('Unlink Google'), findsOneWidget);

    source.failUnlink = true;
    await tester.tap(find.byTooltip('Unlink Google'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Unlink'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Unlink Google'), findsOneWidget);
    expect(find.byTooltip('Link Google'), findsNothing);
    expect(find.textContaining('Keep another sign-in method'), findsOneWidget);
    source.failUnlink = false;
    for (final label in ['Google', 'GitHub']) {
      final pending = Completer<void>();
      source.unlinkGate = pending.future;
      await tester.tap(find.byTooltip('Unlink $label'));
      await tester.pumpAndSettle();
      expect(find.text('Unlink $label?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Unlink'));
      await tester.pump();
      expect(find.byTooltip('Unlinking…'), findsOneWidget);
      if (label == 'Google') {
        final button = tester.widget<IconButton>(
          find
              .ancestor(
                of: find.byTooltip('Unlink GitHub'),
                matching: find.byType(IconButton),
              )
              .first,
        );
        expect(button.onPressed, isNull);
      }
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Unlink $label'), findsNothing);
      expect(find.byTooltip('Link $label'), findsOneWidget);
    }
    expect(source.unlinkedIds, ['google', 'google', 'github']);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('linked providers display with icons and link/unlink options',
      (tester) async {
    for (final providers in [
      <String>[],
      ['GitHub'],
      ['google'],
      ['github', 'google']
    ]) {
      await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        theme: SyntilaBrand.lightTheme(),
        home: SyntilaAppShell(
          services: const DefaultPlatformServices(),
          dataSource: _LinkedProvidersFixture(providers),
          initialUri: Uri.parse('/settings/profile'),
        ),
      ));
      await tester.pumpAndSettle();
      for (final provider in ['github', 'google']) {
        final linked =
            providers.any((value) => value.toLowerCase() == provider);
        final label = provider == 'github' ? 'GitHub' : 'Google';
        expect(find.byTooltip('Link $label'),
            linked ? findsNothing : findsOneWidget);
        expect(find.byTooltip('Unlink $label'),
            linked ? findsOneWidget : findsNothing);
        expect(find.text(label), findsOneWidget);
        expect(
            find.byWidgetPredicate((widget) =>
                widget is Image &&
                widget.image is AssetImage &&
                (widget.image as AssetImage).assetName ==
                    'assets/auth/$provider.png'),
            findsOneWidget);
        final icon = tester.widget<Image>(find.byWidgetPredicate((widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/auth/$provider.png'));
        expect(icon.width, 24);
        final action = find.ancestor(
            of: find.byTooltip('${linked ? 'Unlink' : 'Link'} $label'),
            matching: find.byType(IconButton));
        expect(action, findsOneWidget);
        final button = tester.widget<IconButton>(action);
        expect(button.color, SyntilaColors.textPrimary(false));
        expect(button.iconSize, 20);
        expect(tester.getSize(action), const Size(48, 48));
        final deleteAction =
            find.byKey(const ValueKey('profile-delete-account'));
        expect(tester.widget<IconButton>(deleteAction).iconSize, 20);
        expect(
            tester.getTopRight(action).dx, tester.getTopRight(deleteAction).dx);
        expect(
            (button.icon as Icon).icon, linked ? Icons.link_off : Icons.link);
      }
      expect(
          find.byKey(const ValueKey('profile-delete-account')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('profile sessions have visible small labels for missing metadata',
      (tester) async {
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final isDark in [false, true]) {
      final mode = isDark ? ThemeMode.dark : ThemeMode.light;
      final theme =
          isDark ? SyntilaBrand.darkTheme() : SyntilaBrand.lightTheme();
      await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        theme: theme,
        home: SyntilaAppShell(
          services: const DefaultPlatformServices(),
          themePreference: ThemePreference(
            read: () => mode.name,
            write: (_) {},
          ),
          dataSource: _LinkedProvidersFixture([], sessions: const [
            AxAuthSession(
                token: 'blank',
                id: 'blank',
                createdAt: '',
                expiresAt: '',
                userAgent: '\u200B'),
            AxAuthSession(
                token: 'chrome',
                id: 'chrome',
                createdAt: '',
                expiresAt: '',
                userAgent: 'Mozilla/5.0 (Macintosh) Chrome/140 Safari/537'),
          ]),
          initialUri: Uri.parse('/settings/profile'),
        ),
      ));
      await tester.pumpAndSettle();
      for (final label in ['Browser session', 'Chrome on macOS']) {
        final finder = find.text(label);
        expect(finder, findsOneWidget);
        await tester.ensureVisible(finder);
        final text = tester.widget<Text>(finder);
        expect(text.style?.fontSize, 13);
        expect(text.style?.fontFamily, theme.textTheme.bodySmall?.fontFamily);
        expect(text.style?.fontWeight, FontWeight.w500);
        expect(text.style?.color, SyntilaColors.textPrimary(isDark));
        expect(tester.getSize(finder).width, greaterThan(60));
        expect(tester.getSize(finder).height, greaterThan(0));
      }
      expect(find.text('Expiry unavailable'), findsNWidgets(2));
      expect(find.byIcon(Icons.devices_outlined), findsNothing);
      for (var index = 0; index < 2; index++) {
        final label =
            find.text(index == 0 ? 'Browser session' : 'Chrome on macOS');
        final expiry = find.text('Expiry unavailable').at(index);
        expect(tester.getTopLeft(label).dx, tester.getTopLeft(expiry).dx);
        expect(tester.widget<Text>(expiry).style?.color,
            SyntilaColors.textSecondary(isDark));
      }
      expect(find.text('Linked login methods'), findsNothing);
      expect(find.text('No linked methods loaded.'), findsNothing);
      expect(find.byTooltip('Link GitHub'), findsOneWidget);
      expect(find.byTooltip('Link Google'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('profile revoke all keeps the current session', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: SyntilaBrand.lightTheme(),
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: const AxFixtureDataSource(),
        initialUri: Uri.parse('/settings/profile'),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Revoke all'));
    await tester.pumpAndSettle();

    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Fixture browser'), findsOneWidget);
    expect(find.text('Other browser'), findsNothing);
  });

  testWidgets('profile deletes the account only after the email is retyped',
      (tester) async {
    final data = _DeleteAccountFixture();
    await tester.pumpWidget(MaterialApp(
      theme: SyntilaBrand.lightTheme(),
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: data,
        initialUri: Uri.parse('/settings/profile'),
      ),
    ));
    await tester.pumpAndSettle();

    final deleteButton = find.byKey(const ValueKey('profile-delete-account'));
    await tester.ensureVisible(deleteButton);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();
    expect(
        find.text(
            'This permanently deletes your Syntila account and signs you out on every device. This action cannot be undone.'),
        findsOneWidget);

    final confirmButton = find.widgetWithText(FilledButton, 'Delete account');
    expect(tester.widget<FilledButton>(confirmButton).onPressed, isNull);
    await tester.enterText(
        find.byKey(const ValueKey('delete-account-confirm-email')),
        'wrong@example.test');
    await tester.pump();
    expect(tester.widget<FilledButton>(confirmButton).onPressed, isNull);
    await tester.enterText(
        find.byKey(const ValueKey('delete-account-confirm-email')),
        data.viewerEmail);
    await tester.pump();
    await tester.tap(confirmButton);
    await tester.pumpAndSettle();
    expect(data.deleted, isTrue);
    expect(data.confirmEmail, data.viewerEmail);
    expect(find.text('Welcome to Syntila'), findsOneWidget);
  });

  testWidgets('removed account is signed out when realtime disconnects',
      (tester) async {
    final data = _RemovableAccountFixture();
    final realtime = TestRealtime();
    await tester.pumpWidget(MaterialApp(
      theme: SyntilaBrand.lightTheme(),
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: data,
        realtimeClient: realtime,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Syntila'), findsNothing);

    // The account is deleted elsewhere; Cloud closes the realtime socket.
    data.removed = true;
    realtime.emit({'type': 'realtime.connection', 'status': 'reconnecting'});
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Syntila'), findsOneWidget);
  });

  testWidgets('profile email change needs codes from new then current email',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: SyntilaBrand.lightTheme(),
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: _EmailChangeFixture(),
        initialUri: Uri.parse('/settings/profile'),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit email'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('email-change-new-email')),
        'next@example.test');
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the 6-digit code sent to next@example.test.'),
        findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('email-change-code-newCode')), '000000');
    await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid code'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('email-change-code-newCode')), '111111');
    await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('sent to your current address, old@example.test.'),
        findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('email-change-code-currentCode')), '222222');
    await tester.tap(find.widgetWithText(FilledButton, 'Update email'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('changed@example.test'), findsOneWidget);
  });

  testWidgets('profile security remains loading until both lists arrive',
      (tester) async {
    final data = _DelayedAccountSecurityDataSource();
    await tester.pumpWidget(MaterialApp(
      theme: SyntilaBrand.lightTheme(),
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: data,
        initialUri: Uri.parse('/settings/profile'),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(data.securityLoadCalls, 1);
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    data.complete();
    await tester.pumpAndSettle();
    expect(find.text('Fixture browser'), findsOneWidget);
    expect(find.text('Other browser'), findsOneWidget);
    expect(find.text('Credentials'), findsNothing);
  });

  testWidgets('clicking another space loads and reveals its Threads',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final data = _SpaceScopedFixture();
    await tester.pumpWidget(MaterialApp(
        home: SyntilaAppShell(
      services: const DefaultPlatformServices(),
      dataSource: data,
    )));
    await tester.pumpAndSettle();
    final target = find.byKey(const ValueKey('sidebar-space-row-atlas'));
    final atlasThread =
        find.byKey(const ValueKey('sidebar-thread-row-atlas-chat'));
    expect(atlasThread, findsNothing);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(data.selectedSpaces, contains('atlas'));
    expect(atlasThread, findsOneWidget);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(atlasThread, findsNothing);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(atlasThread, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('space collapse survives background refresh and can expand again',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: SyntilaBrand.darkTheme(),
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: const AxFixtureDataSource(),
        initialUri: Uri.parse('/spaces/space-auth/threads/thread-auth'),
      ),
    ));
    await tester.pumpAndSettle();
    final tree = find.byType(SpaceTree);
    final space = find.byKey(const ValueKey('sidebar-space-row-space-auth'));
    final stream = find.byKey(const ValueKey('sidebar-thread-row-thread-auth'));
    expect(stream, findsOneWidget);
    // Keep the active Thread route while collapsing its sidebar parent.
    tester.widget<SpaceTree>(tree).onToggleSpaceExpanded!('space-auth');
    await tester.pumpAndSettle();
    expect(stream, findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(stream, findsNothing);
    await tester.tap(space);
    await tester.pumpAndSettle();
    expect(stream, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('opening a recent Thread preserves its collapsed Space',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: SyntilaBrand.darkTheme(),
      home: const SyntilaAppShell(
        services: DefaultPlatformServices(),
        dataSource: AxFixtureDataSource(),
      ),
    ));
    await tester.pumpAndSettle();

    final tree = find.byType(SpaceTree);
    const originalThread = ValueKey('sidebar-thread-row-thread-auth');
    const recentThread = ValueKey('recent-thread-row-space-auth-thread-auth');
    expect(find.byKey(originalThread), findsNothing);
    expect(find.byKey(recentThread), findsOneWidget);

    await tester.tap(find.byKey(recentThread));
    await tester.pumpAndSettle();

    expect(tester.widget<SpaceTree>(tree).shellContext.navigation.threadId,
        'thread-auth');
    expect(find.byKey(originalThread), findsNothing);
    expect(find.byKey(recentThread), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('AxShellContext and isNavActive', () {
    test('isNavActive correctly isolates Home from spaces and threads', () {
      const homeContext = AxShellContext(
        navigation: AxNavigation.home(),
        spaces: [],
      );
      expect(homeContext.isNavActive(const AxNavigation.home()), isTrue);
      expect(homeContext.isNavActive(const AxNavigation.spaces()), isFalse);
      expect(homeContext.isNavActive(const AxNavigation.workspaces()), isFalse);

      const spaceContext = AxShellContext(
        navigation: AxNavigation.space('space-1'),
        spaces: [],
      );
      // Home must NOT be active when on a space page
      expect(spaceContext.isNavActive(const AxNavigation.home()), isFalse);
      expect(spaceContext.isNavActive(const AxNavigation.space('space-1')),
          isTrue);
      expect(spaceContext.isNavActive(const AxNavigation.space('space-2')),
          isFalse);
      expect(spaceContext.isNavActive(const AxNavigation.spaces()), isTrue);

      const threadContext = AxShellContext(
        navigation: AxNavigation.thread('space-1', 'ws-1'),
        spaces: [],
      );
      // Home must NOT be active when on a thread page
      expect(threadContext.isNavActive(const AxNavigation.home()), isFalse);
      expect(threadContext.isNavActive(const AxNavigation.space('space-1')),
          isTrue);
      expect(threadContext.isNavActive(const AxNavigation.spaces()), isTrue);
    });

    testWidgets(
        'active Space menu exposes actions without a separate Members destination',
        (tester) async {
      AxNavigation? navigatedTo;
      const space = AxSpace(
        id: 'space-1',
        name: 'Space One',
        role: 'owner',
        branch: '',
        lastActivity: '',
      );
      await tester.pumpWidget(MaterialApp(
        theme: SyntilaBrand.darkTheme(),
        home: Scaffold(
          body: SpaceTree(
            shellContext: const AxShellContext(
              navigation: AxNavigation.space('space-1'),
              spaces: [space],
            ),
            onNavigateTo: (route) => navigatedTo = route,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Space menu'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Space'), findsOneWidget);
      expect(find.text('Archive Space'), findsOneWidget);
      expect(find.text('Delete Space'), findsOneWidget);
      expect(find.text('Workflows'), findsNothing);
      expect(find.text('Members'), findsNothing);
      expect(navigatedTo, isNull);
    });

    test('isNavActive covers every route kind accurately', () {
      // Spaces section active for spaces, space resources, thread, and run
      const routesInSpaces = [
        AxNavigation.spaces(),
        AxNavigation.space('p-1'),
        AxNavigation.spaceMembers('p-1'),
        AxNavigation.thread('p-1', 'ws-1'),
        AxNavigation.run('p-1', 'r-1'),
        AxNavigation.thread('p-1', 'ws-2'),
      ];

      for (final nav in routesInSpaces) {
        final ctx = AxShellContext(navigation: nav, spaces: const []);
        expect(
          ctx.isNavActive(const AxNavigation.spaces()),
          isTrue,
          reason: '$nav should activate Spaces group',
        );
        expect(
          ctx.isNavActive(const AxNavigation.home()),
          isFalse,
          reason: '$nav should NOT activate Home',
        );
        expect(
          ctx.isNavActive(const AxNavigation.workspaces()),
          isFalse,
          reason: '$nav should NOT activate Workspaces',
        );
      }

      // Workspaces route
      const workspaceCtx = AxShellContext(
        navigation: AxNavigation.workspaces(),
        spaces: [],
      );
      expect(workspaceCtx.isNavActive(const AxNavigation.workspaces()), isTrue);
      expect(workspaceCtx.isNavActive(const AxNavigation.spaces()), isFalse);
      expect(workspaceCtx.isNavActive(const AxNavigation.home()), isFalse);

      // Profile & Security route
      const profileCtx = AxShellContext(
        navigation: AxNavigation.profileSecurity(),
        spaces: [],
      );
      expect(
          profileCtx.isNavActive(const AxNavigation.profileSecurity()), isTrue);
      expect(profileCtx.isNavActive(const AxNavigation.home()), isFalse);
      expect(profileCtx.isNavActive(const AxNavigation.spaces()), isFalse);
    });
  });

  group('AxSidebar Canonical Component', () {
    const testSpace = AxSpace(
      id: 'space-1',
      name: 'Syntila',
      branch: 'main',
      lastActivity: 'today',
      threads: [
        AxThread(
          id: 'ws-1',
          spaceId: 'space-1',
          name: 'Authentication redesign',
          lead: 'Vitalii',
          status: 'running',
          brief: 'Redesign login flow',
          primaryWorkspace: 'MacBook Pro',
          queueStatus: 'Running',
        ),
      ],
    );

    testWidgets('renders canonical sidebar hierarchy and triggers callbacks',
        (tester) async {
      AxNavigation? navigatedTo;
      String? toggledSpaceId;
      var createSpaceCalled = false;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: [testSpace],
        threadsBySpace: {testSpace.id: testSpace.threads},
        selectedSpace: testSpace,
        workspaces: [
          const AxWorkspace(
            id: 'worker-1',
            name: 'MacBook Pro',
            hostname: 'vitalii-mac',
            status: 'online',
            platform: 'macOS',
            architecture: 'arm64',
            appVersion: '0.6.0',
            lastSeen: 'just now',
            workerCount: 2,
            activeTaskCount: 1,
          ),
        ],
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
        expandedSpaceIds: {'space-1'},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onToggleSpaceExpanded: (id) => toggledSpaceId = id,
              onCreateSpace: () => createSpaceCalled = true,
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check Header & Main Sections
      expect(find.byKey(const ValueKey('sidebar-space-row-space-1')),
          findsOneWidget);
      expect(find.text('Home'), findsNothing);
      expect(find.text('Spaces'), findsNothing);
      expect(find.text('SPACES'), findsNothing);

      // Tapping Syntila brand navigates to Home
      await tester.tap(find.byTooltip('Syntila — Home'));
      expect(navigatedTo?.kind, AxRouteKind.home);
      navigatedTo = null;

      // Check sidebar collapse button with menu_open icon
      expect(find.byIcon(Icons.menu_open_rounded), findsOneWidget);

      // Infrequent execution and insights configuration are removed from permanent sidebar
      expect(find.text('EXECUTION'), findsNothing);
      expect(find.text('Workers'), findsNothing);
      expect(find.text('AI Accounts'), findsNothing);
      expect(find.text('INSIGHTS'), findsNothing);

      // Check Space & Thread tree
      expect(find.byKey(const ValueKey('sidebar-thread-row-ws-1')),
          findsOneWidget);

      // Check Viewer Initials & Name button
      expect(find.text('VN'), findsOneWidget);
      expect(find.text('Vitalii Noha'), findsOneWidget);

      // Tap New Space button before alarm icon
      await tester.tap(find.byTooltip('New Space'));
      await tester.pumpAndSettle();
      expect(createSpaceCalled, isTrue);

      // Selecting an expanded Space from Home preserves its expansion.
      await tester.tap(find.byKey(const ValueKey('sidebar-space-row-space-1')));
      expect(navigatedTo?.kind, AxRouteKind.space);
      expect(navigatedTo?.spaceId, 'space-1');
      expect(toggledSpaceId, isNull);

      // Tap thread row
      await tester.tap(find.byKey(const ValueKey('sidebar-thread-row-ws-1')));
      expect(navigatedTo?.kind, AxRouteKind.thread);
      expect(navigatedTo?.threadId, 'ws-1');

      // Verify folder open icon is displayed for expanded space
      expect(
        find.byWidgetPredicate(
            (w) => w is SyntilaFolderIcon && w.isExpanded == true),
        findsOneWidget,
      );

      // Tap User Profile Button at bottom of sidebar -> navigates to /settings/profile
      await tester.tap(find.text('Vitalii Noha'));
      expect(navigatedTo?.kind, AxRouteKind.profileSecurity);

      // Tap ⋯ Application menu at bottom of sidebar
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      expect(
          find.descendant(
              of: find.byType(MenuItemButton),
              matching: find.text('Workspaces')),
          findsOneWidget);
      expect(find.text('Archived Spaces'), findsOneWidget);
      expect(find.text('Appearance'), findsNothing);
      expect(find.text('Documentation'), findsOneWidget);
      expect(find.text('About Syntila'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);
      expect(find.text('Usage'), findsNothing);
      expect(find.text('GitHub repository'), findsNothing);
      expect(find.text('Website'), findsNothing);

      // Tap Execution in Application menu
      await tester.tap(find.descendant(
          of: find.byType(MenuItemButton), matching: find.text('Workspaces')));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, AxRouteKind.workspaces);
    });

    testWidgets(
        'Phase 2: bottom user/profile control and separate ⋯ menu hit target',
        (tester) async {
      AxNavigation? navigatedTo;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: [testSpace],
        threadsBySpace: {testSpace.id: testSpace.threads},
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onToggleSpaceExpanded: (_) {},
              onCreateSpace: () {},
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Tapping the avatar specifically navigates to /settings/profile and does not open menu
      await tester.tap(find.text('VN'));
      expect(navigatedTo?.kind, AxRouteKind.profileSecurity);
      expect(
          find.descendant(
              of: find.byType(MenuItemButton),
              matching: find.text('Workspaces')),
          findsNothing);

      // Reset
      navigatedTo = null;

      // 2. Tapping the user name specifically navigates to /settings/profile and does not open menu
      await tester.tap(find.text('Vitalii Noha'));
      expect(navigatedTo?.kind, AxRouteKind.profileSecurity);
      expect(
          find.descendant(
              of: find.byType(MenuItemButton),
              matching: find.text('Workspaces')),
          findsNothing);

      // Reset
      navigatedTo = null;

      // 3. Tapping the ⋯ button specifically opens the Application Menu and does NOT navigate to profile
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      expect(navigatedTo, isNull);
      expect(
          find.descendant(
              of: find.byType(MenuItemButton),
              matching: find.text('Workspaces')),
          findsOneWidget);
      expect(find.text('Archived Spaces'), findsOneWidget);
      expect(find.text('Appearance'), findsNothing);
      expect(find.text('Documentation'), findsOneWidget);
      expect(find.text('About Syntila'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);
      expect(find.text('Usage'), findsNothing);
      expect(find.text('GitHub repository'), findsNothing);
      expect(find.text('Website'), findsNothing);
    });

    testWidgets(
        'Phase 3: Global application menu actions (destinations, product info, session logout)',
        (tester) async {
      var logoutTriggered = false;
      var aboutTriggered = false;
      Uri? openedExternalUri;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: [testSpace],
        threadsBySpace: {testSpace.id: testSpace.threads},
        themeMode: ThemeMode.system,
        viewerDisplayName: 'Vitalii Noha',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onToggleSpaceExpanded: (_) {},
              onCreateSpace: () {},
              onLogout: () => logoutTriggered = true,
              onOpenAbout: () => aboutTriggered = true,
              onOpenExternal: (uri) => openedExternalUri = uri,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open menu in sidebar
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      expect(
          tester
              .widget<MenuAnchor>(find.byType(MenuAnchor).last)
              .style
              ?.backgroundColor
              ?.resolve({}),
          SyntilaColors.navigationBackgroundDark);

      // Test 2: Documentation
      await tester.tap(find.text('Documentation'));
      await tester.pumpAndSettle();
      expect(
          openedExternalUri, Uri.parse('https://conclaveax.com/how-it-works/'));

      // Re-open menu
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      // Test 3: About Syntila
      await tester.tap(find.text('About Syntila'));
      await tester.pumpAndSettle();
      expect(aboutTriggered, isTrue);

      // Re-open menu
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      // Test 4: Log out
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(logoutTriggered, isTrue);
    });

    testWidgets(
        'Phase 3: AxIconRail includes global application menu with destinations and actions',
        (tester) async {
      AxNavigation? navigatedTo;
      var logoutTriggered = false;
      var aboutTriggered = false;
      Uri? openedExternalUri;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: [testSpace],
        threadsBySpace: {testSpace.id: testSpace.threads},
        themeMode: ThemeMode.light,
        viewerDisplayName: 'Vitalii Noha',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.lightTheme(),
          home: Scaffold(
            body: AxIconRail(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenDrawer: () {},
              onLogout: () => logoutTriggered = true,
              onOpenAbout: () => aboutTriggered = true,
              onOpenExternal: (uri) => openedExternalUri = uri,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open menu in rail
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      // Check items exist
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Archived Spaces'), findsOneWidget);
      expect(find.text('Appearance'), findsNothing);
      expect(find.text('Documentation'), findsOneWidget);
      expect(find.text('About Syntila'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);
      expect(find.text('Usage'), findsNothing);
      expect(find.text('GitHub repository'), findsNothing);
      expect(find.text('Website'), findsNothing);

      // Click Execution
      await tester.tap(find.text('Workspaces'));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, AxRouteKind.workspaces);

      // Reopen and check Documentation
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Documentation'));
      await tester.pumpAndSettle();
      expect(
          openedExternalUri, Uri.parse('https://conclaveax.com/how-it-works/'));

      // Reopen and check About Syntila
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About Syntila'));
      await tester.pumpAndSettle();
      expect(aboutTriggered, isTrue);

      // Reopen and check Log out
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(logoutTriggered, isTrue);
    });

    testWidgets('omits archived threads and archive groups from the sidebar',
        (tester) async {
      const spaceWithArchived = AxSpace(
        id: 'space-2',
        name: 'Syntila Core',
        branch: 'main',
        lastActivity: 'today',
        threads: [
          AxThread(
            id: 'ws-active',
            spaceId: 'space-2',
            name: 'Active Thread',
            lead: 'Vitalii',
            status: 'active',
            brief: 'Active task',
            primaryWorkspace: 'MacBook Pro',
            queueStatus: 'Idle',
          ),
          AxThread(
            id: 'ws-archived',
            spaceId: 'space-2',
            name: 'Old Archived Thread',
            lead: 'Vitalii',
            status: 'archived',
            brief: 'Archived task',
            primaryWorkspace: 'MacBook Pro',
            queueStatus: 'Done',
          ),
        ],
      );

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: [spaceWithArchived],
        threadsBySpace: {spaceWithArchived.id: spaceWithArchived.threads},
        expandedSpaceIds: {'space-2'},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onToggleSpaceExpanded: (_) {},
              onCreateSpace: () {},
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sidebar-thread-row-ws-active')),
          findsOneWidget);
      expect(find.text('Old Archived Thread'), findsNothing);
      expect(find.text('Archived (1)'), findsNothing);
    });
  });

  group('AxTopBar Canonical Component', () {
    const testSpace = AxSpace(
      id: 'space-1',
      name: 'Syntila',
      branch: 'main',
      lastActivity: 'today',
      threads: [
        AxThread(
          id: 'ws-1',
          spaceId: 'space-1',
          name: 'Authentication redesign',
          lead: 'Vitalii',
          status: 'running',
          brief: 'Redesign login flow',
          primaryWorkspace: 'MacBook Pro',
          queueStatus: 'Running',
        ),
      ],
    );

    testWidgets('renders breadcrumbs, search affordance, and workspace status',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      AxNavigation? navigatedTo;
      var commandPaletteOpened = false;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.thread('space-1', 'ws-1'),
        spaces: const [testSpace],
        selectedSpace: testSpace,
        selectedThread: testSpace.threads.first,
        workspaces: const [
          AxWorkspace(
            id: 'worker-1',
            name: 'MacBook Pro',
            hostname: 'vitalii-mac',
            status: 'online',
            platform: 'macOS',
            architecture: 'arm64',
            appVersion: '0.6.0',
            lastSeen: 'just now',
            workerCount: 2,
            activeTaskCount: 1,
          ),
        ],
        unreadNotificationCount: 3,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () => commandPaletteOpened = true,
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check Breadcrumbs: Syntila / Authentication redesign
      expect(find.text('Syntila'), findsOneWidget);
      expect(find.text('Authentication redesign'), findsOneWidget);

      // Check Search affordance (desktop)
      expect(find.text('Search or jump to...'), findsOneWidget);

      // Check Workspace status button
      expect(find.text('MacBook Pro · Online'), findsOneWidget);

      // Check Notification badge
      expect(find.text('3'), findsOneWidget);

      // Low-value controls (theme toggle & about) must NOT be in the permanent top HUD
      expect(find.byTooltip('Switch to light mode'), findsNothing);
      expect(find.byTooltip('Switch to dark mode'), findsNothing);
      expect(find.text('About'), findsNothing);

      // Click Space in breadcrumb
      await tester.tap(find.text('Syntila'));
      expect(navigatedTo?.kind, AxRouteKind.space);
      expect(navigatedTo?.spaceId, 'space-1');

      // Click Search affordance
      await tester.tap(find.text('Search or jump to...'));
      expect(commandPaletteOpened, isTrue);
    });

    testWidgets('tablet/compact HUD shows account and global actions',
        (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: [testSpace],
        threadsBySpace: {testSpace.id: testSpace.threads},
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
        isDarkTheme: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onOpenCommandPalette: () {},
              onOpenNotifications: () {},
              compact: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('VN'), findsNothing);
      expect(find.text('Vitalii Noha'), findsOneWidget);
      expect(find.byTooltip('Account menu'), findsNothing);

      final opener = find.byTooltip('Syntila — Spaces');
      final menu = find.byTooltip('Application menu');
      expect(opener, findsOneWidget);
      expect(menu, findsOneWidget);
      expect(tester.getCenter(opener).dx, lessThan(tester.getCenter(menu).dx));
      expect(tester.getCenter(menu).dx,
          greaterThan(tester.getCenter(find.byTooltip('Notifications')).dx));
      expect(tester.getCenter(find.byTooltip('Search')).dx,
          lessThan(tester.getCenter(find.byTooltip('Notifications')).dx));
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.text('My Notes'), findsOneWidget);
      await tester.tapAt(const Offset(390, 600));
      await tester.pumpAndSettle();
      // Search and Notifications should be present
      expect(find.byTooltip('Search'), findsOneWidget);
      expect(find.byTooltip('Notifications'), findsOneWidget);
    });

    testWidgets(
        'tablet/compact HUD search icon click displays inline search control and triggers search',
        (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final controller = TextEditingController();
      final focusNode = FocusNode();
      String? searchedText;
      var clearCalled = false;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: [testSpace],
        threadsBySpace: {testSpace.id: testSpace.threads},
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
        isDarkTheme: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onOpenCommandPalette: () {},
              onOpenNotifications: () {},
              searchController: controller,
              searchFocusNode: focusNode,
              onSearchChanged: (val) => searchedText = val,
              onClearSearch: () => clearCalled = true,
              compact: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially search icon is visible and inline TextField is not
      expect(find.byTooltip('Search'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      // Tap search icon
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();

      // Now inline TextField is visible
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

      // Enter search text
      await tester.enterText(find.byType(TextField), 'auth workflow');
      await tester.pumpAndSettle();
      expect(searchedText, 'auth workflow');

      // Tap clear/close button
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(clearCalled, isTrue);
    });

    testWidgets('renders Run breadcrumbs: Space / Thread / Run',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      AxNavigation? navigatedTo;

      final shellContext = AxShellContext(
        navigation:
            const AxNavigation.run('space-1', 'run-1', threadId: 'ws-1'),
        spaces: const [testSpace],
        selectedSpace: testSpace,
        selectedThread: testSpace.threads.first,
        selectedRun: const AxRun(
          id: 'run-1',
          threadId: 'ws-1',
          status: RunStatus.running,
          objective: 'Run test objective',
          taskCount: 2,
          completedTaskCount: 1,
          openFindingCount: 0,
          verifiedCriterionCount: 1,
          criterionCount: 2,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Syntila'), findsOneWidget);
      expect(find.text('Authentication redesign'), findsOneWidget);
      expect(find.text('Run'), findsOneWidget);

      // Click Thread link in breadcrumb
      await tester.tap(find.text('Authentication redesign'));
      expect(navigatedTo?.kind, AxRouteKind.thread);
      expect(navigatedTo?.spaceId, 'space-1');
      expect(navigatedTo?.threadId, 'ws-1');
    });

    testWidgets('compact HUD prioritizes leaf entity in breadcrumbs for thread',
        (tester) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      AxNavigation? navigatedTo;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.thread('space-1', 'ws-1'),
        spaces: const [testSpace],
        selectedSpace: testSpace,
        selectedThread: testSpace.threads.first,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
              compact: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // In compact mode, parent space 'Syntila' and thread are displayed
      expect(find.text('Syntila'), findsOneWidget);
      expect(find.text('Authentication redesign'), findsOneWidget);

      // Tapping parent space navigates back to the Space
      await tester.tap(find.text('Syntila'));
      expect(navigatedTo?.kind, AxRouteKind.space);
      expect(navigatedTo?.spaceId, 'space-1');
    });

    testWidgets('compact HUD displays full breadcrumb path for run',
        (tester) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      AxNavigation? navigatedTo;

      final shellContext = AxShellContext(
        navigation:
            const AxNavigation.run('space-1', 'run-1', threadId: 'ws-1'),
        spaces: const [testSpace],
        selectedSpace: testSpace,
        selectedThread: testSpace.threads.first,
        selectedRun: const AxRun(
          id: 'run-1',
          threadId: 'ws-1',
          status: RunStatus.running,
          objective: 'Run test objective',
          taskCount: 2,
          completedTaskCount: 1,
          openFindingCount: 0,
          verifiedCriterionCount: 1,
          criterionCount: 2,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
              compact: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // In compact mode, parent space and thread are displayed
      expect(find.text('Syntila'), findsOneWidget);
      expect(find.text('Authentication redesign'), findsOneWidget);
      expect(find.text('Run'), findsOneWidget);

      // Tapping parent thread navigates to parent Thread
      await tester.ensureVisible(find.text('Authentication redesign'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Authentication redesign'),
          warnIfMissed: false);
      expect(navigatedTo?.kind, AxRouteKind.thread);
      expect(navigatedTo?.spaceId, 'space-1');
      expect(navigatedTo?.threadId, 'ws-1');
    });

    testWidgets(
        'AxIconRail has 50px width and renders navigation icons and controls',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      AxNavigation? navigatedTo;
      var notificationsOpened = false;
      var createSpaceOpened = false;
      var collapseToggled = false;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: [testSpace],
        threadsBySpace: {testSpace.id: testSpace.threads},
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
        unreadNotificationCount: 2,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 50,
              child: AxIconRail(
                shellContext: shellContext,
                onNavigateTo: (nav) => navigatedTo = nav,
                onOpenDrawer: () {},
                onCreateSpace: () => createSpaceOpened = true,
                onOpenCommandPalette: () {},
                onOpenNotifications: () => notificationsOpened = true,
                onToggleTheme: () {},
                onLogout: () {},
                onOpenAbout: () {},
                onOpenExternal: (_) {},
                onToggleCollapse: () => collapseToggled = true,
                sidebarWidth: 260,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(AxIconRail)).width, 50);
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Syntila — Home'), findsOneWidget);
      expect(find.byTooltip('Expand sidebar'), findsOneWidget);
      expect(find.byTooltip('Search...'), findsOneWidget);
      expect(find.byTooltip('Add Space'), findsOneWidget);
      expect(find.byTooltip('Notifications'), findsOneWidget);
      expect(find.byTooltip('Your spaces'), findsOneWidget);
      expect(find.byType(CircleAvatar), findsOneWidget);
      expect(find.byTooltip('Application menu'), findsOneWidget);

      // Tapping Syntila brand logo navigates to Home
      await tester.tap(find.byTooltip('Syntila — Home'));
      expect(navigatedTo, equals(const AxNavigation.home()));

      // Tapping Expand sidebar button expands sidebar
      await tester.tap(find.byTooltip('Expand sidebar'));
      expect(collapseToggled, isTrue);

      // Tapping Search icon opens the search popup control
      await tester.tap(find.byTooltip('Search...'));
      await tester.pumpAndSettle();
      expect(find.text('Search or jump to...'), findsOneWidget);
      expect(find.text('Open Command Palette'), findsNothing);

      // Typing and tapping clear icon clears search text and closes the popup form
      await tester.enterText(find.byType(TextField), 'test query');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Search or jump to...'), findsNothing); // popup closed

      // Tapping Add Space icon
      await tester.tap(find.byTooltip('Add Space'));
      expect(createSpaceOpened, isTrue);

      // Tapping Notifications icon
      await tester.tap(find.byTooltip('Notifications'));
      expect(notificationsOpened, isTrue);

      // Tapping Spaces & Threads popup menu
      await tester.tap(find.byTooltip('Your spaces'));
      await tester.pumpAndSettle();
      expect(find.byType(SyntilaFolderIcon), findsAtLeastNWidgets(1));
      expect(find.text(testSpace.name), findsOneWidget);
      expect(find.text(testSpace.threads.first.name), findsOneWidget);
      expect(tester.getSize(find.byType(MenuItemButton).first).width, 260);
      expect(find.text('Create Space'), findsNothing); // Removed from menu
      await tester.tap(find.text(testSpace.threads.first.name));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, AxRouteKind.thread);
      expect(navigatedTo?.threadId, testSpace.threads.first.id);

      // Tapping Profile avatar button navigates to profile
      await tester.tap(find.byType(CircleAvatar));
      expect(navigatedTo?.kind, AxRouteKind.profileSecurity);

      // Tapping Application menu opens menu with Workspaces
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Usage'), findsNothing);
      await tester.tap(find.text('Workspaces'));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, AxRouteKind.workspaces);
    });

    testWidgets(
        'Workspaces status popover opens and displays workspaces and workers',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      AxNavigation? navigatedTo;

      const macBook = AxWorkspace(
        id: 'worker-1',
        name: 'MacBook Pro',
        hostname: 'vitalii-mac',
        status: 'online',
        platform: 'macOS',
        architecture: 'arm64',
        appVersion: '0.6.0',
        lastSeen: 'just now',
        workerCount: 4,
        activeTaskCount: 1,
      );

      const buildServer = AxWorkspace(
        id: 'worker-2',
        name: 'Build Server',
        hostname: 'build-srv',
        status: 'online',
        platform: 'Linux',
        architecture: 'x64',
        appVersion: '0.6.0',
        lastSeen: 'just now',
        workerCount: 6,
        activeTaskCount: 0,
      );

      const officeMac = AxWorkspace(
        id: 'worker-3',
        name: 'Office Mac',
        hostname: 'office-mac',
        status: 'offline',
        platform: 'macOS',
        architecture: 'arm64',
        appVersion: '0.6.0',
        lastSeen: '2 hours ago',
        workerCount: 0,
        activeTaskCount: 0,
      );

      // 1. Global context test: "2 / 3 Workspaces online"
      const globalContext = AxShellContext(
        navigation: AxNavigation.home(),
        spaces: [],
        workspaces: [macBook, buildServer, officeMac],
      );

      expect(globalContext.executionStatusLabel, '2 / 3 Workspaces online');
      expect(globalContext.executionStatusTone, ExecutionStatusTone.usable);

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: globalContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('2 / 3 Workspaces online'), findsOneWidget);

      // Tap execution status trigger to open popover
      await tester.tap(find.text('2 / 3 Workspaces online'));
      await tester.pumpAndSettle();

      // Check Popover content
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('2 / 3 Online'), findsOneWidget);
      expect(find.text('MacBook Pro'), findsOneWidget);
      expect(find.text('4 Workers ready'), findsOneWidget);
      expect(find.text('Build Server'), findsOneWidget);
      expect(find.text('6 Workers ready'), findsOneWidget);
      expect(find.text('Office Mac'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);

      // Tap Manage Workspaces in popover footer
      await tester.tap(find.text('Manage Workspaces'));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, AxRouteKind.workspaces);
    });

    test('AxShellContext derives correct tone and label across states', () {
      const macBook = AxWorkspace(
        id: 'worker-1',
        name: 'MacBook Pro',
        hostname: 'vitalii-mac',
        status: 'online',
        platform: 'macOS',
        architecture: 'arm64',
        appVersion: '0.6.0',
        lastSeen: 'just now',
        workerCount: 4,
        activeTaskCount: 1,
      );
      const officeMacOffline = AxWorkspace(
        id: 'worker-3',
        name: 'Office Mac',
        hostname: 'office-mac',
        status: 'offline',
        platform: 'macOS',
        architecture: 'arm64',
        appVersion: '0.6.0',
        lastSeen: 'yesterday',
        workerCount: 0,
        activeTaskCount: 0,
      );

      // Thread context: targeted workspace online
      const wsCtxOnline = AxShellContext(
        navigation: AxNavigation.thread('space-1', 'ws-1'),
        spaces: [],
        selectedThread: AxThread(
          id: 'ws-1',
          spaceId: 'space-1',
          name: 'Authentication redesign',
          lead: 'Vitalii',
          status: 'running',
          brief: 'Redesign login flow',
          primaryWorkspace: 'MacBook Pro',
          queueStatus: 'Running',
        ),
        workspaces: [macBook, officeMacOffline],
      );
      expect(wsCtxOnline.executionStatusLabel, 'MacBook Pro · Online');
      expect(wsCtxOnline.executionStatusTone, ExecutionStatusTone.usable);

      // Thread context: targeted workspace offline
      const wsCtxOffline = AxShellContext(
        navigation: AxNavigation.thread('space-1', 'ws-2'),
        spaces: [],
        selectedThread: AxThread(
          id: 'ws-2',
          spaceId: 'space-1',
          name: 'Core refactor',
          lead: 'Vitalii',
          status: 'running',
          brief: 'Refactoring core',
          primaryWorkspace: 'Office Mac',
          queueStatus: 'Running',
        ),
        workspaces: [macBook, officeMacOffline],
      );
      expect(wsCtxOffline.executionStatusLabel, 'Office Mac · Offline');
      expect(wsCtxOffline.executionStatusTone, ExecutionStatusTone.failed);

      // Reconnecting / stale state
      const staleCtx = AxShellContext(
        navigation: AxNavigation.home(),
        spaces: [],
        workspaces: [macBook],
        realtimeStale: true,
      );
      expect(staleCtx.executionStatusTone, ExecutionStatusTone.degraded);

      // Empty workspaces state
      const emptyCtx = AxShellContext(
        navigation: AxNavigation.home(),
        spaces: [],
        workspaces: [],
      );
      expect(emptyCtx.executionStatusLabel, 'No Workspaces');
      expect(emptyCtx.executionStatusTone, ExecutionStatusTone.neutral);
    });
  });

  group('Phase 10 — Shell Cleanup, Regressions, and Deep Interactions', () {
    const spaceA = AxSpace(
      id: 'p-1',
      name: 'Syntila Core',
      branch: 'main',
      lastActivity: 'today',
      threads: [
        AxThread(
          id: 'ws-running',
          spaceId: 'p-1',
          name: 'Engine optimization',
          lead: 'Vitalii',
          status: 'running',
          brief: 'Optimizing worker loop',
          primaryWorkspace: 'MacBook Pro',
          queueStatus: 'Running',
        ),
        AxThread(
          id: 'ws-queued',
          spaceId: 'p-1',
          name: 'Queue integration',
          lead: 'Vitalii',
          status: 'queued',
          brief: 'Queue worker tasks',
          primaryWorkspace: 'MacBook Pro',
          queueStatus: 'Queued',
        ),
        AxThread(
          id: 'ws-failed',
          spaceId: 'p-1',
          name: 'Buggy patch',
          lead: 'Vitalii',
          status: 'failed',
          brief: 'Failed run',
          primaryWorkspace: 'MacBook Pro',
          queueStatus: 'Failed',
        ),
      ],
    );

    testWidgets('Active sidebar route visual check for all route kinds',
        (tester) async {
      const allRoutes = [
        AxNavigation.home(),
        AxNavigation.spaces(),
        AxNavigation.space('p-1'),
        AxNavigation.thread('p-1', 'ws-running'),
        AxNavigation.run('p-1', 'run-1', threadId: 'ws-running'),
        AxNavigation.workspaces(),
        AxNavigation.workspaces(),
        AxNavigation.profileSecurity(),
      ];

      for (final nav in allRoutes) {
        final ctx = AxShellContext(
          navigation: nav,
          spaces: const [spaceA],
          selectedSpace: spaceA,
          expandedSpaceIds: {'p-1'},
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: SyntilaBrand.darkTheme(),
            home: Scaffold(
              body: AxSidebar(
                shellContext: ctx,
                onNavigateTo: (_) {},
                onToggleSpaceExpanded: (_) {},
                onCreateSpace: () {},
                onLogout: () {},
                onOpenAbout: () {},
                onOpenExternal: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Ensure sidebar renders without error
        expect(find.byTooltip('Syntila — Home'), findsOneWidget);
      }
    });

    testWidgets(
        'Space click opens space and toggles expansion only when clicking active space',
        (tester) async {
      AxNavigation? navigatedTo;
      String? toggledSpaceId;

      // 1. Initially on Home (not active space)
      final homeContext = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: [spaceA],
        threadsBySpace: {spaceA.id: spaceA.threads},
        expandedSpaceIds: {},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
              shellContext: homeContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onToggleSpaceExpanded: (id) => toggledSpaceId = id,
              onCreateSpace: () {},
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Threads should not be visible when collapsed
      expect(find.byKey(const ValueKey('sidebar-thread-row-ws-running')),
          findsNothing);
      // Collapsed space shows closed folder icon
      expect(
        find.byWidgetPredicate(
            (w) => w is SyntilaFolderIcon && w.isExpanded == false),
        findsOneWidget,
      );

      // Tap the space item -> should navigate to space and toggle expansion
      await tester.tap(find.byKey(const ValueKey('sidebar-space-row-p-1')));
      expect(navigatedTo?.kind, AxRouteKind.space);
      expect(navigatedTo?.spaceId, 'p-1');
      expect(toggledSpaceId, 'p-1');

      // Reset
      navigatedTo = null;
      toggledSpaceId = null;

      // 2. When expanded
      final expandedSpaceContext = AxShellContext(
        navigation: const AxNavigation.space('p-1'),
        spaces: [spaceA],
        threadsBySpace: {spaceA.id: spaceA.threads},
        selectedSpace: spaceA,
        expandedSpaceIds: {'p-1'},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
              shellContext: expandedSpaceContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onToggleSpaceExpanded: (id) => toggledSpaceId = id,
              onCreateSpace: () {},
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Expanded space shows open folder icon and threads
      expect(
        find.byWidgetPredicate(
            (w) => w is SyntilaFolderIcon && w.isExpanded == true),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('sidebar-thread-row-ws-running')),
          findsOneWidget);

      // Tap the space item again -> toggles expansion to collapse and navigates
      await tester.tap(find.byKey(const ValueKey('sidebar-space-row-p-1')));
      expect(navigatedTo?.kind, AxRouteKind.space);
      expect(toggledSpaceId, 'p-1');
    });

    testWidgets('Thread status dot indicators render for each status',
        (tester) async {
      final expandedContext = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: [spaceA],
        threadsBySpace: {spaceA.id: spaceA.threads},
        expandedSpaceIds: {'p-1'},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
              shellContext: expandedContext,
              onNavigateTo: (_) {},
              onToggleSpaceExpanded: (_) {},
              onCreateSpace: () {},
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sidebar-thread-row-ws-running')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('sidebar-thread-row-ws-queued')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('sidebar-thread-row-ws-failed')),
          findsOneWidget);
    });

    testWidgets(
        'Breadcrumb generation and segment navigation across all routes',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      AxNavigation? navigatedTo;

      // Test 1: Space route -> "Spaces / Syntila Core"
      final spaceContext = AxShellContext(
        navigation: const AxNavigation.space('p-1'),
        spaces: [spaceA],
        threadsBySpace: {spaceA.id: spaceA.threads},
        selectedSpace: spaceA,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: spaceContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Syntila Core'), findsOneWidget);

      // Test 1b: Thread route -> "Syntila Core / WS"
      final threadContext = AxShellContext(
        navigation: const AxNavigation.thread('p-1', 'ws-1'),
        spaces: const [spaceA],
        selectedSpace: spaceA,
        selectedThread: spaceA.threads.first,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: threadContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Syntila Core'), findsOneWidget);
      await tester.tap(find.text('Syntila Core'));
      expect(navigatedTo?.kind, AxRouteKind.space);

      // Test 1c: Workspace route -> "Workspaces / Workspace Name"
      const testWs = AxWorkspace(
        id: 'ws-mac',
        name: 'MacBook Pro',
        hostname: 'macbook-pro',
        status: 'online',
        appVersion: '1.0.0',
        workerCount: 0,
        activeTaskCount: 0,
      );
      final workspaceContext = AxShellContext(
        navigation: const AxNavigation.workspace('ws-mac'),
        spaces: [spaceA],
        threadsBySpace: {spaceA.id: spaceA.threads},
        workspaces: [testWs],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: workspaceContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('MacBook Pro'), findsOneWidget);
      await tester.tap(find.text('Workspaces'));
      expect(navigatedTo?.kind, AxRouteKind.workspaces);
      expect(navigatedTo?.workspaceId, isNull);
    });

    testWidgets(
        'Workspaces status popover shows degraded/reconnecting and failed status',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const degradedCtx = AxShellContext(
        navigation: AxNavigation.home(),
        spaces: [],
        workspaces: [
          AxWorkspace(
            id: 'worker-1',
            name: 'Build Server',
            hostname: 'build-srv',
            status: 'offline',
            platform: 'Linux',
            architecture: 'x86_64',
            appVersion: '0.6.0',
            lastSeen: '10m ago',
            workerCount: 0,
            activeTaskCount: 0,
          ),
        ],
        realtimeStale: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: degradedCtx,
              onNavigateTo: (_) {},
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('0 / 1 Workspace online'), findsOneWidget);
      expect(degradedCtx.executionStatusTone, ExecutionStatusTone.degraded);

      // Tap to open popover
      await tester.tap(find.text('0 / 1 Workspace online'));
      await tester.pumpAndSettle();

      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Build Server'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
    });

    testWidgets(
        'Command Palette HUD control responds to click in desktop, tablet, and mobile',
        (tester) async {
      var commandPaletteOpened = false;

      const shellContext = AxShellContext(
        navigation: AxNavigation.home(),
        spaces: [],
      );

      // 1. Desktop
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onOpenCommandPalette: () => commandPaletteOpened = true,
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Search or jump to...'));
      expect(commandPaletteOpened, isTrue);

      // 2. Compact / Mobile
      commandPaletteOpened = false;
      tester.view.physicalSize = const Size(450, 800);
      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onOpenCommandPalette: () => commandPaletteOpened = true,
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
              compact: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Search'));
      expect(commandPaletteOpened, isTrue);
    });

    testWidgets('Regression Assertions: shell contains no legacy mental models',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: [spaceA],
        threadsBySpace: {spaceA.id: spaceA.threads},
        selectedSpace: spaceA,
        expandedSpaceIds: {'p-1'},
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: Row(
              children: [
                AxSidebar(
                  shellContext: shellContext,
                  onNavigateTo: (_) {},
                  onToggleSpaceExpanded: (_) {},
                  onCreateSpace: () {},
                  onLogout: () {},
                  onOpenAbout: () {},
                  onOpenExternal: (_) {},
                ),
                Expanded(
                  child: Scaffold(
                    appBar: AxTopBar(
                      shellContext: shellContext,
                      onNavigateTo: (_) {},
                      onOpenCommandPalette: () {},
                      onToggleTheme: () {},
                      onOpenNotifications: () {},
                      onOpenAbout: () {},
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Regression checks:
      // 1. No "New chat" button in shell
      expect(find.text('New chat'), findsNothing);

      // 2. No "New goal" button in shell
      expect(find.text('New goal'), findsNothing);

      // 3. No generic "Back to chat" button
      expect(find.text('Back to chat'), findsNothing);

      // 4. HUD heading is "Home" (from route breadcrumb), NOT generic "Workspace"
      expect(find.text('Home'), findsWidgets);
      // "Workspaces" only appears as the nav section item in sidebar, never as HUD title for Home
      expect(find.text('Workspace'), findsNothing);
    });

    testWidgets(
        'Phase 8: Space tree centerpiece with trailing meaningful status dots and contextual create',
        (tester) async {
      var createSpaceCalled = false;

      const space = AxSpace(
        id: 'p-1',
        name: 'Syntila',
        branch: 'main',
        lastActivity: 'today',
        threads: [
          AxThread(
            id: 'ws-1',
            spaceId: 'p-1',
            name: 'Authentication redesign',
            lead: 'Vitalii',
            status: 'running',
            brief: 'Redesign login flow',
            primaryWorkspace: 'MacBook Pro',
            queueStatus: 'Running',
          ),
          AxThread(
            id: 'ws-2',
            spaceId: 'p-1',
            name: 'Landing page',
            lead: 'Vitalii',
            status: 'idle',
            brief: 'Landing page work',
            primaryWorkspace: 'MacBook Pro',
            queueStatus: 'Idle',
          ),
          AxThread(
            id: 'ws-3',
            spaceId: 'p-1',
            name: 'Scheduler',
            lead: 'Vitalii',
            status: 'queued',
            brief: 'Scheduler updates',
            primaryWorkspace: 'MacBook Pro',
            queueStatus: 'Queued',
          ),
        ],
      );

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: [space],
        threadsBySpace: {space.id: space.threads},
        selectedSpace: space,
        expandedSpaceIds: {'p-1'},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onToggleSpaceExpanded: (_) {},
              onCreateSpace: () => createSpaceCalled = true,
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Space rows display the space name without legacy Goal counts.
      expect(
          find.byKey(const ValueKey('sidebar-space-row-p-1')), findsOneWidget);
      expect(find.text('5'), findsNothing);

      // Thread rows are rendered
      expect(find.byKey(const ValueKey('sidebar-thread-row-ws-1')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('sidebar-thread-row-ws-2')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('sidebar-thread-row-ws-3')),
          findsOneWidget);

      // Test New Space button in sidebar header row
      await tester.tap(find.byTooltip('New Space'));
      await tester.pumpAndSettle();
      expect(createSpaceCalled, isTrue);
    });

    testWidgets(
        'Phase 9: Fix Home/Spaces active navigation isolation across all routes',
        (tester) async {
      const ws1 = AxThread(
        id: 'ws-1',
        spaceId: 'p-1',
        name: 'Authentication redesign',
        lead: 'Vitalii',
        status: 'running',
        brief: 'Redesign login flow',
        primaryWorkspace: 'MacBook Pro',
        queueStatus: 'Running',
      );

      const space = AxSpace(
        id: 'p-1',
        name: 'Syntila',
        branch: 'main',
        lastActivity: 'today',
        threads: [ws1],
      );

      // 1. On Home route (/)
      final homeCtx = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: [space],
        threadsBySpace: {space.id: space.threads},
        expandedSpaceIds: {'p-1'},
      );
      expect(homeCtx.isNavActive(const AxNavigation.home()), isTrue);
      expect(homeCtx.isNavActive(const AxNavigation.spaces()), isFalse);

      // 2. On Spaces list (/spaces)
      final spacesCtx = AxShellContext(
        navigation: const AxNavigation.spaces(),
        spaces: [space],
        threadsBySpace: {space.id: space.threads},
        expandedSpaceIds: {'p-1'},
      );
      expect(spacesCtx.isNavActive(const AxNavigation.home()), isFalse);
      expect(spacesCtx.isNavActive(const AxNavigation.spaces()), isTrue);

      // 3. On Space detail (/spaces/p-1)
      final spaceDetailCtx = AxShellContext(
        navigation: const AxNavigation.space('p-1'),
        spaces: [space],
        threadsBySpace: {space.id: space.threads},
        selectedSpace: space,
        expandedSpaceIds: {'p-1'},
      );
      expect(spaceDetailCtx.isNavActive(const AxNavigation.home()), isFalse);
      expect(spaceDetailCtx.isNavActive(const AxNavigation.spaces()), isTrue);

      // 4. On Thread detail (/spaces/p-1/threads/ws-1)
      final threadCtx = AxShellContext(
        navigation: const AxNavigation.thread('p-1', 'ws-1'),
        spaces: [space],
        threadsBySpace: {space.id: space.threads},
        selectedSpace: space,
        selectedThread: ws1,
        expandedSpaceIds: {'p-1'},
      );
      expect(threadCtx.isNavActive(const AxNavigation.home()), isFalse);
      expect(threadCtx.isNavActive(const AxNavigation.spaces()), isTrue);

      // 5. On Run detail (/spaces/p-1/threads/ws-1/runs/r-1)
      final runCtx = AxShellContext(
        navigation: const AxNavigation.run('p-1', 'r-1', threadId: 'ws-1'),
        spaces: [space],
        threadsBySpace: {space.id: space.threads},
        selectedSpace: space,
        selectedThread: ws1,
        expandedSpaceIds: {'p-1'},
      );
      expect(runCtx.isNavActive(const AxNavigation.home()), isFalse);
      expect(runCtx.isNavActive(const AxNavigation.spaces()), isTrue);

      // 6. Verify Visual UI: when on Thread, Thread item is highlighted, Home is not
      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
              shellContext: threadCtx,
              onNavigateTo: (_) {},
              onToggleSpaceExpanded: (_) {},
              onCreateSpace: () {},
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Home container has transparent background, Spaces nav is active
      expect(find.byKey(const ValueKey('sidebar-thread-row-ws-1')),
          findsOneWidget);
    });

    testWidgets(
        'Phase 11: Responsive layout adapts across Desktop, Medium (Rail), and Mobile',
        (tester) async {
      const ws = AxThread(
        id: 'ws-1',
        spaceId: 'p-1',
        name: 'Authentication redesign',
        lead: 'Vitalii',
        status: 'running',
        brief: 'Redesign login flow',
        primaryWorkspace: 'MacBook Pro',
        queueStatus: 'Running',
      );

      const space = AxSpace(
        id: 'p-1',
        name: 'Syntila',
        branch: 'main',
        lastActivity: 'today',
        threads: [ws],
      );

      final shellContext = AxShellContext(
        navigation: const AxNavigation.thread('p-1', 'ws-1'),
        spaces: [space],
        threadsBySpace: {space.id: space.threads},
        selectedSpace: space,
        selectedThread: ws,
        expandedSpaceIds: {'p-1'},
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
      );

      Widget buildAppScaffold() {
        final scaffoldKey = GlobalKey<ScaffoldState>();
        return MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: LayoutBuilder(
            builder: (context, constraints) {
              final isDesktop = SyntilaBrand.isDesktop(constraints.maxWidth);

              return Scaffold(
                key: scaffoldKey,
                drawer: !isDesktop
                    ? Drawer(
                        child: AxSidebar(
                          shellContext: shellContext,
                          onNavigateTo: (_) {},
                          onToggleSpaceExpanded: (_) {},
                          onCreateSpace: () {},
                          onOpenCommandPalette: _dummyAction,
                          onOpenNotifications: _dummyAction,
                          onLogout: () {},
                          onOpenAbout: () {},
                          onOpenExternal: (_) {},
                          compact: true,
                        ),
                      )
                    : null,
                body: Row(
                  children: [
                    if (isDesktop)
                      SizedBox(
                        width: 248,
                        child: AxSidebar(
                          shellContext: shellContext,
                          onNavigateTo: _dummyNav,
                          onToggleSpaceExpanded: _dummyToggle,
                          onCreateSpace: _dummyAction,
                          onOpenCommandPalette: _dummyAction,
                          onOpenNotifications: _dummyAction,
                          onLogout: _dummyAction,
                          onOpenAbout: _dummyAction,
                          onOpenExternal: _dummyExternal,
                        ),
                      ),
                    Expanded(
                      child: Column(
                        children: [
                          if (!isDesktop)
                            AxTopBar(
                              shellContext: shellContext,
                              onNavigateTo: _dummyNav,
                              onOpenCommandPalette: _dummyAction,
                              onOpenNotifications: _dummyAction,
                              compact: true,
                            ),
                          const Expanded(child: SizedBox()),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      }

      // 1. Desktop mode (>= 500, test at 1000 x 800)
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(buildAppScaffold());
      await tester.pumpAndSettle();

      // Full sidebar visible with space tree, search & alarm button
      expect(find.byType(AxSidebar), findsOneWidget);
      expect(find.byType(AxTopBar), findsNothing); // Top HUD hidden on desktop
      expect(find.byKey(const ValueKey('sidebar-thread-row-ws-1')),
          findsOneWidget); // sidebar item
      expect(find.byTooltip('Search...'),
          findsOneWidget); // Search icon on sidebar
      expect(
          find.byTooltip('Notifications'), findsOneWidget); // Alarm on sidebar
      expect(
          find.byTooltip('Open menu'), findsNothing); // No hamburger on desktop

      // 2. Tablet mode (< 500, test at 400 x 800)
      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpWidget(buildAppScaffold());
      await tester.pumpAndSettle();

      // Top HUD visible with breadcrumb and hamburger menu, pinned sidebar hidden
      expect(find.byType(AxTopBar), findsOneWidget);
      expect(find.byTooltip('Syntila — Spaces'), findsOneWidget);
      expect(find.text('Syntila'), findsOneWidget); // breadcrumb space
      expect(find.text('Authentication redesign'),
          findsOneWidget); // breadcrumb thread

      expect(find.byTooltip('Open menu'), findsNothing);
      expect(find.byTooltip('Syntila — Spaces'), findsOneWidget);
      expect(find.byTooltip('Profile & Settings'), findsNothing);
      expect(find.byTooltip('Application menu'), findsOneWidget);
    });

    testWidgets(
        'About dialog displays title, version badge, description, and website action',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: const Scaffold(
            body: SyntilaAppShell(
              services: DefaultPlatformServices(),
              dataSource: AxFixtureDataSource(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open application menu
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      // Tap About Syntila to trigger dialog
      await tester.tap(find.text('About Syntila'));
      await tester.pumpAndSettle();

      // Assert modal dialog contents
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Version 0.1.0'), findsOneWidget);
      expect(
          find.textContaining(
              'people and AI Workers together in Spaces and Threads'),
          findsOneWidget);
      expect(
          find.textContaining('Team conversations, AI requests, and results'),
          findsOneWidget);
      expect(find.textContaining('Syntila Workspace and the provider CLIs'),
          findsOneWidget);
      expect(find.textContaining('coordinates AI Workers across models'),
          findsNothing);
      expect(find.textContaining('Provider-Independent'), findsNothing);
      expect(find.text('Docs'), findsNothing);
      expect(find.text('GitHub'), findsNothing);
      expect(find.text('Website'), findsNothing);
      expect(find.text('Close'), findsOneWidget);
      expect(find.text('Visit website'), findsOneWidget);

      // Close dialog
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets(
        'Phase 6: Accepting invitation on zero-space screen navigates directly into accepted space without reload',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final data = _InvitationTestFixture();
      await tester.pumpWidget(MaterialApp(
        home: SyntilaAppShell(
          services: const DefaultPlatformServices(),
          dataSource: data,
        ),
      ));
      await tester.pumpAndSettle();

      // Zero-space screen with Pending Invitation in Join a Space priority card
      expect(find.text('Welcome to Syntila'), findsOneWidget);
      expect(find.text('Join a Space'), findsOneWidget);
      expect(find.text('You have 1 invitation.'), findsOneWidget);
      expect(find.text('Joined AX Core'), findsWidgets);

      // Tap Accept
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();

      // Invitation is accepted and disappears, user is navigated into space
      expect(find.text('Welcome to Syntila'), findsNothing);
      expect(find.text('Join a Space'), findsNothing);
      expect(find.text('Joined AX Core'), findsWidgets);

      // Drain toast timer
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'Phase 25: Integrated invitation UX — Accepting invitation from established Home instantly synchronizes Home, sidebar Spaces, notification badge, and navigates into space',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final data = _InvitationTestFixture(
        initialSpaces: const [
          AxSpace(
            id: 'existing-proj-1',
            name: 'Existing Space',
            description: 'Main space',
            branch: 'main',
            lastActivity: '2026-10-07T10:00:00Z',
          ),
        ],
      );

      await tester.pumpWidget(MaterialApp(
        home: SyntilaAppShell(
          services: const DefaultPlatformServices(),
          dataSource: data,
        ),
      ));
      await tester.pumpAndSettle();

      // Established Home is visible
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('For you'), findsOneWidget);
      expect(find.text('Joined AX Core'), findsOneWidget);
      expect(find.text('Pending invitations (1)'), findsOneWidget);

      // Tap Accept on Home invitation
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();

      // Instantly without reload:
      // 1. Navigates into newly joined space
      expect(find.text('Joined AX Core'), findsWidgets);
      // 3. Pending invitations in sidebar is gone
      expect(find.text('Pending invitations (1)'), findsNothing);

      // Drain toast timer
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets(
      'sign-up sends a 6-digit verification code before creating the account',
      (tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final data = _SignUpOtpFixture();
    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: data,
        initialUri: Uri.parse('/login'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Syntila'), findsOneWidget);
    await tester.tap(find.text('New here? Create an account'));
    await tester.pumpAndSettle();

    expect(find.text('Create your account'), findsOneWidget);
    final password =
        tester.widget<TextField>(find.widgetWithText(TextField, 'Password'));
    expect(password.decoration!.hintText, 'At least 8 characters');
    expect(password.decoration!.helperText, isNull);

    expect(find.text('Already have an account? Sign in'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Ada Lovelace',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Email'),
      'ada@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'strong-password-123',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Confirm password'),
      'strong-password-123',
    );

    final createButton = find.widgetWithText(FilledButton, 'Create account');
    await tester.ensureVisible(createButton);
    await tester.tap(createButton);
    await tester.pumpAndSettle();

    expect(data.codeRequestedForEmail, 'ada@example.com');
    expect(data.codeRequestedForName, 'Ada Lovelace');
    expect(data.signedUpOtp, isNull);
    expect(find.text('Verify your email address'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Verification code'), findsOneWidget);
    expect(find.text('Edit details'), findsNothing);
    expect(find.text('Already have an account? Sign in'), findsNothing);
    expect(find.textContaining('Enter it below'), findsNothing);
    expect(
        find.text(
            'Enter the 6-digit verification code we sent to ada@example.com.'),
        findsOneWidget);
    await tester.tap(find.text('Resend code'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'A new 6-digit verification code was sent to ada@example.com.'),
        findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Verification code'),
      '482910',
    );
    final verifyButton =
        find.widgetWithText(FilledButton, 'Verify & create account');
    await tester.ensureVisible(verifyButton);
    await tester.tap(verifyButton);
    await tester.pumpAndSettle();

    expect(data.signedUpEmail, 'ada@example.com');
    expect(data.signedUpName, 'Ada Lovelace');
    expect(data.signedUpOtp, '482910');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'preserves password reset token across unauthenticated session check and resets password',
      (tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final data = _PasswordResetFixture();
    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: data,
        initialUri: Uri.parse('/login?token=reset-token-abc'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Choose a new password'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Confirm password'), findsOneWidget);
    expect(find.text('Continue with GitHub'), findsNothing);

    // Password visibility toggle works
    expect(find.byTooltip('Show password'), findsNWidgets(2));
    await tester.tap(find.byTooltip('Show password').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hide password'), findsOneWidget);

    // Empty submission shows specific validation message
    await tester.tap(find.widgetWithText(FilledButton, 'Save new password'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a new password.'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'updated-secret-999',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Confirm password'),
      'updated-secret-999',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save new password'));
    await tester.pumpAndSettle();

    expect(data.resetTokenUsed, 'reset-token-abc');
    expect(data.resetNewPasswordUsed, 'updated-secret-999');
    expect(
      find.text('Password changed. You can sign in now.'),
      findsOneWidget,
    );
    expect(find.text('Welcome to Syntila'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'preserves OAuth error banner on /login and blocks contextual create shortcut while unauthenticated',
      (tester) async {
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const data = AxFixtureDataSource(authenticated: false);
    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: data,
        initialUri: Uri.parse('/login?error=account_not_linked'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'An account with this email already exists. Sign in with your email and password, then link Google or GitHub in your profile security settings.',
      ),
      findsOneWidget,
    );

    // Pressing Meta+N or Control+N while unauthenticated must not open Create Space dialog
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(find.text('Create Space'), findsNothing);

    // Account creation offers email registration and a return to sign in.
    await tester.tap(find.text('New here? Create an account'));
    await tester.pumpAndSettle();

    expect(find.text('Already have an account? Sign in'), findsNothing);
    expect(find.text('Back to sign in'), findsOneWidget);
    expect(find.text('Continue with GitHub'), findsNothing);
    expect(find.text('Continue with Google'), findsNothing);

    await tester.tap(find.text('Back to sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Create your account'), findsNothing);
    expect(find.text('Sign in with email'), findsOneWidget);
    expect(find.text('Continue with GitHub'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

void _dummyNav(AxNavigation _) {}
void _dummyToggle(String _) {}
void _dummyAction() {}
void _dummyExternal(Uri _) {}

class _PasswordResetFixture extends AxFixtureDataSource {
  _PasswordResetFixture() : super(authenticated: false);

  String? resetTokenUsed;
  String? resetNewPasswordUsed;

  @override
  Future<void> resetPassword({
    required String token,
    required String password,
  }) async {
    resetTokenUsed = token;
    resetNewPasswordUsed = password;
  }
}

class _SignUpOtpFixture extends AxFixtureDataSource {
  _SignUpOtpFixture() : super(authenticated: false);

  String? codeRequestedForEmail;
  String? codeRequestedForName;
  String? signedUpEmail;
  String? signedUpName;
  String? signedUpOtp;

  @override
  Future<void> requestSignUpVerificationCode({
    required String email,
    String? name,
  }) async {
    codeRequestedForEmail = email;
    codeRequestedForName = name;
  }

  @override
  Future<void> signUpWithEmail({
    required String name,
    required String email,
    required String password,
    String? otp,
  }) async {
    signedUpName = name;
    signedUpEmail = email;
    signedUpOtp = otp;
    await super.signUpWithEmail(
      name: name,
      email: email,
      password: password,
      otp: otp,
    );
  }

  static const _spaces = [
    AxSpace(
      id: 'existing-proj-1',
      name: 'Existing Space',
      description: 'Main space',
      branch: 'main',
      lastActivity: '2026-10-07T10:00:00Z',
    ),
  ];

  @override
  Future<AxSnapshot> loadBootstrapState({
    String? spaceId,
    String? workspaceId,
  }) async {
    final base = await super.loadBootstrapState(
      spaceId: spaceId,
      workspaceId: workspaceId,
    );
    return base.copyWith(spaces: _spaces);
  }

  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async =>
      _spaces;
}

class _SpaceScopedFixture extends AxFixtureDataSource {
  final selectedSpaces = <String>[];
  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async {
    selectedSpaces.add(spaceId);
    if (spaceId != 'atlas') {
      return super.loadSpaceThreads(spaceId: spaceId);
    }
    return const [
      AxThread(
          id: 'atlas-chat',
          spaceId: 'atlas',
          name: 'Atlas conversation',
          lead: 'Test',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: 'Idle')
    ];
  }
}

class _DelayedAccountSecurityDataSource extends AxFixtureDataSource {
  _DelayedAccountSecurityDataSource();

  final _securityCompleter = Completer<AxAccountSecurity>();
  var securityLoadCalls = 0;

  void complete() {
    if (_securityCompleter.isCompleted) return;
    _securityCompleter.complete(
      const AxAccountSecurity(
        accounts: [
          AxAuthAccount(
              id: 'account-github', providerId: 'github', accountId: 'gh-1'),
          AxAuthAccount(
              id: 'account-credentials',
              providerId: 'credentials',
              accountId: 'user@example.com'),
        ],
        sessions: [
          AxAuthSession(
            token: 'fixture-session-token',
            id: 'fixture-session',
            createdAt: '2026-09-23T10:00:00Z',
            expiresAt: '2026-10-07T10:00:00Z',
            userAgent: 'Fixture browser',
          ),
          AxAuthSession(
            token: 'fixture-other-session-token',
            id: 'fixture-other-session',
            createdAt: '2026-09-22T10:00:00Z',
            expiresAt: '2026-10-06T10:00:00Z',
            userAgent: 'Other browser',
          ),
        ],
      ),
    );
  }

  @override
  Future<AxAccountSecurity> loadAccountSecurity() {
    securityLoadCalls++;
    return _securityCompleter.future;
  }
}

class _RemovableAccountFixture extends AxFixtureDataSource {
  var removed = false;

  @override
  Future<AxSession> loadSession() async =>
      removed ? const AxSession(authenticated: false) : super.loadSession();
}

class _EmailChangeFixture extends AxFixtureDataSource {
  @override
  Future<AxSession> loadSession() async => const AxSession(
        authenticated: true,
        sessionId: 'fixture-session',
        viewer: AxViewer(
            id: 'user-1', displayName: 'Person', email: 'old@example.test'),
      );
}

class _DeleteAccountFixture extends AxFixtureDataSource {
  var deleted = false;
  String? confirmEmail;
  final viewerEmail = 'person@example.test';

  @override
  Future<AxSession> loadSession() async => AxSession(
        authenticated: true,
        sessionId: 'fixture-session',
        viewer:
            AxViewer(id: 'user-1', displayName: 'Person', email: viewerEmail),
      );

  @override
  Future<void> deleteAccount({required String confirmEmail}) async {
    deleted = true;
    this.confirmEmail = confirmEmail;
  }
}

class _InvitationTestFixture extends AxFixtureDataSource {
  _InvitationTestFixture({this.initialSpaces = const []});

  final List<AxSpace> initialSpaces;
  var pendingInvitations = <AxSpaceInvitation>[
    const AxSpaceInvitation(
      id: 'inv-invite-1',
      spaceId: 'proj-joined-1',
      spaceName: 'Joined AX Core',
      email: 'user@example.com',
      role: 'member',
      status: 'pending',
      invitedByUserId: 'u-1',
      invitedByUserName: 'Vitalii Noha',
      createdAt: '2026-10-07T12:00:00Z',
    ),
  ];

  @override
  Future<AxSnapshot> loadBootstrapState(
      {String? spaceId, String? workspaceId}) async {
    final base = await super
        .loadBootstrapState(spaceId: spaceId, workspaceId: workspaceId);
    return base.copyWith(spaces: initialSpaces);
  }

  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async =>
      initialSpaces;

  @override
  Future<List<AxSpaceInvitation>> loadCurrentUserInvitations() async =>
      pendingInvitations;

  @override
  Future<void> acceptSpaceInvitation({required String invitationId}) async {
    pendingInvitations =
        pendingInvitations.where((i) => i.id != invitationId).toList();
  }

  @override
  Future<void> declineSpaceInvitation({required String invitationId}) async {
    pendingInvitations =
        pendingInvitations.where((i) => i.id != invitationId).toList();
  }
}

class _LinkedProvidersFixture extends AxFixtureDataSource {
  _LinkedProvidersFixture(this.providers, {this.sessions = const []});
  final List<AxAuthSession> sessions;
  final List<String> providers;
  bool failUnlink = false;
  Future<void>? unlinkGate;
  final unlinkedIds = <String>[];

  @override
  Future<void> unlinkAccount({required String accountId}) async {
    unlinkedIds.add(accountId);
    if (failUnlink) throw Exception('Keep another sign-in method');
    if (unlinkGate != null) await unlinkGate;
    providers.remove(accountId);
  }

  @override
  Future<AxAccountSecurity> loadAccountSecurity() async => AxAccountSecurity(
        accounts: providers
            .map((provider) => AxAuthAccount(
                id: provider, providerId: provider, accountId: provider))
            .toList(),
        sessions: sessions,
      );
}
