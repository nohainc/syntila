import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_app.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/home/home_page.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'package:syntila_app/src/navigation/ax_browser_navigation.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'ax_fixture_data.dart';
import 'ax_fixture_realtime.dart';

class InvitationsTestNavigation implements AxBrowserNavigation {
  InvitationsTestNavigation(this.current);
  @override
  Uri current;
  final controller = StreamController<Uri>.broadcast(sync: true);
  @override
  Stream<Uri> get changes => controller.stream;
  @override
  Stream<void> get lifecycleChanges => const Stream.empty();

  @override
  void push(Uri uri) {
    current = uri;
    controller.add(uri);
  }

  @override
  void replace(Uri uri) {
    current = uri;
    controller.add(uri);
  }

  @override
  void replaceWithLogin(Uri returnTo) {
    current = Uri(path: '/login');
  }

  @override
  void startSocialLogin(String provider, Uri returnTo) {}
  @override
  void openExternal(Uri uri) {}
  @override
  bool closeCurrentWindow() => false;
  @override
  void dispose() {
    unawaited(controller.close());
  }
}

class InvitationsE2eDataSource extends AxFixtureDataSource {
  InvitationsE2eDataSource({
    this.initialSpaces = const [],
    this.initialInvitations = const [],
  }) {
    spaces = List.of(initialSpaces);
    invitations = List.of(initialInvitations);
  }

  final List<AxSpace> initialSpaces;
  final List<AxSpaceInvitation> initialInvitations;
  late List<AxSpace> spaces;
  late List<AxSpaceInvitation> invitations;

  int acceptCalls = 0;
  int declineCalls = 0;
  int refreshInvitationsCalls = 0;

  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async =>
      spaces;

  @override
  Future<List<AxSpaceInvitation>> loadCurrentUserInvitations() async {
    refreshInvitationsCalls++;
    return invitations;
  }

  @override
  Future<void> acceptSpaceInvitation({required String invitationId}) async {
    acceptCalls++;
    final invite = invitations.firstWhere((item) => item.id == invitationId);
    invitations.removeWhere((item) => item.id == invitationId);
    spaces.add(AxSpace(
      id: invite.spaceId,
      name: invite.spaceName.isNotEmpty ? invite.spaceName : 'New Space',
      branch: 'main',
      lastActivity: DateTime.now().toIso8601String(),
      role: invite.role,
    ));
  }

  @override
  Future<void> declineSpaceInvitation({required String invitationId}) async {
    declineCalls++;
    invitations.removeWhere((item) => item.id == invitationId);
  }

  @override
  Future<AxSpace> loadSpace({required String spaceId}) async {
    final proj = spaces.firstWhere(
      (p) => p.id == spaceId,
      orElse: () => AxSpace(
        id: spaceId,
        name: 'Space $spaceId',
        branch: 'main',
        lastActivity: '',
        role: 'collaborator',
      ),
    );
    return proj;
  }

  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async =>
      [];

  @override
  Future<AxSnapshot> loadBootstrapState({String? spaceId}) async {
    return AxSnapshot(
      spaces: spaces,
      tasks: const [],
      findings: const [],
      events: const [],
      artifacts: const [],
    );
  }
}

void main() {
  testWidgets(
      'zero-space user discovers invitation on Welcome screen and opens space on accept without app reload',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const invite = AxSpaceInvitation(
      id: 'pinv-hero-1',
      spaceId: 'proj-collab',
      spaceName: 'Syntila Development',
      email: 'ulikossnokia@gmail.com',
      role: 'collaborator',
      status: 'pending',
      invitedByUserName: 'Vitalii Noha',
      invitedByUserEmail: 'vitalii@nohainc.com',
      createdAt: '2026-10-07T12:00:00Z',
    );

    final dataSource = InvitationsE2eDataSource(
      initialSpaces: [],
      initialInvitations: [invite],
    );
    final browser = InvitationsTestNavigation(Uri.parse('/'));
    final realtime = TestRealtime();

    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        dataSource: dataSource,
        services: const DefaultPlatformServices(),
        browserNavigation: browser,
        realtimeClient: realtime,
      ),
    ));
    await tester.pumpAndSettle();

    // 1. Zero-space recipient with pending invitation renders NewUserHome with Join a Space priority card
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.text('Welcome to Syntila'), findsOneWidget);
    expect(find.text('Join a Space'), findsOneWidget);
    expect(find.text('You have 1 invitation.'), findsOneWidget);
    expect(find.text('Syntila Development'), findsWidgets);
    expect(find.text('Accept'), findsWidgets);

    // 2. Click Accept invitation
    await tester.tap(find.text('Accept').first);
    await tester.pump();
    await tester.pumpAndSettle();

    // 3. Verify instantaneous navigation into accepted Space without app reload
    expect(dataSource.acceptCalls, 1);
    expect(find.byType(NewThreadPage), findsOneWidget);
    expect(find.text('Syntila Development'), findsWidgets);
    expect(browser.current.path, '/spaces/proj-collab');

    // Drain toast timer
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'online recipient receives invitation via realtime event and updates badge/inbox',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dataSource = InvitationsE2eDataSource(
      initialSpaces: [
        const AxSpace(
          id: 'proj-1',
          name: 'Existing Space',
          branch: 'main',
          lastActivity: '',
        )
      ],
      initialInvitations: [],
    );
    final browser = InvitationsTestNavigation(Uri.parse('/'));
    final realtime = TestRealtime();

    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        dataSource: dataSource,
        services: const DefaultPlatformServices(),
        browserNavigation: browser,
        realtimeClient: realtime,
      ),
    ));
    await tester.pumpAndSettle();

    // Initially no pending invitations
    expect(find.text('Pending invitations (1)'), findsNothing);

    // Vitalii sends invitation -> Cloud fans out realtime event to online recipient
    dataSource.invitations = [
      const AxSpaceInvitation(
        id: 'pinv-live-2',
        spaceId: 'proj-live',
        spaceName: 'Live Shared Space',
        email: 'ulikossnokia@gmail.com',
        role: 'collaborator',
        status: 'pending',
        invitedByUserName: 'Vitalii Noha',
        createdAt: '2026-10-07T12:00:00Z',
      )
    ];

    realtime.emit({
      'type': 'space.updated',
      'spaceId': 'proj-live',
      'payload': {'entityId': 'pinv-live-2'},
    });
    await tester.pump();
    await tester.pumpAndSettle();

    // Bell icon badge and sidebar show Pending invitations (1)
    expect(find.text('Pending invitations (1)'), findsWidgets);
    expect(find.textContaining('Live Shared Space'), findsWidgets);
    // The arrival is announced in the Notification Center, not only listed.
    await tester.tap(find.byTooltip('Notifications').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Vitalii Noha invited you to Live Shared Space'),
        findsWidgets);
  });
}
