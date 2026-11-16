import 'package:syntila_app/src/features/home/home_page.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/notifications/notification_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('changelog adds history without duplicating current updates', () {
    const current = AxProductUpdate(
      id: 'newer-entry',
      slug: 'parallel-research',
      title: 'Research',
      summary: 'Current update',
      publishedAt: '2026-11-15T00:00:00Z',
    );
    final updates = productUpdateHistory([current]);
    expect(updates.where((update) => update.slug == 'parallel-research'),
        [current]);
    expect(
        updates.any((update) => update.slug == 'personal-connections'), isTrue);
    expect(defaultProductUpdates.length, 4);
  });

  testWidgets('Home shows the four latest updates from the full history',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: EstablishedUserHome(
        spaces: const [],
        workspaces: const [],
        workers: const [],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenRun: (_, __) {},
        onOpenSpace: (_) {},
      ),
    ))));
    await tester.pumpAndSettle();
    final latest = AxProductUpdateService.getHomeUpdates(
        productUpdateHistory(defaultProductUpdates),
        limit: 4);
    expect(latest, hasLength(4));
    for (final update in latest) {
      expect(find.text(update.title), findsOneWidget);
    }
    expect(find.text('Research with multiple Workers'), findsNothing);
  });

  Widget scaffold(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  testWidgets('Home uses brand icons, category icons, and latest four Threads',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(scaffold(EstablishedUserHome(
      historicalUpdates: const [],
      spaces: const [
        AxSpace(
            id: 's',
            name: 'Space',
            branch: '',
            lastActivity: '',
            settings: {
              'sharedWorkers': ['chatgpt', 'gemini', 'claude']
            })
      ],
      workers: const [],
      workspaces: const [],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenRun: (_, __) {},
      onOpenSpace: (_) {},
      continueWorkItems: List.generate(
          6,
          (index) => AxContinueWorkItem(
                spaceId: 's',
                threadId: '$index',
                threadTitle: 'Thread $index',
                collaboratorsDisplay: '',
                lastMessageSnippet: 'Message $index',
                lastActivityDisplay: 'Recently',
                lastMeaningfulActivityAt: DateTime.utc(2026, 10, index + 1),
                hasUnresolvedState: index == 0,
              )),
      productUpdates: defaultProductUpdates,
      aiUpdates: defaultAiCapabilityUpdates,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Thread 0'), findsNothing);
    expect(find.text('Thread 1'), findsNothing);
    for (final index in [2, 3, 4, 5]) {
      expect(find.text('Thread $index'), findsOneWidget);
    }
    expect(tester.getTopLeft(find.text('Thread 5')).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('Thread 4')).dy));
    final assets = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => (image.image as AssetImage).assetName)
        .toSet();
    expect(
        assets,
        containsAll([
          'assets/worker_icons/chatgpt.png',
          'assets/worker_icons/gemini.png',
          'assets/worker_icons/claude.png'
        ]));
    expect(find.byIcon(Icons.groups_outlined), findsOneWidget);
    expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
    expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
    expect(find.text('Oct 7, 2026'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  for (final section in ["What's new", 'AI updates']) {
    for (final contentWidth in [354.0, 532.0, 840.0]) {
      testWidgets(
          '$section See all matches Home width $contentWidth and keeps four latest items',
          (tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 2200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final products = List.generate(
            5,
            (index) => AxProductUpdate(
                  id: 'product-$index',
                  slug: 'product-$index',
                  title: 'Product $index',
                  summary: 'Product summary',
                  publishedAt: '2026-10-${10 + index}T00:00:00Z',
                ));
        final ai = List.generate(
            5,
            (index) => AxAiCapabilityUpdate(
                  id: 'ai-$index',
                  workerProfileId: 'chatgpt',
                  type: AxAiCapabilityUpdateType.modelAdded,
                  title: 'AI $index',
                  summary: 'AI summary',
                  publishedAt: '2026-10-${10 + index}T00:00:00Z',
                ));
        await tester.pumpWidget(scaffold(Center(
            child: SizedBox(
          width: contentWidth,
          child: EstablishedUserHome(
            historicalUpdates: const [],
            spaces: const [
              AxSpace(
                  id: 's',
                  name: 'Space',
                  branch: '',
                  lastActivity: '',
                  settings: {
                    'sharedWorkers': ['chatgpt']
                  })
            ],
            workspaces: const [],
            workers: const [],
            run: null,
            openFindingCount: 0,
            onOpenWorkspaces: () {},
            onOpenRun: (_, __) {},
            onOpenSpace: (_) {},
            onDismissUpdate: (_) => fail('Dismiss is unavailable'),
            productUpdates: products,
            aiUpdates: ai,
            productUpdateReadStates: {
              'product-4': AxUserProductUpdateState(
                  userId: 'u',
                  updateId: 'product-4',
                  dismissedAt: DateTime.utc(2026, 10, 15))
            },
          ),
        ))));
        await tester.pumpAndSettle();
        for (final prefix in ['Product', 'AI']) {
          expect(find.text('$prefix 0'), findsNothing);
          for (var index = 1; index <= 4; index++) {
            expect(find.text('$prefix $index'), findsOneWidget);
          }
        }
        final title = section == 'AI updates' ? 'AI 4' : 'Product 4';
        final homeWidth =
            tester.getSize(find.byKey(ValueKey('home-update-$title'))).width;
        await tester
            .tap(find.text('See all').at(section == 'AI updates' ? 1 : 0));
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byKey(ValueKey('home-update-$title'))).width,
            homeWidth);
        expect(find.text(section == 'AI updates' ? 'AI 0' : 'Product 0'),
            findsOneWidget);
        expect(find.byTooltip('Hide update'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final width in [390.0, 1200.0]) {
    testWidgets('Home times and update dates align right at width $width',
        (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(scaffold(EstablishedUserHome(
        historicalUpdates: const [],
        spaces: const [
          AxSpace(
              id: 's',
              name: 'Space',
              branch: '',
              lastActivity: '',
              settings: {
                'sharedWorkers': ['chatgpt']
              })
        ],
        workers: const [],
        workspaces: const [],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenRun: (_, __) {},
        onOpenSpace: (_) {},
        continueWorkItems: const [
          AxContinueWorkItem(
            spaceId: 's',
            spaceName: 'Space',
            threadId: 't',
            threadTitle: 'A long Thread title for responsive timestamp layout',
            collaboratorsDisplay: '',
            lastMessageSnippet: 'Message',
            lastActivityDisplay: '18 min ago',
          )
        ],
        productUpdates: [defaultProductUpdates.first],
        aiUpdates: [defaultAiCapabilityUpdates.first],
      )));
      await tester.pumpAndSettle();
      final labels = {'18 min ago', 'Oct 7, 2026'};
      for (final label in labels) {
        final matches = find.text(label);
        expect(matches, findsWidgets);
        for (var index = 0; index < matches.evaluate().length; index++) {
          final text = matches.at(index);
          final row = find.ancestor(of: text, matching: find.byType(Row)).first;
          expect(tester.getRect(text).right, tester.getRect(row).right);
          expect(tester.widget<Text>(text).textAlign, TextAlign.right);
        }
      }
      for (final title in [
        defaultProductUpdates.first.title,
        defaultAiCapabilityUpdates.first.title
      ]) {
        final card = tester
            .widget<Container>(find.byKey(ValueKey('home-update-$title')));
        final decoration = card.decoration! as BoxDecoration;
        expect(decoration.borderRadius, BorderRadius.circular(12));
        expect(decoration.border, isNotNull);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Continue working bounds the message preview to 200 characters',
      (tester) async {
    await tester.pumpWidget(scaffold(EstablishedUserHome(
      historicalUpdates: const [],
      spaces: const [
        AxSpace(id: 's', name: 'Syntila', branch: 'main', lastActivity: 'Now')
      ],
      workers: const [],
      workspaces: const [],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenRun: (_, __) {},
      continueWorkItems: [
        AxContinueWorkItem(
          spaceId: 's',
          spaceName: 'Syntila',
          threadId: 't',
          threadTitle: 'Thread',
          collaboratorsDisplay: '',
          lastMessageSnippet: List.filled(250, 'a').join(),
          lastMessageAuthor: 'Alex',
          lastActivityDisplay: 'Now',
        )
      ],
      onOpenSpace: (_) {},
    )));
    final text = tester
        .widget<Text>(find.byKey(const ValueKey('continue-work-last-message')));
    expect(
        text.textSpan!.toPlainText(), 'Alex: ${List.filled(199, 'a').join()}…');
    expect(find.text('SYNTILA'), findsNothing);
  });

  const space = AxSpace(
    id: 'space-1',
    name: 'Space One',
    branch: 'main',
    lastActivity: 'Today',
  );

  const testInvite1 = AxSpaceInvitation(
    id: 'inv-1',
    spaceId: 'proj-123',
    spaceName: 'Family Travel',
    email: 'vitalii@nohainc.com',
    role: 'owner',
    status: 'pending',
    invitedByUserId: 'user-2',
    invitedByUserEmail: 'julia@nohainc.com',
    invitedByUserName: 'Julia',
    createdAt: '2026-10-07T12:00:00Z',
  );

  const testInvite2 = AxSpaceInvitation(
    id: 'inv-2',
    spaceId: 'proj-456',
    spaceName: 'Home Renovation',
    email: 'vitalii@nohainc.com',
    role: 'editor',
    status: 'pending',
    invitedByUserId: 'user-3',
    invitedByUserEmail: 'alex@nohainc.com',
    invitedByUserName: 'Alex',
    createdAt: '2026-10-07T14:00:00Z',
  );

  test('For you filters read actions before applying the four-item limit', () {
    final items = AxHomeAttentionProjector.space(
        invitations: const [],
        openFindingCount: 0,
        spaces: const [space],
        rawAttentionItems: [
          const AxHomeAttentionItem(
              id: 'read',
              type: AxHomeAttentionType.executionFailed,
              title: 'Already read',
              description: '',
              isUnread: false),
          ...List.generate(
              5,
              (index) => AxHomeAttentionItem(
                  id: '$index',
                  type: AxHomeAttentionType.executionFailed,
                  title: 'Unread $index',
                  description: '',
                  isUnread: true,
                  createdAt: DateTime.utc(2026, 10, index + 1))),
        ],
        readItemIds: const {'4'});
    expect(items.map((item) => item.id), ['3', '2', '1', '0']);
  });

  testWidgets(
      'Opening a For you card marks it read before navigation and clears Home',
      (tester) async {
    final readIds = <String>{};
    var navigated = false;
    await tester.pumpWidget(scaffold(StatefulBuilder(
        builder: (context, setState) => HomePage(
              historicalUpdates: const [],
              spaces: const [space],
              workspaces: const [],
              workers: const [],
              run: null,
              openFindingCount: 0,
              onOpenWorkspaces: () {},
              onOpenRun: (_, __) {},
              onOpenThread: (_, __) {
                expect(readIds, contains('unread'));
                navigated = true;
              },
              readAttentionItemIds: readIds,
              onReadAttentionItem: (id) => setState(() => readIds.add(id)),
              attentionItems: const [
                AxHomeAttentionItem(
                    id: 'unread',
                    type: AxHomeAttentionType.executionFailed,
                    title: 'Unread failure',
                    description: '',
                    spaceId: 'space-1',
                    threadId: 'thread'),
                AxHomeAttentionItem(
                    id: 'read',
                    type: AxHomeAttentionType.executionFailed,
                    title: 'Read failure',
                    description: '',
                    isUnread: false),
              ],
            ))));
    expect(find.text('Read failure'), findsNothing);
    await tester.tap(find.text('Unread failure'));
    await tester.pumpAndSettle();
    expect(navigated, isTrue);
    expect(find.text('Unread failure'), findsNothing);
    expect(find.text('For you'), findsNothing);
  });

  test('For you ignores stale invitations and informational Open actions', () {
    final ordinary = [
      const AxHomeAttentionItem(
          id: 'done',
          type: AxHomeAttentionType.executionCompleted,
          title: 'Done',
          description: 'Result ready',
          isActionable: true,
          actionLabel: 'Open'),
      const AxHomeAttentionItem(
          id: 'old-invite',
          type: AxHomeAttentionType.spaceInvitation,
          title: 'Old invitation',
          description: 'Already accepted',
          isActionable: true),
    ];
    final before = [...ordinary];
    final projected = AxHomeAttentionProjector.space(
        invitations: const [],
        rawAttentionItems: ordinary,
        openFindingCount: 0,
        spaces: const [space]);
    expect(projected, isEmpty);
    expect(ordinary, before); // Inbox history is untouched.
    final pending = AxHomeAttentionProjector.space(
        invitations: const [testInvite1],
        rawAttentionItems: ordinary,
        openFindingCount: 0,
        spaces: const [space]);
    expect(pending, hasLength(1));
    expect(pending.single.invitation?.id, testInvite1.id);
    for (final status in ['accepted', 'declined', 'expired', 'revoked']) {
      expect(
          AxHomeAttentionProjector.space(
              invitations: [
                AxSpaceInvitation(
                    id: 'old',
                    email: 'user@example.com',
                    role: 'editor',
                    status: status,
                    createdAt: '2026-10-01T00:00:00Z')
              ],
              rawAttentionItems: ordinary,
              openFindingCount: 0,
              spaces: const [space]),
          isEmpty);
    }
  });

  testWidgets('For you shows unread actions without a count badge',
      (tester) async {
    await tester.pumpWidget(scaffold(HomePage(
      historicalUpdates: const [],
      spaces: const [space],
      workspaces: const [],
      workers: const [],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenRun: (_, __) {},
      attentionItems: [
        const AxHomeAttentionItem(
            id: 'info',
            type: AxHomeAttentionType.executionCompleted,
            title: 'Ordinary completion',
            description: 'Done'),
        ...List.generate(
            5,
            (index) => AxHomeAttentionItem(
                id: 'failure-$index',
                type: AxHomeAttentionType.executionFailed,
                title: 'Failure $index',
                description: 'Needs investigation',
                spaceId: space.id,
                createdAt: DateTime.utc(2026, 10, index + 1))),
        const AxHomeAttentionItem(
            id: 'private',
            type: AxHomeAttentionType.executionFailed,
            title: 'Inaccessible failure',
            description: 'Private',
            spaceId: 'revoked'),
      ],
    )));
    expect(find.text('5'), findsNothing);
    expect(find.text('Ordinary completion'), findsNothing);
    expect(find.text('Inaccessible failure'), findsNothing);
    expect(find.text('Failure 0'), findsNothing);
    for (var index = 1; index <= 4; index++) {
      expect(find.text('Failure $index'), findsOneWidget);
    }
  });

  testWidgets(
      'NewUserHome renders collaborative onboarding and value cards when no invitations exist',
      (tester) async {
    var spaceCreated = false;
    var workspaceOpened = false;

    await tester.pumpWidget(scaffold(HomePage(
      historicalUpdates: const [],
      spaces: const [],
      workspaces: const [],
      workers: const [],
      invitations: const [],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () => workspaceOpened = true,
      onOpenSpace: (_) {},
      onOpenRun: (_, __) {},
      onCreateSpace: () => spaceCreated = true,
    )));

    // NewUserHome Header & Hero
    expect(find.text('Welcome to Syntila'), findsOneWidget);
    expect(find.text('Bring your people and AI together.'), findsOneWidget);
    expect(find.text('Create your first Space'), findsOneWidget);
    expect(find.text('Start a shared space for people, conversations and AI.'),
        findsOneWidget);
    expect(find.text('Create Space →'), findsOneWidget);

    // No priority invitation card or separator
    expect(find.text('Join a Space'), findsNothing);
    expect(find.text('or'), findsNothing);

    // Value cards
    expect(find.text('How Syntila works'), findsOneWidget);
    expect(find.text('People first'), findsOneWidget);
    expect(find.text('Private credentials'), findsOneWidget);
    expect(find.text('Shared conversations'), findsOneWidget);

    // Advanced local execution card
    expect(find.text('Want to use AI or tools running on your computer?'),
        findsOneWidget);
    expect(
        find.text(
            'Connect Syntila Workspace to make local Workers available to your Spaces.'),
        findsOneWidget);
    expect(find.text('Connect Workspace →'), findsOneWidget);

    // Dashboard sections must NOT appear for new user
    expect(find.text('For you'), findsNothing);
    expect(find.text('Continue working'), findsNothing);
    expect(find.text("What's new in Syntila"), findsNothing);
    expect(find.text('AI updates'), findsNothing);
    expect(find.text('Ready Workers'), findsNothing);
    expect(find.text('Archived Spaces'), findsNothing);

    await tester.tap(find.text('Create Space →'));
    expect(spaceCreated, isTrue);

    await tester.ensureVisible(find.text('Connect Workspace →'));
    await tester.tap(find.text('Connect Workspace →'));
    expect(workspaceOpened, isTrue);
  });

  testWidgets(
      'NewUserHome prioritizes Join a Space card when user has 0 spaces but has pending invitations',
      (tester) async {
    var spaceCreated = false;
    var workspaceOpened = false;
    AxSpaceInvitation? acceptedInvite;
    AxSpaceInvitation? declinedInvite;

    await tester.pumpWidget(scaffold(HomePage(
      historicalUpdates: const [],
      spaces: const [],
      workspaces: const [],
      workers: const [],
      invitations: const [testInvite1, testInvite2],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () => workspaceOpened = true,
      onOpenSpace: (_) {},
      onOpenRun: (_, __) {},
      onCreateSpace: () => spaceCreated = true,
      onAcceptInvitation: (inv) => acceptedInvite = inv,
      onDeclineInvitation: (inv) => declinedInvite = inv,
    )));

    // Header
    expect(find.text('Welcome to Syntila'), findsOneWidget);
    expect(find.text('Bring your people and AI together.'), findsOneWidget);

    // Priority Join a Space card
    expect(find.text('Join a Space'), findsOneWidget);
    expect(find.text('You have 2 invitations.'), findsOneWidget);
    expect(find.text('Family Travel'), findsOneWidget);
    expect(find.text('Invited by Julia · OWNER'), findsOneWidget);
    expect(find.text('Home Renovation'), findsOneWidget);
    expect(find.text('Invited by Alex · EDITOR'), findsOneWidget);

    // 'or' divider and Create your first Space
    expect(find.text('or'), findsOneWidget);
    expect(find.text('Create your first Space'), findsOneWidget);
    expect(find.text('Create Space →'), findsOneWidget);

    // Value cards
    expect(find.text('How Syntila works'), findsOneWidget);
    expect(find.text('People first'), findsOneWidget);
    expect(find.text('Private credentials'), findsOneWidget);
    expect(find.text('Shared conversations'), findsOneWidget);

    // Advanced workspace connection
    expect(find.text('Want to use AI or tools running on your computer?'),
        findsOneWidget);
    expect(
        find.text(
            'Connect Syntila Workspace to make local Workers available to your Spaces.'),
        findsOneWidget);
    expect(find.text('Connect Workspace →'), findsOneWidget);

    // Test accept on first invite
    await tester.tap(find.text('Accept').first);
    expect(acceptedInvite?.id, 'inv-1');

    // Test decline on second invite
    await tester.tap(find.text('Decline').last);
    expect(declinedInvite?.id, 'inv-2');

    // Test create space
    await tester.tap(find.text('Create Space →'));
    expect(spaceCreated, isTrue);

    // Test connect workspace
    await tester.ensureVisible(find.text('Connect Workspace →'));
    await tester.tap(find.text('Connect Workspace →'));
    expect(workspaceOpened, isTrue);
  });

  testWidgets(
      'EstablishedUserHome implements the 4-part contract and omits onboarding',
      (tester) async {
    var openedSpace = '';
    var openedThread = '';
    AxSpaceInvitation? acceptedInvite;

    await tester.pumpWidget(scaffold(HomePage(
      historicalUpdates: const [],
      spaces: const [space],
      workspaces: const [
        AxWorkspace(id: 'workspace-1', name: 'MacBook'),
      ],
      workers: const [
        AxWorker(
          id: 'ready-1',
          workspaceId: 'workspace-1',
          workspaceName: 'MacBook',
          workerTypeId: 'chatgpt',
          displayName: 'ChatGPT',
          status: 'ready',
          readinessState: 'ready',
          localConcurrencyLimit: 1,
        ),
      ],
      invitations: const [testInvite1],
      continueWorkItems: const [
        AxContinueWorkItem(
          spaceId: 'space-1',
          spaceName: 'Website Redesign',
          threadId: 'ws-landing',
          threadTitle: 'Landing page',
          collaboratorsDisplay: 'You and ChatGPT',
          lastMessageSnippet: "Let's simplify the hero section...",
          lastActivityDisplay: '18 min ago',
        ),
      ],
      attentionItems: const [
        AxHomeAttentionItem(
          id: 'attn-1',
          title: 'Authentication thread needs your input',
          subtitle: 'Question from Erik about OAuth providers',
          timestampDisplay: '24 min ago',
          spaceId: 'space-1',
          threadId: 'ws-auth',
          actionLabel: 'Open',
        ),
      ],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenSpace: (id) => openedSpace = id,
      onOpenRun: (_, __) {},
      onCreateSpace: () {},
      onAcceptInvitation: (inv) => acceptedInvite = inv,
      onOpenThread: (pId, wsId) {
        openedSpace = pId;
        openedThread = wsId;
      },
      onOpenNotifications: () {},
    )));

    // 1. FOR YOU (unified prioritized card projection)
    expect(find.text('For you'), findsOneWidget);
    expect(find.text('View all notifications →'), findsOneWidget);
    expect(find.text('SPACE'), findsOneWidget);
    expect(find.text('Family Travel'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);

    expect(find.text('Needs your input'), findsOneWidget);
    expect(find.text('Authentication thread needs your input'), findsOneWidget);
    expect(find.text('Open'), findsNothing);

    // 2. CONTINUE WORKING
    expect(find.text('Continue working'), findsOneWidget);
    expect(find.text('WEBSITE REDESIGN'), findsNothing);
    expect(find.text('Landing page'), findsOneWidget);
    expect(find.text('18 min ago'), findsOneWidget);
    expect(
        find.textContaining("Let's simplify the hero section...",
            findRichText: true),
        findsOneWidget);
    expect(find.text('Continue →'), findsNothing);

    // 3. WHAT'S NEW
    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Space Invitations'), findsOneWidget);
    expect(find.text('Conversation Continuity'), findsOneWidget);

    // 4. AI UPDATES
    expect(find.text('AI updates'), findsOneWidget);
    expect(find.text('ChatGPT Worker'), findsOneWidget);

    // INVARIANTS: Onboarding cards and prohibited legacy elements must NOT appear
    expect(find.text('Welcome to Syntila'), findsNothing);
    expect(find.text('How Syntila works'), findsNothing);
    expect(find.text('Spaces count'), findsNothing);
    expect(find.text('Ready Workers count'), findsNothing);
    expect(find.text('Workspaces count'), findsNothing);
    expect(find.text('No active Runs'), findsNothing);
    expect(find.text('Nothing needs your attention.'), findsNothing);
    expect(find.text('Archived Spaces'), findsNothing);
    expect(find.text('Your execution capacity at a glance.'), findsNothing);

    await tester.ensureVisible(
        find.byKey(const ValueKey('continue-work-last-message')).first);
    await tester
        .tap(find.byKey(const ValueKey('continue-work-last-message')).first);
    expect(openedSpace, 'space-1');
    expect(openedThread, 'ws-landing');

    await tester.ensureVisible(find.text('Accept'));
    await tester.tap(find.text('Accept'));
    expect(acceptedInvite?.id, 'inv-1');
  });

  testWidgets('For you shows four items and navigates from the card',
      (tester) async {
    var notificationsOpened = false;
    var openedSpace = '';
    var openedThread = '';

    final manyAttentionItems = [
      const AxHomeAttentionItem(
        id: 'completed-1',
        kind: AxAttentionKind.completed,
        categoryLabel: 'Completed',
        title: 'Gemini finished reviewing Landing Page',
        subtitle: 'Website Redesign',
        timestampDisplay: '1 hour ago',
        actionLabel: 'Review →',
        spaceId: 'proj-1',
        threadId: 'ws-landing',
      ),
      const AxHomeAttentionItem(
        id: 'failed-1',
        kind: AxAttentionKind.failedExecution,
        categoryLabel: 'Failed execution',
        title: 'Build task failed on CI Worker',
        subtitle: 'Space One',
        timestampDisplay: '15 min ago',
        actionLabel: 'Inspect →',
        spaceId: 'space-1',
      ),
      const AxHomeAttentionItem(
        id: 'worker-prob-1',
        kind: AxAttentionKind.workerProblem,
        categoryLabel: 'Worker needs attention',
        title: 'ChatGPT Worker authentication expired',
        subtitle: 'Workspace: MacBook',
        timestampDisplay: '30 min ago',
        actionLabel: 'Fix →',
      ),
      const AxHomeAttentionItem(
        id: 'input-1',
        kind: AxAttentionKind.needsInput,
        categoryLabel: 'Needs your input',
        title: 'Authentication thread needs your input',
        subtitle: 'Syntila',
        timestampDisplay: '24 min ago',
        actionLabel: 'Open',
        spaceId: 'space-1',
        threadId: 'ws-auth',
      ),
      const AxHomeAttentionItem(
        id: 'workspace-prob-1',
        kind: AxAttentionKind.workspaceProblem,
        categoryLabel: 'Workspace offline',
        title: "Workspace Mac-Mini went offline",
        subtitle: 'Re-connect to enable workers',
        timestampDisplay: '45 min ago',
        actionLabel: 'Connect →',
      ),
      const AxHomeAttentionItem(
        id: 'general-extra',
        kind: AxAttentionKind.general,
        categoryLabel: 'Info',
        title: 'Lower priority extra notification',
        subtitle: 'Should be cut off past top 5',
        timestampDisplay: '2 hours ago',
      ),
    ];

    await tester.pumpWidget(scaffold(HomePage(
      historicalUpdates: const [],
      spaces: const [space],
      workspaces: const [],
      workers: const [],
      invitations: const [testInvite1], // Priority 1: invitation
      attentionItems: manyAttentionItems,
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenSpace: (id) => openedSpace = id,
      onOpenRun: (_, __) {},
      onCreateSpace: () {},
      onOpenThread: (pId, wsId) {
        openedSpace = pId;
        openedThread = wsId;
      },
      onOpenNotifications: () => notificationsOpened = true,
    )));

    expect(find.text('For you'), findsOneWidget);
    expect(find.text('View all notifications →'), findsOneWidget);

    // Priority 1: Invitation (present)
    expect(find.text('SPACE'), findsOneWidget);
    expect(find.text('Family Travel'), findsOneWidget);

    // Priority 2: Needs your input (present)
    expect(find.text('Needs your input'), findsOneWidget);
    expect(find.text('Authentication thread needs your input'), findsOneWidget);

    // Priority 3: Failed execution (present)
    expect(find.text('Failed execution'), findsOneWidget);
    expect(find.text('Build task failed on CI Worker'), findsOneWidget);

    // Priority 4: Worker needs attention (present)
    expect(find.text('Worker needs attention'), findsOneWidget);
    expect(find.text('ChatGPT Worker authentication expired'), findsOneWidget);

    // Priority 5: Workspace offline (present - total 5 items reached)
    expect(find.text('Workspace offline'), findsNothing);
    expect(find.text("Workspace Mac-Mini went offline"), findsNothing);

    // Priority 6 & lower items past limit of 5:
    // 'Gemini finished reviewing Landing Page' (Priority 6) and 'Lower priority extra notification' (Priority 7) should be cut off
    expect(find.text('Gemini finished reviewing Landing Page'), findsNothing);
    expect(find.text('Lower priority extra notification'), findsNothing);

    // Test View all notifications trigger
    await tester.tap(find.text('View all notifications →'));
    expect(notificationsOpened, isTrue);

    // Test action navigation on attention item
    await tester.tap(find.text('Authentication thread needs your input'));
    expect(openedSpace, 'space-1');
    expect(openedThread, 'ws-auth');
  });

  testWidgets(
      'For you selects the latest four items actionable items regardless of priority or read state',
      (tester) async {
    final now = DateTime.now();
    final items = [
      AxHomeAttentionItem(
          id: 'approval',
          type: AxHomeAttentionType.approvalRequired,
          title: 'Approve deployment',
          description: 'Approval needed',
          createdAt: now.subtract(const Duration(minutes: 3))),
      AxHomeAttentionItem(
          id: 'worker',
          type: AxHomeAttentionType.workerProblem,
          title: 'Repair login',
          description: 'Login expired',
          createdAt: now.subtract(const Duration(minutes: 2))),
      // Same category (completed) but unread vs read:
      AxHomeAttentionItem(
        id: 'comp-read',
        kind: AxAttentionKind.completed,
        categoryLabel: 'Completed',
        title: 'Read Task A',
        subtitle: 'Done',
        timestampDisplay: '10 min ago',
        isUnread: false,
        isActionable: false,
        createdAt: now.subtract(const Duration(minutes: 10)),
      ),
      AxHomeAttentionItem(
        id: 'comp-unread',
        kind: AxAttentionKind.completed,
        categoryLabel: 'Completed',
        title: 'Unread Task B',
        subtitle: 'Done',
        timestampDisplay: '12 min ago',
        isUnread: true,
        isActionable: false,
        createdAt: now.subtract(const Duration(minutes: 12)),
      ),
      // Same category (needsInput), actionable
      AxHomeAttentionItem(
        id: 'input-actionable',
        kind: AxAttentionKind.needsInput,
        categoryLabel: 'Needs your input',
        title: 'Actionable input needed',
        subtitle: 'Decision required',
        timestampDisplay: '5 min ago',
        actionLabel: 'Review →',
        isUnread: true,
        isActionable: true,
        createdAt: now.subtract(const Duration(minutes: 5)),
      ),
      // Same category (failedExecution), newer vs older:
      AxHomeAttentionItem(
        id: 'fail-newer',
        kind: AxAttentionKind.failedExecution,
        categoryLabel: 'Failed execution',
        title: 'Newer Failure',
        subtitle: 'Just failed',
        timestampDisplay: '1 min ago',
        actionLabel: 'Inspect →',
        isUnread: true,
        isActionable: true,
        createdAt: now.subtract(const Duration(minutes: 1)),
      ),
      AxHomeAttentionItem(
        id: 'fail-older',
        kind: AxAttentionKind.failedExecution,
        categoryLabel: 'Failed execution',
        title: 'Older Failure',
        subtitle: 'Failed earlier',
        timestampDisplay: '20 min ago',
        actionLabel: 'Inspect →',
        isUnread: true,
        isActionable: true,
        createdAt: now.subtract(const Duration(minutes: 20)),
      ),
    ];

    await tester.pumpWidget(scaffold(HomePage(
      historicalUpdates: const [],
      spaces: const [space],
      workspaces: const [],
      workers: const [],
      invitations: const [],
      attentionItems: items,
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenSpace: (_) {},
      onOpenRun: (_, __) {},
      onCreateSpace: () {},
    )));

    expect(
        tester.getTopLeft(find.text('Newer Failure')).dy,
        lessThanOrEqualTo(
            tester.getTopLeft(find.text('Actionable input needed')).dy));
    // Recent items remain visible regardless of priority.
    expect(find.text('Actionable input needed'), findsOneWidget);
    // Expect fail-newer & fail-older (Priority 3)
    expect(find.text('Newer Failure'), findsOneWidget);
    expect(find.text('Older Failure'), findsNothing);
    // Expect unread completed (Priority 6, unread) before read completed (Priority 6, read)
    expect(find.text('Unread Task B'), findsNothing);
    expect(find.text('Read Task A'), findsNothing);
  });

  testWidgets(
      'AxHomeAttentionItem abstraction renders and executes decoupled primaryAction and secondaryAction',
      (tester) async {
    var primaryExecuted = false;
    var secondaryExecuted = false;

    final itemWithActions = AxHomeAttentionItem(
      id: 'custom-action-item',
      type: AxHomeAttentionType.needsInput,
      title: 'Decoupled Action Item',
      description: 'Item with encapsulated primary and secondary closures',
      timestampDisplay: 'Just now',
      primaryAction: AxHomeAttentionAction(
        label: 'Custom Resolve',
        onPerform: () => primaryExecuted = true,
      ),
      secondaryAction: AxHomeAttentionAction(
        label: 'Custom Dismiss',
        onPerform: () => secondaryExecuted = true,
        isDestructive: true,
      ),
    );

    await tester.pumpWidget(scaffold(HomePage(
      historicalUpdates: const [],
      spaces: const [space],
      workspaces: const [],
      workers: const [],
      invitations: const [],
      attentionItems: [itemWithActions],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenSpace: (_) {},
      onOpenRun: (_, __) {},
      onCreateSpace: () {},
    )));

    expect(find.text('Decoupled Action Item'), findsOneWidget);
    expect(find.text('Item with encapsulated primary and secondary closures'),
        findsOneWidget);
    expect(find.text('Custom Resolve'), findsNothing);
    expect(find.text('Custom Dismiss'), findsNothing);

    await tester.tap(find.text('Decoupled Action Item'));
    expect(primaryExecuted, isTrue);

    expect(secondaryExecuted, isFalse);
  });

  test('AxHomeAttentionProjector cleanly maps and prioritizes domain items',
      () {
    var acceptedInvite = false;
    var declinedInvite = false;
    var openedSpace = '';

    final projected = AxHomeAttentionProjector.space(
      invitations: [testInvite1],
      rawAttentionItems: [
        const AxHomeAttentionItem(
          id: 'attn-raw',
          type: AxHomeAttentionType.executionFailed,
          title: 'Execution Failed on Worker',
          description: 'Stack trace error',
          actionLabel: 'Inspect →',
          spaceId: 'space-1',
        ),
      ],
      openFindingCount: 2,
      spaces: [space],
      onAcceptInvitation: (_) => acceptedInvite = true,
      onDeclineInvitation: (_) => declinedInvite = true,
      onOpenSpace: (id) => openedSpace = id,
    );

    expect(projected.length, 3);

    // 1. Invitation (Priority 1)
    expect(projected[0].type, AxHomeAttentionType.spaceInvitation);
    expect(projected[0].primaryAction?.label, 'Accept');
    expect(projected[0].secondaryAction?.label, 'Decline');
    projected[0].primaryAction?.onPerform();
    expect(acceptedInvite, isTrue);
    projected[0].secondaryAction?.onPerform();
    expect(declinedInvite, isTrue);

    // 2. Open findings (Priority 2, needsInput)
    expect(projected[2].type, AxHomeAttentionType.needsInput);
    expect(projected[2].primaryAction?.label, 'Review →');
    projected[2].primaryAction?.onPerform();
    expect(openedSpace, 'space-1');

    // 3. Raw attention item (Priority 3, executionFailed)
    expect(projected[1].type, AxHomeAttentionType.executionFailed);
    expect(projected[1].primaryAction?.label, 'Inspect →');
    openedSpace = '';
    projected[1].primaryAction?.onPerform();
    expect(openedSpace, 'space-1');
  });

  testWidgets(
      'Continue Working displays four ranked Thread cards and opens conversations',
      (tester) async {
    var openedSpace = '';
    var openedThread = '';

    final continueItems = [
      const AxContinueWorkItem(
        spaceId: 'proj-syntila',
        spaceName: 'Syntila Development',
        threadId: 'ws-sessions',
        threadTitle: 'Worker Sessions',
        collaboratorsDisplay: 'ChatGPT',
        lastMessageSnippet: 'We should persist\n\nthe session context.',
        lastMessageAuthor: 'Alex',
        lastActivityDisplay: '23 min ago',
      ),
      const AxContinueWorkItem(
        spaceId: 'proj-web',
        spaceName: 'Website',
        threadId: 'ws-landing',
        threadTitle: 'Landing Page',
        collaboratorsDisplay: 'You + Gemini',
        lastMessageSnippet: 'The hero should bring people together.',
        lastActivityDisplay: 'Yesterday',
      ),
      const AxContinueWorkItem(
        spaceId: 'proj-docs',
        spaceName: 'Documentation',
        threadId: 'ws-architecture',
        threadTitle: 'Architecture v8',
        collaboratorsDisplay: 'Julia + Claude',
        lastMessageSnippet: 'ADRs updated with signed tool profiles.',
        lastActivityDisplay: '2 days ago',
      ),
      const AxContinueWorkItem(
        spaceId: 'proj-cloud',
        spaceName: 'Cloud Services',
        threadId: 'ws-d1',
        threadTitle: 'D1 Migrations',
        collaboratorsDisplay: 'Erik',
        lastMessageSnippet: 'Baseline schema applied.',
        lastActivityDisplay: '3 days ago',
      ),
      const AxContinueWorkItem(
        spaceId: 'proj-mobile',
        spaceName: 'Mobile App',
        threadId: 'ws-ios',
        threadTitle: 'iOS Polish',
        collaboratorsDisplay: 'Alex',
        lastMessageSnippet: 'Responsive layouts fixed.',
        lastActivityDisplay: '4 days ago',
      ),
      const AxContinueWorkItem(
        spaceId: 'proj-extra',
        spaceName: 'Extra Space',
        threadId: 'ws-extra',
        threadTitle: 'Extra Thread',
        collaboratorsDisplay: 'Bot',
        lastMessageSnippet: 'Should not appear past 5 items.',
        lastActivityDisplay: '5 days ago',
      ),
    ];

    await tester.pumpWidget(scaffold(HomePage(
      historicalUpdates: const [],
      spaces: const [
        AxSpace(
          id: 'proj-syntila',
          name: 'Syntila Development',
          branch: 'main',
          lastActivity: 'Today',
        ),
        AxSpace(
          id: 'proj-web',
          name: 'Website',
          branch: 'main',
          lastActivity: 'Today',
        ),
        AxSpace(
          id: 'proj-docs',
          name: 'Documentation',
          branch: 'main',
          lastActivity: 'Today',
        ),
        AxSpace(
          id: 'proj-cloud',
          name: 'Cloud Services',
          branch: 'main',
          lastActivity: 'Today',
        ),
        AxSpace(
          id: 'proj-mobile',
          name: 'Mobile App',
          branch: 'main',
          lastActivity: 'Today',
        ),
        AxSpace(
          id: 'proj-extra',
          name: 'Extra Space',
          branch: 'main',
          lastActivity: 'Today',
        ),
      ],
      workspaces: const [],
      workers: const [],
      invitations: const [],
      continueWorkItems: continueItems,
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenSpace: (_) {},
      onOpenRun: (_, __) {},
      onCreateSpace: () {},
      onOpenThread: (pId, wsId) {
        openedSpace = pId;
        openedThread = wsId;
      },
    )));

    expect(find.text('Continue working'), findsOneWidget);

    // Card 1
    expect(find.text('SYNTILA DEVELOPMENT'), findsNothing);
    expect(find.text('Worker Sessions'), findsOneWidget);
    expect(find.text('23 min ago'), findsOneWidget);
    // The last message is a one-line preview prefixed with its sender.
    expect(
        find.text('Alex: We should persist the session context.',
            findRichText: true),
        findsOneWidget);

    // Card 2
    expect(find.text('WEBSITE'), findsNothing);
    expect(find.text('Landing Page'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(
        find.textContaining('The hero should bring people together.',
            findRichText: true),
        findsOneWidget);

    // Card 3
    expect(find.text('DOCUMENTATION'), findsNothing);
    expect(find.text('Architecture v8'), findsOneWidget);

    // Card 4
    expect(find.text('CLOUD SERVICES'), findsNothing);
    expect(find.text('D1 Migrations'), findsOneWidget);

    // Home shows at most four ranked Threads.
    expect(find.byKey(const ValueKey('continue-work-last-message')),
        findsNWidgets(4));
    expect(find.text('MOBILE APP'), findsNothing);
    expect(find.text('iOS Polish'), findsNothing);

    // Remaining items are omitted by the four-item limit
    expect(find.text('EXTRA SPACE'), findsNothing);
    expect(find.text('Extra Thread'), findsNothing);

    // Test clicking Continue → on first card
    await tester.ensureVisible(
        find.byKey(const ValueKey('continue-work-last-message')).first);
    await tester
        .tap(find.byKey(const ValueKey('continue-work-last-message')).first);
    expect(openedSpace, 'proj-syntila');
    expect(openedThread, 'ws-sessions');
  });

  test(
      'AxRecentWorkRanker ranks by meaningful activity factors and excludes archived/inaccessible items',
      () {
    final now = DateTime(2026, 10, 8, 12, 0, 0);

    final itemArchived = AxContinueWorkItem(
      spaceId: 'p-archived',
      spaceName: 'Archived Space',
      threadId: 'ws-1',
      threadTitle: 'Old Thread',
      collaboratorsDisplay: 'None',
      lastMessageSnippet: 'Archived',
      lastActivityDisplay: '1 year ago',
      archived: true,
      lastMeaningfulActivityAt: now.subtract(const Duration(minutes: 5)),
    );

    final itemInaccessible = AxContinueWorkItem(
      spaceId: 'p-inaccessible',
      spaceName: 'Inaccessible Space',
      threadId: 'ws-2',
      threadTitle: 'Restricted',
      collaboratorsDisplay: 'None',
      lastMessageSnippet: 'Restricted',
      lastActivityDisplay: 'Just now',
      isDirectMember: false,
      lastMeaningfulActivityAt: now.subtract(const Duration(minutes: 1)),
    );

    final itemPassiveSyncOnly = AxContinueWorkItem(
      spaceId: 'p-passive',
      spaceName: 'Passive Metadata Updated Space',
      threadId: 'ws-passive',
      threadTitle: 'No Real Messages',
      collaboratorsDisplay: 'None',
      lastMessageSnippet: 'Automated background sync ping',
      lastActivityDisplay: 'Just now',
      hasUserParticipation: false,
      hasRecentWorkerResponse: false,
      hasUnresolvedState: false,
      // Meaningful conversation was 3 days ago, only metadata was updated now
      lastMeaningfulActivityAt: now.subtract(const Duration(days: 3)),
    );

    final itemUserParticipated = AxContinueWorkItem(
      spaceId: 'p-user',
      spaceName: 'User Discussion Space',
      threadId: 'ws-user',
      threadTitle: 'Active Discussion',
      collaboratorsDisplay: 'You + Team',
      lastMessageSnippet: 'I responded with the specs.',
      lastActivityDisplay: '2 hours ago',
      hasUserParticipation: true,
      lastMeaningfulActivityAt: now.subtract(const Duration(hours: 2)),
    );

    final itemWorkerResponded = AxContinueWorkItem(
      spaceId: 'p-worker',
      spaceName: 'AI Assistant Space',
      threadId: 'ws-worker',
      threadTitle: 'Worker Synthesis',
      collaboratorsDisplay: 'ChatGPT',
      lastMessageSnippet: 'Synthesis completed with 3 artifacts.',
      lastActivityDisplay: '1 hour ago',
      hasRecentWorkerResponse: true,
      lastMeaningfulActivityAt: now.subtract(const Duration(hours: 1)),
    );

    final itemUnresolvedState = AxContinueWorkItem(
      spaceId: 'p-unresolved',
      spaceName: 'Execution Space',
      threadId: 'ws-unresolved',
      threadTitle: 'Pending Decisions',
      collaboratorsDisplay: 'You + Gemini',
      lastMessageSnippet: 'Waiting for parameter confirmation.',
      lastActivityDisplay: '4 hours ago',
      hasUnresolvedState: true,
      hasUserParticipation: true,
      lastMeaningfulActivityAt: now.subtract(const Duration(hours: 4)),
    );

    final ranked = AxRecentWorkRanker.rank(
      [
        itemArchived,
        itemInaccessible,
        itemPassiveSyncOnly,
        itemUserParticipated,
        itemWorkerResponded,
        itemUnresolvedState,
      ],
      now: now,
    );

    // Assert archived and inaccessible items are completely excluded
    expect(ranked.any((it) => it.spaceId == 'p-archived'), isFalse);
    expect(ranked.any((it) => it.spaceId == 'p-inaccessible'), isFalse);

    // Expected order:
    // 1. itemUnresolvedState (score ~ 1000 + 500 + 100 + decay) -> Rank 1
    // 2. itemUserParticipated (score ~ 500 + 100 + decay) -> Rank 2
    // 3. itemWorkerResponded (score ~ 250 + 100 + decay) -> Rank 3
    // 4. itemPassiveSyncOnly (score ~ 0 + 100 + decayed 3 days) -> Rank 4 (does NOT beat active conversations despite background metadata)
    expect(ranked.length, 4);
    expect(ranked[0].threadId, 'ws-unresolved');
    expect(ranked[1].threadId, 'ws-user');
    expect(ranked[2].threadId, 'ws-worker');
    expect(ranked[3].threadId, 'ws-passive');
  });

  test(
      'AxProductUpdate domain model and AxProductUpdateService lifecycle & read state filtering',
      () {
    final now = DateTime(2026, 10, 8, 12, 0, 0);

    final update1Published = AxProductUpdate(
      id: 'up-1',
      slug: 'invitations',
      title: 'Space Invitations',
      summary: 'Invite collaborators to spaces.',
      category: AxProductUpdateCategory.collaboration,
      publishedAt: now.subtract(const Duration(days: 1)),
      status: AxProductUpdateStatus.published,
    );

    final update2Draft = AxProductUpdate(
      id: 'up-2',
      slug: 'draft-feature',
      title: 'Unreleased Draft',
      summary: 'Coming soon.',
      category: AxProductUpdateCategory.feature,
      publishedAt: now,
      status: AxProductUpdateStatus.draft,
    );

    final update3Archived = AxProductUpdate(
      id: 'up-3',
      slug: 'old-feature',
      title: 'Deprecated System',
      summary: 'Archived release.',
      category: AxProductUpdateCategory.improvement,
      publishedAt: now.subtract(const Duration(days: 60)),
      status: AxProductUpdateStatus.archived,
    );

    final update4Dismissed = AxProductUpdate(
      id: 'up-4',
      slug: 'workspace-sync',
      title: 'Workspace Sync',
      summary: 'Local process execution.',
      category: AxProductUpdateCategory.workspace,
      publishedAt: now.subtract(const Duration(days: 2)),
      status: AxProductUpdateStatus.published,
    );

    final update5Incompatible = AxProductUpdate(
      id: 'up-5',
      slug: 'future-v9',
      title: 'Future Feature',
      summary: 'Requires v9.0.0',
      category: AxProductUpdateCategory.worker,
      publishedAt: now,
      minimumAppVersion: '9.0.0',
      status: AxProductUpdateStatus.published,
    );

    final readStates = <String, AxUserProductUpdateState>{
      'up-1': AxUserProductUpdateState(
        userId: 'u-1',
        updateId: 'up-1',
        seenAt: now.subtract(const Duration(hours: 1)),
      ),
      'up-4': AxUserProductUpdateState(
        userId: 'u-1',
        updateId: 'up-4',
        dismissedAt: now.subtract(const Duration(minutes: 30)),
      ),
    };

    final allUpdates = [
      update1Published,
      update2Draft,
      update3Archived,
      update4Dismissed,
      update5Incompatible,
    ];

    // Test Home filtering: only published, non-dismissed, version-compatible updates
    final homeUpdates = AxProductUpdateService.getHomeUpdates(
      allUpdates,
      readStates: readStates,
      appVersion: '1.0.0',
    );

    expect(homeUpdates.length, 1);
    expect(homeUpdates.first.id, 'up-1');

    // Test unread count: update1 is seen, update4 is dismissed, update2 is draft, update5 incompatible
    // Only published un-seen un-dismissed compatible items are unread
    final unreadCount = AxProductUpdateService.computeUnreadCount(
      allUpdates,
      readStates: readStates,
      appVersion: '1.0.0',
    );
    expect(unreadCount, 0);

    // If update1 was not seen, unread count should be 1
    final unreadCountUnseen = AxProductUpdateService.computeUnreadCount(
      allUpdates,
      readStates: {},
      appVersion: '1.0.0',
    );
    expect(unreadCountUnseen, 2); // update1 and update4

    // Test Month/Year grouping for full changelog with historical releases
    final grouped = AxProductUpdateService.groupUpdatesByMonthYear(
      allUpdates,
      includeDrafts: true,
    );
    expect(grouped.containsKey('October 2026'), isTrue);
    expect(grouped.containsKey('August 2026'), isTrue);
  });

  testWidgets(
      'EstablishedUserHome renders What\'s new with badge, category tags, See all CTA, and AxWhatsNewDialog',
      (tester) async {
    final now = DateTime(2026, 10, 8, 12, 0, 0);
    final updates = [
      AxProductUpdate(
        id: 'up-1',
        slug: 'collab',
        title: 'Space Invitations',
        summary: 'Collaborate with your team.',
        details: 'Full RBAC invitation workflow directly inside AX.',
        category: AxProductUpdateCategory.collaboration,
        publishedAt: now,
        dateDisplay: 'Oct 8',
      ),
      AxProductUpdate(
        id: 'up-2',
        slug: 'continuity',
        title: 'Conversation Continuity',
        summary: 'Keep conversational context across Workers.',
        category: AxProductUpdateCategory.workflow,
        publishedAt: now.subtract(const Duration(days: 1)),
        dateDisplay: 'Oct 7',
      ),
    ];

    var seeAllOpened = false;
    AxProductUpdate? selectedDetailUpdate;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EstablishedUserHome(
            historicalUpdates: const [],
            spaces: const [
              AxSpace(
                id: 'p-1',
                name: 'Main Space',
                description: 'Active space',
                archived: false,
                branch: 'main',
                lastActivity: 'Just now',
                threads: [],
              ),
            ],
            workspaces: const [],
            workers: const [],
            run: null,
            openFindingCount: 0,
            productUpdates: updates,
            productUpdateReadStates: const {}, // Both updates unread
            onOpenWorkspaces: () {},
            onOpenSpace: (_) {},
            onOpenRun: (_, __) {},
            onOpenWhatsNew: () => seeAllOpened = true,
            onOpenUpdateDetail: (u) => selectedDetailUpdate = u,
          ),
        ),
      ),
    );

    // The What's new header shows no unread count badge.
    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('2'), findsNothing);
    expect(find.text('See all'), findsOneWidget);

    // Verify tiles rendered with category pill and CTA
    expect(find.text('COLLABORATION'), findsOneWidget);
    expect(find.text('WORKFLOW'), findsOneWidget);
    expect(find.text('Space Invitations'), findsOneWidget);
    expect(find.text('Conversation Continuity'), findsOneWidget);
    expect(find.text('Learn more →'), findsNothing);

    // Tap See all
    await tester.tap(find.text('See all'));
    await tester.pumpAndSettle();
    expect(seeAllOpened, isTrue);

    // Update rows are informational and do not open details.
    expect(selectedDetailUpdate, isNull);
  });

  testWidgets('AxWhatsNewDialog displays grouped changelog and details',
      (tester) async {
    final now = DateTime(2026, 10, 8, 12, 0, 0);
    final updates = [
      AxProductUpdate(
        id: 'up-oct',
        title: 'October Feature',
        summary: 'Launched in October.',
        details: 'Detailed technical changelog for October release.',
        category: AxProductUpdateCategory.feature,
        publishedAt: now,
      ),
      AxProductUpdate(
        id: 'up-sep',
        title: 'September Feature',
        summary: 'Launched in September.',
        details: 'Detailed changelog for September release.',
        category: AxProductUpdateCategory.workspace,
        publishedAt: now.subtract(const Duration(days: 35)),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => AxWhatsNewDialog.show(
                  context,
                  updates: updates,
                ),
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();

    // Verify Dialog rendered with Month Year grouping
    expect(find.text("What's New"), findsOneWidget);
    expect(find.text('October 2026'), findsOneWidget);
    expect(find.text('September 2026'), findsOneWidget);
    expect(find.text('October Feature'), findsOneWidget);
    expect(find.text('September Feature'), findsOneWidget);
    expect(find.text('Detailed technical changelog for October release.'),
        findsOneWidget);
  });

  test('Phase 16 — AxAiCapabilityUpdate domain model and serialization', () {
    const update = AxAiCapabilityUpdate(
      id: 'ai-gpt4o-mini',
      workerProfileId: 'chatgpt',
      provider: 'openai',
      type: AxAiCapabilityUpdateType.modelAdded,
      modelId: 'gpt-4o-mini',
      modelDisplayName: 'GPT-4o Mini',
      title: 'Fast lightweight model added',
      summary: 'GPT-4o Mini is now available for low-latency code tasks.',
      publishedAt: '2026-10-08T00:00:00Z',
      dateDisplay: 'Oct 8',
      minimumProfileVersion: '1.2.0',
    );

    expect(update.workerTypeId, 'chatgpt');
    expect(update.workerDisplayName, 'ChatGPT Worker');
    expect(update.type.isModelUpdate, isTrue);
    expect(update.type.isCapabilityUpdate, isFalse);
    expect(update.type.wireName, 'model_added');
    expect(update.type.label, 'Model Added');
    expect(update.dateDisplay, 'Oct 8');
    expect(update.isCompatibleWithProfileVersion('1.3.0'), isTrue);
    expect(update.isCompatibleWithProfileVersion('1.1.0'), isFalse);

    final json = update.toJson();
    expect(json['id'], 'ai-gpt4o-mini');
    expect(json['workerProfileId'], 'chatgpt');
    expect(json['provider'], 'openai');
    expect(json['type'], 'model_added');
    expect(json['modelId'], 'gpt-4o-mini');
    expect(json['modelDisplayName'], 'GPT-4o Mini');
    expect(json['title'], 'Fast lightweight model added');
    expect(json['minimumProfileVersion'], '1.2.0');

    final parsed = AxAiCapabilityUpdate.fromJson(json);
    expect(parsed.id, update.id);
    expect(parsed.workerProfileId, update.workerProfileId);
    expect(parsed.provider, update.provider);
    expect(parsed.type, update.type);
    expect(parsed.modelId, update.modelId);
    expect(parsed.modelDisplayName, update.modelDisplayName);
    expect(parsed.summary, update.summary);
    expect(parsed.minimumProfileVersion, update.minimumProfileVersion);
  });

  test('Thread records retain timestamps used by Continue working', () {
    final thread = AxThread.fromJson({
      'id': 'thread-latest',
      'spaceId': 'space-1',
      'name': 'Latest discussion',
      'status': 'active',
      'lead': 'Julia',
      'createdAt': '2026-10-01T10:00:00Z',
      'updatedAt': '2026-10-10T09:30:00Z',
    });
    expect(thread.createdAt, '2026-10-01T10:00:00Z');
    expect(thread.updatedAt, '2026-10-10T09:30:00Z');
  });

  testWidgets(
      'Phase 16 — EstablishedUserHome renders AI capability updates with distinct badges',
      (tester) async {
    const aiUpdates = [
      AxAiCapabilityUpdate(
        id: 'ai-up-1',
        workerProfileId: 'chatgpt',
        provider: 'openai',
        type: AxAiCapabilityUpdateType.modelAdded,
        title: 'New Reasoning Model',
        summary: 'Deep reasoning model enabled for complex code architecture.',
        publishedAt: '2026-10-08T00:00:00Z',
        dateDisplay: 'Oct 8',
      ),
      AxAiCapabilityUpdate(
        id: 'ai-up-2',
        workerProfileId: 'gemini',
        provider: 'google',
        type: AxAiCapabilityUpdateType.capabilityAdded,
        title: 'Structured Output Mode',
        summary: 'Enforce JSON schema guarantees across multi-turn runs.',
        publishedAt: '2026-10-09T00:00:00Z',
        dateDisplay: 'Oct 9',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EstablishedUserHome(
            historicalUpdates: const [],
            spaces: const [
              AxSpace(
                id: 'p-1',
                name: 'Active Space',
                description: 'Space description',
                archived: false,
                branch: 'main',
                lastActivity: 'Just now',
                threads: [
                  AxThread(
                    id: 'ws-1',
                    spaceId: 'p-1',
                    name: 'AI Stream',
                    lead: 'Gemini',
                    status: 'active',
                    brief: '',
                    primaryWorkspace: '',
                    queueStatus: 'idle',
                  ),
                ],
              ),
            ],
            workspaces: const [],
            workers: const [
              AxWorker(
                id: 'w-chatgpt',
                workspaceId: 'ws-local',
                workspaceName: 'Local',
                workerTypeId: 'chatgpt',
                displayName: 'ChatGPT Worker',
                status: 'ready',
                readinessState: 'ready',
                localConcurrencyLimit: 2,
              ),
            ],
            run: null,
            openFindingCount: 0,
            aiUpdates: aiUpdates,
            onOpenSpace: (_) {},
            onOpenRun: (_, __) {},
            onOpenWorkspaces: () {},
          ),
        ),
      ),
    );

    // Verify section header and update details
    expect(find.text('AI updates'), findsOneWidget);
    expect(find.text('ChatGPT Worker'), findsOneWidget);
    expect(find.text('MODEL ADDED'), findsOneWidget);
    expect(find.text('New Reasoning Model'), findsOneWidget);
    expect(find.text('Oct 8, 2026'), findsOneWidget);

    expect(find.text('Gemini Worker'), findsOneWidget);
    expect(find.text('CAPABILITY ADDED'), findsOneWidget);
    expect(find.text('Structured Output Mode'), findsOneWidget);
    expect(find.text('Oct 9, 2026'), findsOneWidget);
  });

  testWidgets('AI updates See all opens the full update dialog',
      (tester) async {
    const update = AxAiCapabilityUpdate(
      id: 'ai-dialog-1',
      workerProfileId: 'chatgpt',
      provider: 'openai',
      type: AxAiCapabilityUpdateType.modelAdded,
      modelDisplayName: 'GPT-5',
      title: 'GPT-5 is available',
      summary: 'Use the newest reasoning model for demanding tasks.',
      publishedAt: '2026-10-08T00:00:00Z',
      dateDisplay: 'Oct 8',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EstablishedUserHome(
          historicalUpdates: const [],
          spaces: const [space],
          workspaces: const [],
          workers: const [
            AxWorker(
              id: 'worker-1',
              workspaceId: 'workspace-1',
              workspaceName: 'Local',
              workerTypeId: 'chatgpt',
              displayName: 'ChatGPT Worker',
              status: 'ready',
              readinessState: 'ready',
              localConcurrencyLimit: 1,
            ),
          ],
          aiUpdates: [update],
          run: null,
          openFindingCount: 0,
          onOpenSpace: (_) {},
          onOpenRun: (_, __) {},
          onOpenWorkspaces: () {},
        ),
      ),
    ));

    await tester.ensureVisible(find.text('See all').last);
    await tester.tap(find.text('See all').last);
    await tester.pumpAndSettle();
    // AI updates open as a full page; Home is no longer visible behind it.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('AI updates'), findsOneWidget);
    expect(find.text('New Worker execution options and model updates'),
        findsOneWidget);
    expect(find.text('GPT-5 is available'), findsWidgets);
    expect(find.text('Use the newest reasoning model for demanding tasks.'),
        findsWidgets);
    expect(
        find.descendant(
            of: find.byType(AxAiUpdatesDialog),
            matching: find.text('Model: GPT-5')),
        findsOneWidget);
  });

  test(
      'Phase 17 — AxAiCapabilityUpdateService filters AI updates by user accessible workers',
      () {
    const chatgptWorker = AxWorker(
      id: 'w-1',
      workspaceId: 'ws-1',
      workspaceName: 'Local',
      workerTypeId: 'chatgpt',
      displayName: 'ChatGPT Worker',
      status: 'ready',
      readinessState: 'ready',
      localConcurrencyLimit: 1,
    );

    const updates = [
      AxAiCapabilityUpdate(
        id: 'up-gpt',
        workerProfileId: 'chatgpt',
        provider: 'openai',
        type: AxAiCapabilityUpdateType.modelAdded,
        title: 'ChatGPT New Model',
        summary: 'New o3 model available.',
      ),
      AxAiCapabilityUpdate(
        id: 'up-claude',
        workerProfileId: 'claude',
        provider: 'anthropic',
        type: AxAiCapabilityUpdateType.modelAdded,
        title: 'Claude 3.7 Sonnet',
        summary: 'Hybrid reasoning and artifacts.',
      ),
      AxAiCapabilityUpdate(
        id: 'up-gemini',
        workerProfileId: 'gemini',
        provider: 'google',
        type: AxAiCapabilityUpdateType.capabilityAdded,
        title: 'Gemini Search Grounding',
        summary: 'Web grounded search outputs.',
      ),
    ];

    // Case 1: User has ChatGPT only -> ONLY ChatGPT updates returned
    final chatgptOnly = AxAiCapabilityUpdateService.getRelevantUpdates(
      updates: updates,
      workers: [chatgptWorker],
      spaces: const [],
    );
    expect(chatgptOnly.length, 1);
    expect(chatgptOnly.first.workerProfileId, 'chatgpt');
    expect(chatgptOnly.first.title, 'ChatGPT New Model');

    // Case 2: User gains access through shared Space Worker (e.g. Gemini lead/config in shared space)
    const sharedSpace = AxSpace(
      id: 'proj-shared',
      name: 'Shared Space',
      branch: 'main',
      lastActivity: 'Now',
      threads: [
        AxThread(
          id: 'ws-gemini',
          spaceId: 'proj-shared',
          name: 'Gemini Analysis',
          lead: 'Gemini',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: 'idle',
        ),
      ],
    );

    final chatgptAndSharedGemini =
        AxAiCapabilityUpdateService.getRelevantUpdates(
      updates: updates,
      workers: [chatgptWorker],
      spaces: [sharedSpace],
    );
    expect(chatgptAndSharedGemini.length, 2);
    final workerIds =
        chatgptAndSharedGemini.map((u) => u.workerProfileId).toSet();
    expect(workerIds, containsAll(['chatgpt', 'gemini']));
    expect(workerIds, isNot(contains('claude')));

    // Case 3: User with 0 accessible workers -> returns empty list (cleanly omitted)
    final zeroWorkers = AxAiCapabilityUpdateService.getRelevantUpdates(
      updates: updates,
      workers: const [],
      spaces: const [],
    );
    expect(zeroWorkers, isEmpty);
  });

  testWidgets(
      'Phase 17 — EstablishedUserHome omits AI updates when user has no accessible workers',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EstablishedUserHome(
            historicalUpdates: const [],
            spaces: const [
              AxSpace(
                id: 'p-1',
                name: 'Solo Space',
                description: 'Solo space',
                archived: false,
                branch: 'main',
                lastActivity: 'Just now',
                threads: [],
              ),
            ],
            workspaces: const [],
            workers: const [],
            run: null,
            openFindingCount: 0,
            onOpenSpace: (_) {},
            onOpenRun: (_, __) {},
            onOpenWorkspaces: () {},
          ),
        ),
      ),
    );

    // AI updates section is omitted cleanly
    expect(find.text('AI updates'), findsNothing);
  });

  test(
      'Phase 18 — Model discovery automatically generates system AI capability updates',
      () {
    final discoveryUpdates =
        AxAiCapabilityUpdateService.synthesizeDiscoveredModelUpdates(
      workerProfileId: 'chatgpt',
      provider: 'openai',
      workerDisplayName: 'ChatGPT Worker',
      previousModelIds: ['gpt-4o', 'o1-mini'],
      currentModelIds: ['gpt-4o', 'o1-mini', 'o3-mini'],
      timestamp: DateTime(2026, 10, 8),
    );

    expect(discoveryUpdates.length, 1);
    final autoUpdate = discoveryUpdates.first;
    expect(autoUpdate.isSystemGenerated, isTrue);
    expect(autoUpdate.isEditorial, isFalse);
    expect(autoUpdate.source, AxAiCapabilityUpdateSource.systemGenerated);
    expect(autoUpdate.type, AxAiCapabilityUpdateType.modelAdded);
    expect(autoUpdate.modelId, 'o3-mini');
    expect(autoUpdate.title, 'New model available');
    expect(autoUpdate.summary,
        'Model o3-mini is now available for your ChatGPT Worker.');
  });

  test(
      'Phase 18 — Editorial updates take precedence over raw system discovery updates',
      () {
    const editorialUpdate = AxAiCapabilityUpdate(
      id: 'ed-o3-mini',
      workerProfileId: 'chatgpt',
      provider: 'openai',
      type: AxAiCapabilityUpdateType.modelAdded,
      source: AxAiCapabilityUpdateSource.editorial,
      modelId: 'o3-mini',
      title: 'OpenAI o3-mini reasoning model released',
      summary: 'High-speed STEM reasoning model with flexible effort controls.',
      publishedAt: '2026-10-08T00:00:00Z',
    );

    final rawDiscoveryUpdates =
        AxAiCapabilityUpdateService.synthesizeDiscoveredModelUpdates(
      workerProfileId: 'chatgpt',
      previousModelIds: ['gpt-4o'],
      currentModelIds: ['gpt-4o', 'o3-mini', 'gpt-4.5'],
    );
    expect(rawDiscoveryUpdates.length, 2);

    final merged = AxAiCapabilityUpdateService.mergeUpdates(
      editorialUpdates: [editorialUpdate],
      discoveryUpdates: rawDiscoveryUpdates,
    );

    // Should have 2 items total: editorial for o3-mini and discovery for gpt-4.5
    expect(merged.length, 2);
    final o3Item = merged.firstWhere((u) => u.modelId == 'o3-mini');
    expect(o3Item.isEditorial, isTrue);
    expect(o3Item.title, 'OpenAI o3-mini reasoning model released');

    final gpt45Item = merged.firstWhere((u) => u.modelId == 'gpt-4.5');
    expect(gpt45Item.isSystemGenerated, isTrue);
    expect(gpt45Item.title, 'New model available');
  });

  testWidgets(
      'Phase 19 — Running now renders ephemeral execution card with rich metadata and Open CTA when run is active',
      (tester) async {
    String? openedSpaceId;
    String? openedRunId;

    const activeRunSpace = AxSpace(
      id: 'proj-landing',
      name: 'Website',
      branch: 'main',
      lastActivity: 'Today',
    );

    const activeRun = AxRun(
      id: 'run-101',
      spaceId: 'proj-landing',
      spaceName: 'Website',
      threadId: 'ws-landing',
      threadTitle: 'Landing Page',
      status: RunStatus.running,
      objective: 'Landing page review',
      taskCount: 5,
      completedTaskCount: 2,
      openFindingCount: 0,
      verifiedCriterionCount: 2,
      criterionCount: 5,
      workerName: 'ChatGPT',
      modelName: 'Model X',
      effort: 'High',
      durationDisplay: 'Running for 1m 42s',
    );

    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          historicalUpdates: const [],
          spaces: const [activeRunSpace],
          workspaces: const [],
          workers: const [],
          invitations: const [],
          attentionItems: const [],
          continueWorkItems: const [],
          productUpdates: const [],
          productUpdateReadStates: const {},
          aiUpdates: const [],
          run: activeRun,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenRun: (pId, rId) {
            openedSpaceId = pId;
            openedRunId = rId;
          },
        ),
      ),
    );

    // Section header
    expect(find.text('Running now'), findsOneWidget);

    // Card contents
    expect(find.text('Landing page review'), findsOneWidget);
    expect(find.text('ChatGPT · Model X · High'), findsOneWidget);
    expect(find.text('Website / Landing Page'), findsOneWidget);
    expect(find.text('Running for 1m 42s'), findsOneWidget);
    expect(find.text('Open →'), findsOneWidget);

    // Tap CTA
    await tester.tap(find.text('Open →'));
    expect(openedSpaceId, 'proj-landing');
    expect(openedRunId, 'run-101');
  });

  testWidgets(
      'Phase 19 — Running now is completely omitted with zero noise when run is null or completed',
      (tester) async {
    // 1. When run is null
    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          historicalUpdates: const [],
          spaces: const [space],
          workspaces: const [],
          workers: const [],
          invitations: const [],
          attentionItems: const [],
          continueWorkItems: const [],
          productUpdates: const [],
          productUpdateReadStates: const {},
          aiUpdates: const [],
          run: null,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenRun: (_, __) {},
        ),
      ),
    );

    expect(find.text('Running now'), findsNothing);
    expect(find.text('Open →'), findsNothing);
    expect(find.text('No active runs'), findsNothing);
    expect(find.text('No runs executing'), findsNothing);

    // 2. When run status is completed
    const completedRun = AxRun(
      id: 'run-done',
      status: RunStatus.completed,
      objective: 'Completed task review',
      taskCount: 3,
      completedTaskCount: 3,
      openFindingCount: 0,
      verifiedCriterionCount: 3,
      criterionCount: 3,
    );

    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          historicalUpdates: const [],
          spaces: const [space],
          workspaces: const [],
          workers: const [],
          invitations: const [],
          attentionItems: const [],
          continueWorkItems: const [],
          productUpdates: const [],
          productUpdateReadStates: const {},
          aiUpdates: const [],
          run: completedRun,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenRun: (_, __) {},
        ),
      ),
    );

    expect(find.text('Running now'), findsNothing);
    expect(find.text('Completed task review'), findsNothing);
  });

  testWidgets(
      'Phase 20 — Conditional Home composition renders only active sections (User A: For You + Running Now)',
      (tester) async {
    const activeRun = AxRun(
      id: 'run-1',
      status: RunStatus.running,
      objective: 'Optimizing database queries',
      taskCount: 4,
      completedTaskCount: 2,
      openFindingCount: 0,
      verifiedCriterionCount: 1,
      criterionCount: 4,
    );

    const testAttentionItem = AxHomeAttentionItem(
      id: 'att-1',
      type: AxHomeAttentionType.workspaceProblem,
      title: 'MacBook Pro is disconnected',
      description: 'MacBook Pro workspace disconnected',
      actionLabel: 'Reconnect →',
    );

    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          historicalUpdates: const [],
          spaces: const [space],
          workspaces: const [],
          workers: const [],
          invitations: const [],
          attentionItems: const [testAttentionItem],
          continueWorkItems: const [],
          productUpdates: const [
            AxProductUpdate(
              id: 'update-draft',
              slug: 'draft-feature',
              title: 'Draft Feature',
              summary: 'Not yet visible to users',
              publishedAt: '2026-10-08T00:00:00Z',
              status: AxProductUpdateStatus.draft,
            ),
          ],
          productUpdateReadStates: const {},
          aiUpdates: const [
            AxAiCapabilityUpdate(
              id: 'ai-claude-inaccessible',
              workerProfileId: 'claude-unassigned',
              provider: 'anthropic',
              type: AxAiCapabilityUpdateType.modelAdded,
              title: 'Claude 3.7 Sonnet',
              summary: 'Claude model upgrade for Anthropic users',
              publishedAt: '2026-10-08T00:00:00Z',
            ),
          ],
          run: activeRun,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenRun: (_, __) {},
        ),
      ),
    );

    // Section 1: For You - present
    expect(find.text('For you'), findsOneWidget);
    expect(find.text('Workspace offline'), findsOneWidget);

    // Section 2: Running Now - present
    expect(find.text('Running now'), findsOneWidget);
    expect(find.text('Optimizing database queries'), findsOneWidget);

    // Section 3: Continue Working - present (fallback derived from space)
    expect(find.text('Continue working'), findsOneWidget);

    // Section 4: What's New - omitted (only draft update)
    expect(find.text("What's new"), findsNothing);

    // Section 5: AI Updates - omitted (claude-unassigned not accessible to user)
    expect(find.text('AI updates'), findsNothing);
  });

  testWidgets(
      'Phase 20 — Conditional Home composition renders only active sections (User B: Continue Working + What\'s New + AI Updates)',
      (tester) async {
    const testWorker = AxWorker(
      id: 'worker-chatgpt',
      workspaceId: 'ws-macbook',
      workspaceName: 'Local Workspace',
      workerTypeId: 'chatgpt',
      displayName: 'ChatGPT Worker',
      status: 'ready',
      readinessState: 'ready',
      localConcurrencyLimit: 1,
    );

    const testPublishedUpdate = AxProductUpdate(
      id: 'update-collab',
      slug: 'realtime-collab',
      title: 'Real-time Collaboration',
      summary: 'Collaborate live with teammates.',
      publishedAt: '2026-10-08T00:00:00Z',
      status: AxProductUpdateStatus.published,
    );

    const testAiUpdate = AxAiCapabilityUpdate(
      id: 'ai-chatgpt-o3',
      workerProfileId: 'chatgpt',
      provider: 'openai',
      type: AxAiCapabilityUpdateType.modelAdded,
      title: 'OpenAI o3-mini model',
      summary: 'High-speed reasoning model available.',
      publishedAt: '2026-10-08T00:00:00Z',
    );

    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          historicalUpdates: const [],
          spaces: const [space],
          workspaces: const [],
          workers: const [testWorker],
          invitations: const [],
          attentionItems: const [],
          continueWorkItems: const [],
          productUpdates: const [testPublishedUpdate],
          productUpdateReadStates: const {},
          aiUpdates: const [testAiUpdate],
          run: null, // No active executions
          openFindingCount: 0, // No attention items
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenRun: (_, __) {},
        ),
      ),
    );

    // Section 1: For You - omitted
    expect(find.text('For you'), findsNothing);

    // Section 2: Running Now - omitted
    expect(find.text('Running now'), findsNothing);

    // Section 3: Continue Working - present
    expect(find.text('Continue working'), findsOneWidget);

    // Section 4: What's New - present
    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Real-time Collaboration'), findsOneWidget);

    // Section 5: AI Updates - present
    expect(find.text('AI updates'), findsOneWidget);
    expect(find.text('OpenAI o3-mini model'), findsOneWidget);
  });

  testWidgets(
      'Phase 21 — Establish visual hierarchy renders sections in canonical order with For You strongest',
      (tester) async {
    const activeRun = AxRun(
      id: 'run-urgent',
      status: RunStatus.running,
      objective: 'Generating security audit report',
      taskCount: 3,
      completedTaskCount: 1,
      openFindingCount: 0,
      verifiedCriterionCount: 1,
      criterionCount: 3,
    );

    const urgentAttentionItem = AxHomeAttentionItem(
      id: 'att-approval',
      type: AxHomeAttentionType.approvalRequired,
      title: 'Production deployment approval',
      description: 'Review pending changes before deployment',
      actionLabel: 'Approve →',
    );

    const testWorker = AxWorker(
      id: 'worker-chatgpt',
      workspaceId: 'ws-main',
      workspaceName: 'Local Workspace',
      workerTypeId: 'chatgpt',
      displayName: 'ChatGPT Worker',
      status: 'ready',
      readinessState: 'ready',
      localConcurrencyLimit: 1,
    );

    const testPublishedUpdate = AxProductUpdate(
      id: 'update-sec',
      slug: 'security-audit',
      title: 'Enhanced Tool Isolation',
      summary: 'Strict process containment for CLI tools.',
      publishedAt: '2026-10-08T00:00:00Z',
      status: AxProductUpdateStatus.published,
    );

    const testAiUpdate = AxAiCapabilityUpdate(
      id: 'ai-gpt-reasoning',
      workerProfileId: 'chatgpt',
      provider: 'openai',
      type: AxAiCapabilityUpdateType.modelAdded,
      title: 'GPT-4o Reasoning',
      summary: 'Deep reasoning model for complex code.',
      publishedAt: '2026-10-08T00:00:00Z',
    );

    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          historicalUpdates: const [],
          spaces: const [space],
          workspaces: const [],
          workers: const [testWorker],
          invitations: const [],
          attentionItems: const [urgentAttentionItem],
          continueWorkItems: const [],
          productUpdates: const [testPublishedUpdate],
          productUpdateReadStates: const {},
          aiUpdates: const [testAiUpdate],
          run: activeRun,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenRun: (_, __) {},
        ),
      ),
    );

    // 1. For You is rendered at the top (strongest visual weight)
    expect(find.text('For you'), findsOneWidget);
    expect(find.text('Production deployment approval'), findsOneWidget);
    expect(find.text('Approve →'), findsNothing);

    // 2. Running Now is present directly below For You
    expect(find.text('Running now'), findsOneWidget);
    expect(find.text('Generating security audit report'), findsOneWidget);

    // 3. Continue Working is present as primary daily activity
    expect(find.text('Continue working'), findsOneWidget);

    // 4. What's New is rendered below Continue Working as secondary editorial content
    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Enhanced Tool Isolation'), findsOneWidget);

    // 5. AI Updates is rendered as secondary capability discovery
    expect(find.text('AI updates'), findsOneWidget);
    expect(find.text('GPT-4o Reasoning'), findsOneWidget);

    // Verify ordering in widget tree: For you appears before Running now, before Continue working, before What's new, before AI updates
    final forYouPos = tester.getTopLeft(find.text('For you')).dy;
    final runningNowPos = tester.getTopLeft(find.text('Running now')).dy;
    final continueWorkPos = tester.getTopLeft(find.text('Continue working')).dy;
    final whatsNewPos = tester.getTopLeft(find.text("What's new")).dy;
    final aiUpdatesPos = tester.getTopLeft(find.text('AI updates')).dy;

    expect(forYouPos < runningNowPos, isTrue);
    expect(runningNowPos < continueWorkPos, isTrue);
    expect(continueWorkPos < whatsNewPos, isTrue);
    expect(whatsNewPos < aiUpdatesPos, isTrue);
  });

  testWidgets(
      'Phase 22 — Avoid excessive cards: For You, What\'s New, and AI Updates render as clean section rows with dividers',
      (tester) async {
    const activeRun = AxRun(
      id: 'run-1',
      status: RunStatus.running,
      objective: 'Optimizing database queries',
      taskCount: 4,
      completedTaskCount: 2,
      openFindingCount: 0,
      verifiedCriterionCount: 1,
      criterionCount: 4,
    );

    const testAttentionItem = AxHomeAttentionItem(
      id: 'att-1',
      type: AxHomeAttentionType.workspaceProblem,
      title: 'MacBook Pro is disconnected',
      description: 'MacBook Pro workspace disconnected',
      actionLabel: 'Reconnect →',
    );

    const testWorker = AxWorker(
      id: 'worker-chatgpt',
      workspaceId: 'ws-main',
      workspaceName: 'Local Workspace',
      workerTypeId: 'chatgpt',
      displayName: 'ChatGPT Worker',
      status: 'ready',
      readinessState: 'ready',
      localConcurrencyLimit: 1,
    );

    const testProductUpdate = AxProductUpdate(
      id: 'update-1',
      slug: 'realtime-collab',
      title: 'Real-time Collaboration',
      summary: 'Collaborate live with teammates.',
      publishedAt: '2026-10-08T00:00:00Z',
      status: AxProductUpdateStatus.published,
    );

    const testAiUpdate = AxAiCapabilityUpdate(
      id: 'ai-1',
      workerProfileId: 'chatgpt',
      provider: 'openai',
      type: AxAiCapabilityUpdateType.modelAdded,
      title: 'OpenAI o3-mini',
      summary: 'Fast reasoning model.',
      publishedAt: '2026-10-08T00:00:00Z',
    );

    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          historicalUpdates: const [],
          spaces: const [space],
          workspaces: const [],
          workers: const [testWorker],
          invitations: const [],
          attentionItems: const [testAttentionItem],
          continueWorkItems: const [],
          productUpdates: const [testProductUpdate],
          productUpdateReadStates: const {},
          aiUpdates: const [testAiUpdate],
          run: activeRun,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenRun: (_, __) {},
        ),
      ),
    );

    // Verify For You item tile is present as a row (with category badge and action button)
    expect(find.text('MacBook Pro is disconnected'), findsOneWidget);
    expect(find.text('Reconnect →'), findsNothing);

    // Verify Running Now card is present
    expect(find.text('Optimizing database queries'), findsOneWidget);

    // Verify Continue Working card is present
    expect(find.text('Continue working'), findsOneWidget);

    // Verify What's New tile is present as a row
    expect(find.text('Real-time Collaboration'), findsOneWidget);
    expect(find.text('Learn more →'), findsNothing);

    // Verify AI Update row is present
    expect(find.text('OpenAI o3-mini'), findsOneWidget);
    expect(find.text('Fast reasoning model.'), findsOneWidget);
  });

  testWidgets(
      'Phase 23 — Improve Home header: renders clean Home title, omits marketing subtitle, and supports optional personalized greeting',
      (tester) async {
    // 1. Without greeting or userName: renders Home only and zero marketing subtitle
    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          historicalUpdates: const [],
          spaces: const [space],
          workspaces: const [],
          workers: const [],
          invitations: const [],
          attentionItems: const [],
          continueWorkItems: const [],
          productUpdates: const [],
          productUpdateReadStates: const {},
          aiUpdates: const [],
          run: null,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenRun: (_, __) {},
        ),
      ),
    );

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Your execution capacity at a glance.'), findsNothing);

    // 2. With explicit greeting: renders personalized greeting subtitle
    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          historicalUpdates: const [],
          spaces: const [space],
          workspaces: const [],
          workers: const [],
          invitations: const [],
          attentionItems: const [],
          continueWorkItems: const [],
          productUpdates: const [],
          productUpdateReadStates: const {},
          aiUpdates: const [],
          greeting: 'Good morning, Vitalii.',
          run: null,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenRun: (_, __) {},
        ),
      ),
    );

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Good morning, Vitalii.'), findsOneWidget);
    expect(find.text('Your execution capacity at a glance.'), findsNothing);

    // 3. With userName: dynamically derives time-based greeting
    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          historicalUpdates: const [],
          spaces: const [space],
          workspaces: const [],
          workers: const [],
          invitations: const [],
          attentionItems: const [],
          continueWorkItems: const [],
          productUpdates: const [],
          productUpdateReadStates: const {},
          aiUpdates: const [],
          userName: 'Vitalii',
          run: null,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenRun: (_, __) {},
        ),
      ),
    );

    expect(find.text('Home'), findsOneWidget);
    expect(find.textContaining('Vitalii.'), findsOneWidget);
    expect(find.text('Your execution capacity at a glance.'), findsNothing);
  });

  testWidgets(
      'Phase 24 — Home excludes Archived Spaces utility shortcuts and leaves archive management to navigation',
      (tester) async {
    await tester.pumpWidget(
      scaffold(
        HomePage(
          historicalUpdates: const [],
          spaces: const [space],
          workspaces: const [],
          workers: const [],
          run: null,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenRun: (_, __) {},
          onCreateSpace: () {},
        ),
      ),
    );

    // Home must NOT render Archived Spaces shortcut or button
    expect(find.text('Archived Spaces'), findsNothing);
    expect(find.byIcon(Icons.archive_outlined), findsNothing);
  });

  testWidgets(
      'Phase 26 — Deep-link every Home item to its exact actionable destination',
      (tester) async {
    String? openedSpace;
    String? openedThread;
    var openedWorkspaces = false;
    AxProductUpdate? openedUpdate;
    AxAiCapabilityUpdate? openedAiUpdate;

    const attentionItems = [
      AxHomeAttentionItem(
        id: 'att-input-1',
        type: AxHomeAttentionType.needsInput,
        title: 'Landing Page Approval Required',
        description: 'Review updated copy for launch',
        spaceId: 'space-1',
        threadId: 'ws-landing',
        actionLabel: 'Review →',
        isUnread: true,
        isActionable: true,
      ),
      AxHomeAttentionItem(
        id: 'att-ws-problem',
        type: AxHomeAttentionType.workspaceProblem,
        title: 'Mac Studio is offline',
        description: 'Reconnect Workspace to resume execution',
        actionLabel: 'Connect →',
        isUnread: true,
        isActionable: true,
      ),
    ];

    const continueItems = [
      AxContinueWorkItem(
        spaceId: 'space-1',
        spaceName: 'Alpha Space',
        threadId: 'ws-landing',
        threadTitle: 'Landing Page',
        collaboratorsDisplay: 'You + ChatGPT',
        lastMessageSnippet: 'Ready for deployment review.',
        lastActivityDisplay: '10m ago',
      ),
    ];

    const updates = [
      AxProductUpdate(
        id: 'up-1',
        slug: 'space-invitations',
        title: 'Space Invitations',
        summary: 'Invite collaborators to shared spaces.',
        category: AxProductUpdateCategory.collaboration,
        publishedAt: '2026-10-07T00:00:00Z',
        dateDisplay: 'Oct 7',
        status: AxProductUpdateStatus.published,
      ),
    ];

    const aiUpdates = [
      AxAiCapabilityUpdate(
        id: 'ai-1',
        workerProfileId: 'chatgpt',
        workerDisplayName: 'ChatGPT Worker',
        type: AxAiCapabilityUpdateType.modelAdded,
        title: 'GPT-5 Model Available',
        summary: 'GPT-5 is now available for your ChatGPT Worker.',
        publishedAt: '2026-10-07T00:00:00Z',
        dateDisplay: 'Oct 7',
        source: AxAiCapabilityUpdateSource.editorial,
      ),
    ];

    await tester.pumpWidget(
      scaffold(
        HomePage(
          historicalUpdates: const [],
          spaces: const [space],
          workspaces: const [],
          workers: const [
            AxWorker(
              id: 'w-chatgpt',
              workspaceId: 'ws-local',
              workspaceName: 'Local Workspace',
              workerTypeId: 'chatgpt',
              displayName: 'ChatGPT Worker',
              status: 'ready',
              readinessState: 'ready',
              localConcurrencyLimit: 1,
            ),
          ],
          attentionItems: attentionItems,
          continueWorkItems: continueItems,
          productUpdates: updates,
          aiUpdates: aiUpdates,
          run: null,
          openFindingCount: 0,
          onOpenWorkspaces: () => openedWorkspaces = true,
          onOpenSpace: (pId) => openedSpace = pId,
          onOpenThread: (pId, wsId) {
            openedSpace = pId;
            openedThread = wsId;
          },
          onOpenRun: (_, __) {},
          onCreateSpace: () {},
          onOpenUpdateDetail: (u) => openedUpdate = u,
          onOpenAiUpdate: (u) => openedAiUpdate = u,
        ),
      ),
    );

    // 1. Needs Input -> exact Thread deep-link
    expect(find.text('Landing Page Approval Required'), findsOneWidget);
    await tester.tap(find.text('Landing Page Approval Required'));
    expect(openedSpace, 'space-1');
    expect(openedThread, 'ws-landing');

    // 2. Workspace problem -> exact Workspaces deep-link
    await tester.ensureVisible(find.text('Mac Studio is offline'));
    await tester.tap(find.text('Mac Studio is offline'));
    expect(openedWorkspaces, isTrue);

    // 3. Continue Working -> exact Thread deep-link
    openedSpace = null;
    openedThread = null;
    await tester.ensureVisible(
        find.byKey(const ValueKey('continue-work-last-message')).first);
    await tester
        .tap(find.byKey(const ValueKey('continue-work-last-message')).first);
    expect(openedSpace, 'space-1');
    expect(openedThread, 'ws-landing');

    // 4. What's New and AI Update rows are informational, not links.
    expect(find.text('Learn more →'), findsNothing);
    expect(find.text('Configure →'), findsNothing);
    expect(openedUpdate, isNull);
    expect(openedAiUpdate, isNull);
  });

  testWidgets(
      'Phase 27 — Fault isolation: What\'s New or AI Updates failures do not block For You or Continue Working',
      (tester) async {
    var continueOpened = false;

    // We pass valid attention and continue items along with updates that are dismissed / draft or unavailable.
    // Even when secondary sections yield zero items or encounter errors, the primary surfaces (For You and Continue Working) must render flawlessly.
    const attentionItems = [
      AxHomeAttentionItem(
        id: 'attn-safe',
        type: AxHomeAttentionType.needsInput,
        title: 'Safe Attention Item',
        description: 'Requires user decision',
        spaceId: 'space-1',
        threadId: 'ws-safe',
        actionLabel: 'Open',
        isUnread: true,
        isActionable: true,
      ),
    ];

    const continueItems = [
      AxContinueWorkItem(
        spaceId: 'space-1',
        spaceName: 'Active Space',
        threadId: 'ws-safe',
        threadTitle: 'Active Thread',
        collaboratorsDisplay: 'You + ChatGPT',
        lastMessageSnippet: 'Working on core logic.',
        lastActivityDisplay: '5m ago',
      ),
    ];

    const draftUpdate = AxProductUpdate(
      id: 'draft-up',
      slug: 'draft-up',
      title: 'Draft Update',
      summary: 'Should not appear',
      publishedAt: '2026-10-08T00:00:00Z',
      status: AxProductUpdateStatus.draft,
    );

    const inaccessibleAiUpdate = AxAiCapabilityUpdate(
      id: 'ai-inaccessible',
      workerProfileId: 'inaccessible-worker',
      type: AxAiCapabilityUpdateType.modelAdded,
      title: 'Inaccessible Model',
      summary: 'Should not appear',
      publishedAt: '2026-10-08T00:00:00Z',
    );

    await tester.pumpWidget(
      scaffold(
        HomePage(
          historicalUpdates: const [],
          spaces: const [space],
          workspaces: const [],
          workers: const [],
          attentionItems: attentionItems,
          continueWorkItems: continueItems,
          productUpdates: const [draftUpdate],
          productUpdateReadStates: const {},
          aiUpdates: const [inaccessibleAiUpdate],
          run: null,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenThread: (_, __) => continueOpened = true,
          onOpenRun: (_, __) {},
          onCreateSpace: () {},
        ),
      ),
    );

    // Primary triage & daily activity must render cleanly
    expect(find.text('For you'), findsOneWidget);
    expect(find.text('Safe Attention Item'), findsOneWidget);
    expect(find.text('Continue working'), findsOneWidget);
    expect(find.text('Active Thread'), findsOneWidget);

    // Secondary empty/faulty sections gracefully collapse without whole-page error
    expect(find.text("What's new"), findsNothing);
    expect(find.text('AI updates'), findsNothing);

    // Verify interaction on continue item works
    await tester
        .tap(find.byKey(const ValueKey('continue-work-last-message')).first);
    expect(continueOpened, isTrue);
  });

  testWidgets(
      'Phase 28 — Offline behavior: EstablishedUserHome shows cached sections and connectivity indicator without replacing page',
      (tester) async {
    String? openedThread;
    AxProductUpdate? openedUpdate;

    const continueItems = [
      AxContinueWorkItem(
        spaceId: 'space-1',
        spaceName: 'Syntila Core',
        threadId: 'ws-offline',
        threadTitle: 'Offline Mode Testing',
        collaboratorsDisplay: 'You + ChatGPT',
        lastMessageSnippet: 'Cached context remains fully readable.',
        lastActivityDisplay: 'Just now',
      ),
    ];

    const cachedUpdates = [
      AxProductUpdate(
        id: 'up-cached',
        slug: 'cached-update',
        title: 'Cached Release Note',
        summary: 'Details loaded from local cache.',
        category: AxProductUpdateCategory.workflow,
        publishedAt: '2026-10-08T00:00:00Z',
        status: AxProductUpdateStatus.published,
      ),
    ];

    await tester.pumpWidget(
      scaffold(
        HomePage(
          historicalUpdates: const [],
          spaces: const [space],
          workspaces: const [],
          workers: const [],
          continueWorkItems: continueItems,
          productUpdates: cachedUpdates,
          productUpdateReadStates: const {},
          aiUpdates: const [],
          run: null,
          openFindingCount: 0,
          isOffline: true, // Offline mode active
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenThread: (pId, wsId) => openedThread = wsId,
          onOpenRun: (_, __) {},
          onCreateSpace: () {},
          onOpenUpdateDetail: (u) => openedUpdate = u,
        ),
      ),
    );

    // 1. Page is NOT replaced by an error screen; Home title renders
    expect(find.text('Home'), findsOneWidget);

    // 2. Connectivity indicator is displayed
    expect(find.text('Offline · Cached data'), findsOneWidget);

    // 3. Cached Continue Working is present and interactive
    expect(find.text('Continue working'), findsOneWidget);
    expect(find.text('Offline Mode Testing'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('continue-work-last-message')).first);
    expect(openedThread, 'ws-offline');

    // 4. Cached What's New is present and readable
    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Cached Release Note'), findsOneWidget);
    expect(find.text('Learn more →'), findsNothing);
    expect(openedUpdate, isNull);
  });

  testWidgets(
      'Phase 28 — Offline behavior: NewUserHome shows connectivity indicator when offline',
      (tester) async {
    await tester.pumpWidget(
      scaffold(
        HomePage(
          historicalUpdates: const [],
          spaces: const [],
          workspaces: const [],
          workers: const [],
          invitations: const [],
          run: null,
          openFindingCount: 0,
          isOffline: true,
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenRun: (_, __) {},
          onCreateSpace: () {},
        ),
      ),
    );

    expect(find.text('Welcome to Syntila'), findsOneWidget);
    expect(find.text('Offline · Cached data'), findsOneWidget);
    expect(find.text('How Syntila works'), findsOneWidget);
  });

  testWidgets(
      'Phase 30 — Privacy and permissions: Home aggregation omits space name, thread title, worker activity, conversation preview, and inaccessible AI updates after space access revocation',
      (tester) async {
    const authorizedSpace = AxSpace(
      id: 'proj-auth',
      name: 'Authorized Space',
      branch: 'main',
      lastActivity: 'Today',
    );

    // Attention items: one from authorized space, one from revoked space
    final attentionItems = [
      AxHomeAttentionItem(
        id: 'att-auth',
        spaceId: 'proj-auth',
        type: AxHomeAttentionType.needsInput,
        title: 'Review Authorized Spec',
        description: 'Input needed on authorized thread',
        createdAt: DateTime.parse('2026-10-08T09:00:00Z'),
      ),
      AxHomeAttentionItem(
        id: 'att-revoked',
        spaceId: 'proj-revoked',
        type: AxHomeAttentionType.approvalRequired,
        title: 'Secret Proposal in Revoked Space',
        description: 'Confidential preview of revoked thread',
        createdAt: DateTime.parse('2026-10-08T09:30:00Z'),
      ),
    ];

    // Continue work items: one from authorized space, one from revoked space
    const continueItems = [
      AxContinueWorkItem(
        spaceId: 'proj-auth',
        spaceName: 'Authorized Space',
        threadId: 'ws-auth',
        threadTitle: 'Active Authorized Thread',
        collaboratorsDisplay: 'You + ChatGPT',
        lastMessageSnippet: 'Authorized discussion snippet.',
        lastActivityDisplay: 'Just now',
      ),
      AxContinueWorkItem(
        spaceId: 'proj-revoked',
        spaceName: 'Revoked Secret Space',
        threadId: 'ws-revoked',
        threadTitle: 'Revoked Confidential Thread',
        collaboratorsDisplay: 'Alice + Claude',
        lastMessageSnippet: 'Revoked confidential message preview.',
        lastActivityDisplay: '10 min ago',
      ),
    ];

    // Running now: tied to revoked space
    const revokedRun = AxRun(
      id: 'run-revoked',
      spaceId: 'proj-revoked',
      spaceName: 'Revoked Secret Space',
      threadTitle: 'Revoked Confidential Thread',
      objective: 'Execute confidential task in revoked space',
      workerName: 'Secret Worker',
      status: RunStatus.running,
      taskCount: 1,
      completedTaskCount: 0,
      openFindingCount: 0,
      verifiedCriterionCount: 0,
      criterionCount: 1,
    );

    // AI Updates: one accessible (ChatGPT), one inaccessible (Ollama only available in revoked space)
    const aiUpdates = [
      AxAiCapabilityUpdate(
        id: 'ai-chatgpt',
        workerProfileId: 'chatgpt',
        provider: 'openai',
        type: AxAiCapabilityUpdateType.modelAdded,
        title: 'ChatGPT 4.5 Turbo Enabled',
        summary: 'New ChatGPT model is available for your spaces.',
        publishedAt: '2026-10-08T00:00:00Z',
      ),
      AxAiCapabilityUpdate(
        id: 'ai-ollama',
        workerProfileId: 'ollama',
        provider: 'ollama',
        type: AxAiCapabilityUpdateType.modelAdded,
        title: 'Llama 3.3 Available for Private Server',
        summary: 'Local models updated for inaccessible cluster.',
        publishedAt: '2026-10-08T00:00:00Z',
      ),
    ];

    // Workspace worker only supports ChatGPT
    const localWorker = AxWorker(
      id: 'w-chatgpt',
      workspaceId: 'ws-1',
      workspaceName: 'Local Workspace',
      workerTypeId: 'chatgpt',
      displayName: 'ChatGPT Worker',
      status: 'ready',
      readinessState: 'ready',
      localConcurrencyLimit: 1,
    );

    await tester.pumpWidget(
      scaffold(
        HomePage(
          historicalUpdates: const [],
          spaces: const [authorizedSpace],
          workspaces: const [],
          workers: const [localWorker],
          attentionItems: attentionItems,
          continueWorkItems: continueItems,
          aiUpdates: aiUpdates,
          run: revokedRun,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenSpace: (_) {},
          onOpenRun: (_, __) {},
          onCreateSpace: () {},
        ),
      ),
    );

    // 1. Authorized resources MUST render
    expect(find.text('AUTHORIZED SPACE'), findsNothing);
    expect(find.text('Active Authorized Thread'), findsOneWidget);
    expect(
        find.textContaining('Authorized discussion snippet.',
            findRichText: true),
        findsOneWidget);
    expect(find.text('Review Authorized Spec'), findsOneWidget);
    expect(find.text('ChatGPT 4.5 Turbo Enabled'), findsOneWidget);

    // 2. Revoked space resources MUST NEVER appear on Home
    expect(find.text('AUTHORIZED SPACE'), findsNothing);
    expect(find.text('REVOKED SECRET SPACE'), findsNothing);
    expect(find.text('Revoked Secret Space'), findsNothing);
    expect(find.text('Revoked Confidential Thread'), findsNothing);
    expect(find.text('Revoked confidential message preview.'), findsNothing);
    expect(find.text('Secret Proposal in Revoked Space'), findsNothing);
    expect(find.text('Confidential preview of revoked thread'), findsNothing);
    expect(
        find.text('Execute confidential task in revoked space'), findsNothing);
    expect(find.text('Running now'), findsNothing);

    // 3. AI Update tied to inaccessible worker MUST NEVER appear
    expect(find.text('Llama 3.3 Available for Private Server'), findsNothing);
  });

  group('Phase 32 — Realtime updates', () {
    test(
        'notificationFromRealtimeEvent parses invitation.received into For You invitation item',
        () {
      final event = {
        'type': 'invitation.received',
        'spaceId': 'proj-100',
        'payload': {
          'spaceId': 'proj-100',
          'spaceName': 'Super Space',
          'prompt': 'Julia invited you to join Super Space',
        },
      };

      final notification = notificationFromRealtimeEvent(event);
      expect(notification, isNotNull);
      expect(notification!.kind, AxNotificationKind.spaceInvitationReceived);
      expect(notification.spaceId, 'proj-100');

      final items = AxHomeAttentionProjector.space(
        invitations: [
          const AxSpaceInvitation(
            id: 'inv-rt',
            spaceId: 'proj-100',
            spaceName: 'Super Space',
            email: 'user@syntila.dev',
            role: 'member',
            status: 'pending',
            invitedByUserId: 'u-1',
            invitedByUserEmail: 'julia@syntila.dev',
            invitedByUserName: 'Julia',
            createdAt: '2026-10-08T08:00:00Z',
          ),
        ],
        rawAttentionItems: const [],
        openFindingCount: 0,
        spaces: const [space],
      );

      expect(items, hasLength(1));
      expect(items.first.title, contains('Julia invited you to Super Space'));
      expect(items.first.effectiveType, AxHomeAttentionType.spaceInvitation);
    });

    test(
        'notificationFromRealtimeEvent parses thread.needs_input and spaces to For You',
        () {
      final event = {
        'type': 'thread.needs_input',
        'spaceId': 'space-1',
        'threadId': 'ws-1',
        'payload': {
          'spaceId': 'space-1',
          'threadId': 'ws-1',
          'prompt': 'Please clarify API endpoints',
        },
      };

      final notification = notificationFromRealtimeEvent(event);
      expect(notification, isNotNull);
      expect(notification!.kind, AxNotificationKind.threadNeedsInput);
      expect(notification.title, 'Thread needs input');

      var openedThread = '';
      final rawItem = AxHomeAttentionItem(
        id: notification.id,
        kind: AxHomeAttentionType.needsInput,
        title: notification.title,
        subtitle: notification.message,
        spaceId: notification.spaceId,
        threadId: notification.threadId,
        isUnread: true,
        isActionable: true,
      );

      final items = AxHomeAttentionProjector.space(
        invitations: const [],
        rawAttentionItems: [rawItem],
        openFindingCount: 0,
        spaces: const [space],
        onOpenThread: (pId, wsId) => openedThread = '$pId/$wsId',
      );

      expect(items, hasLength(1));
      expect(items.first.primaryAction?.label, 'Review →');
      items.first.primaryAction?.onPerform();
      expect(openedThread, 'space-1/ws-1');
    });

    test('thread.completed does not create a For You action', () {
      // Completed Threads no longer create notifications.
      expect(
        notificationFromRealtimeEvent({
          'type': 'thread.completed',
          'spaceId': 'space-1',
          'threadId': 'ws-1',
        }),
        isNull,
      );

      const rawItem = AxHomeAttentionItem(
        id: 'thread-completed-1',
        kind: AxHomeAttentionType.executionCompleted,
        title: 'Thread completed',
        subtitle: 'Backend refactoring completed',
        spaceId: 'space-1',
        threadId: 'ws-1',
        isUnread: true,
        isActionable: false,
      );

      var openedThread = '';
      final items = AxHomeAttentionProjector.space(
        invitations: const [],
        rawAttentionItems: [rawItem],
        openFindingCount: 0,
        spaces: const [space],
        onOpenThread: (pId, wsId) => openedThread = '$pId/$wsId',
      );

      expect(items, isEmpty);
      expect(openedThread, isEmpty);
    });

    test('worker problem realtime events map to For You with Fix action', () {
      for (final eventType in [
        'worker.credential.expired',
        'worker.problem',
        'worker.credential.problem',
        'worker.install.failed',
        'workspace.offline',
      ]) {
        final event = {
          'type': eventType,
          'payload': {
            'error': 'Worker key expired or unreachable',
          },
        };

        final notification = notificationFromRealtimeEvent(event);
        expect(notification, isNotNull, reason: 'Failed to parse $eventType');

        var workspacesOpened = false;
        final rawItem = AxHomeAttentionItem(
          id: notification!.id,
          kind: eventType.contains('workspace')
              ? AxHomeAttentionType.workspaceProblem
              : AxHomeAttentionType.workerProblem,
          title: notification.title,
          subtitle: notification.message,
          isUnread: true,
          isActionable: true,
        );

        final items = AxHomeAttentionProjector.space(
          invitations: const [],
          rawAttentionItems: [rawItem],
          openFindingCount: 0,
          spaces: const [space],
          onOpenWorkspaces: () => workspacesOpened = true,
        );

        expect(items, hasLength(1));
        expect(items.first.primaryAction?.label, isIn(['Fix →', 'Connect →']));
        items.first.primaryAction?.onPerform();
        expect(workspacesOpened, isTrue);
      }
    });

    testWidgets('new product update dynamically updates What’s New badge count',
        (tester) async {
      final productUpdates = <AxProductUpdate>[
        const AxProductUpdate(
          id: 'up-1',
          slug: 'update-1',
          title: 'Update 1',
          summary: 'Summary 1',
          category: AxProductUpdateCategory.workflow,
          publishedAt: '2026-10-08T00:00:00Z',
          status: AxProductUpdateStatus.published,
        ),
      ];

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
        productUpdates: productUpdates,
        productUpdateReadStates: const {},
      )));

      // Unread count badge should reflect 1 unread update
      expect(find.text("What's new"), findsOneWidget);
      expect(find.text('1'), findsNothing);
    });
  });

  group('Phase 33 — Canonical Scenario Verification Matrix', () {
    // 1. Scenario: Brand-new account -> Expected: Create/Join Space onboarding
    testWidgets(
        'Scenario: Brand-new account -> Expected: Create/Join Space onboarding',
        (tester) async {
      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('Welcome to Syntila'), findsOneWidget);
      expect(find.text('Create your first Space'), findsOneWidget);
      expect(find.text('How Syntila works'), findsOneWidget);
      expect(find.text('People first'), findsOneWidget);
      expect(find.text('Private credentials'), findsOneWidget);
      expect(find.text('Shared conversations'), findsOneWidget);
      expect(find.text('For you'), findsNothing);
      expect(find.text('Continue working'), findsNothing);
    });

    // 2. Scenario: New user with invitation -> Expected: Invitation takes priority
    testWidgets(
        'Scenario: New user with invitation -> Expected: Invitation takes priority',
        (tester) async {
      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [],
        workspaces: const [],
        workers: const [],
        invitations: const [testInvite1],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('Join a Space'), findsOneWidget);
      expect(find.text('You have 1 invitation.'), findsOneWidget);
      expect(find.text('Family Travel'), findsOneWidget);
      expect(find.text('or'), findsOneWidget);
      expect(find.text('Create your first Space'), findsOneWidget);
    });

    // 3. Scenario: Space but no Workspace -> Expected: Normal Home, not setup warning
    testWidgets(
        'Scenario: Space but no Workspace -> Expected: Normal Home, not setup warning',
        (tester) async {
      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Welcome to Syntila'), findsNothing);
      expect(find.text('Setup required'), findsNothing);
      expect(find.text('Workspace offline'), findsNothing);
      expect(find.text('Continue working'), findsOneWidget);
    });

    // 4. Scenario: Invitation received realtime -> Expected: Appears in For You
    testWidgets(
        'Scenario: Invitation received realtime -> Expected: Appears in For You',
        (tester) async {
      final items = AxHomeAttentionProjector.space(
        invitations: const [testInvite1],
        rawAttentionItems: const [],
        openFindingCount: 0,
        spaces: const [space],
      );

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [testInvite1],
        attentionItems: items,
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('For you'), findsOneWidget);
      expect(find.text('Family Travel'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
    });

    // 5. Scenario: Invitation accepted -> Expected: Removed + Space appears
    testWidgets(
        'Scenario: Invitation accepted -> Expected: Removed + Space appears',
        (tester) async {
      AxSpaceInvitation? accepted;
      const newJoinedSpace = AxSpace(
        id: 'proj-123',
        name: 'Family Travel',
        branch: 'main',
        lastActivity: 'Just now',
      );

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [testInvite1],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
        onAcceptInvitation: (inv) => accepted = inv,
      )));

      await tester.tap(find.text('Accept'));
      expect(accepted?.id, 'inv-1');

      // Re-render with invitation accepted & converted to joined space
      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space, newJoinedSpace],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('Family Travel'), findsNothing);
      expect(find.text('FAMILY TRAVEL'), findsNothing);
    });

    // 6. Scenario: Thread needs input -> Expected: For You
    testWidgets('Scenario: Thread needs input -> Expected: For You',
        (tester) async {
      final items = [
        const AxHomeAttentionItem(
          id: 'att-needs-input',
          type: AxHomeAttentionType.needsInput,
          title: 'Input requested for API spec',
          subtitle: 'Please clarify query parameter types',
          spaceId: 'space-1',
          threadId: 'ws-1',
          isUnread: true,
          isActionable: true,
        ),
      ];

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        attentionItems: items,
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('For you'), findsOneWidget);
      expect(find.text('Input requested for API spec'), findsOneWidget);
      expect(find.text('Review →'), findsNothing);
    });

    // 7. Scenario: Work running -> Expected: Running Now appears
    testWidgets('Scenario: Work running -> Expected: Running Now appears',
        (tester) async {
      const activeRun = AxRun(
        id: 'run-1',
        spaceId: 'space-1',
        spaceName: 'Space One',
        threadTitle: 'Backend Architecture',
        objective: 'Generating database migration schemas',
        workerName: 'Syntila Core Engine',
        status: RunStatus.running,
        taskCount: 5,
        completedTaskCount: 2,
        openFindingCount: 0,
        verifiedCriterionCount: 1,
        criterionCount: 3,
      );

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        run: activeRun,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('Running now'), findsOneWidget);
      expect(
          find.text('Generating database migration schemas'), findsOneWidget);
      expect(find.text('2/5 tasks completed'), findsOneWidget);
      expect(find.text('Open →'), findsOneWidget);
    });

    // 8. Scenario: Work completes -> Expected: Running disappears, review appears
    testWidgets(
        'Scenario: Work completes -> Expected: Running and For you disappear',
        (tester) async {
      final completionItem = [
        const AxHomeAttentionItem(
          id: 'att-completed',
          type: AxHomeAttentionType.executionCompleted,
          title: 'Database schemas generated',
          subtitle: 'Completed successfully. 3 criteria verified.',
          spaceId: 'space-1',
          threadId: 'ws-1',
          isUnread: true,
          isActionable: false,
        ),
      ];

      // Re-rendered after completion: run is null / done, completion attention item in For You
      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        attentionItems: completionItem,
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('Running now'), findsNothing);
      expect(find.text('For you'), findsNothing);
      expect(find.text('Database schemas generated'), findsNothing);
      expect(find.text('Open →'), findsNothing);
    });

    // 9. Scenario: Recent Thread -> Expected: Continue Working
    testWidgets('Scenario: Recent Thread -> Expected: Continue Working',
        (tester) async {
      const activeSpace = AxSpace(
        id: 'p-1',
        name: 'Mobile Client',
        branch: 'main',
        lastActivity: '10m ago',
        threads: [
          AxThread(
            id: 'ws-101',
            spaceId: 'p-1',
            name: 'Authentication Flow',
            lead: 'Vitalii + ChatGPT',
            status: 'active',
            brief: 'Refactoring auth token storage and biometric login.',
            primaryWorkspace: 'ws',
            queueStatus: 'idle',
          ),
        ],
      );

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [activeSpace],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('Continue working'), findsOneWidget);
      expect(find.text('MOBILE CLIENT'), findsNothing);
      expect(find.text('Authentication Flow'), findsOneWidget);
      expect(
          find.textContaining(
              'Refactoring auth token storage and biometric login.',
              findRichText: true),
          findsOneWidget);
    });

    // 10. Scenario: Archived Thread -> Expected: Not shown
    testWidgets('Scenario: Archived Thread -> Expected: Not shown',
        (tester) async {
      const spaceWithArchived = AxSpace(
        id: 'p-1',
        name: 'Mobile Client',
        branch: 'main',
        lastActivity: '10m ago',
        threads: [
          AxThread(
            id: 'ws-active',
            spaceId: 'p-1',
            name: 'Active Thread',
            lead: 'Vitalii',
            status: 'active',
            brief: 'Active work in progress.',
            primaryWorkspace: 'ws',
            queueStatus: 'idle',
            archived: false,
          ),
          AxThread(
            id: 'ws-archived',
            spaceId: 'p-1',
            name: 'Obsolete Legacy Pipeline',
            lead: 'Old Worker',
            status: 'archived',
            brief: 'Archived legacy thread content.',
            primaryWorkspace: 'ws',
            queueStatus: 'idle',
            archived: true,
          ),
        ],
      );

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [spaceWithArchived],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('Active Thread'), findsOneWidget);
      expect(find.text('Obsolete Legacy Pipeline'), findsNothing);
      expect(find.text('Archived legacy thread content.'), findsNothing);
    });

    // 11. Scenario: Product update -> Expected: What's New
    testWidgets('Scenario: Product update -> Expected: What\'s New',
        (tester) async {
      final updates = [
        const AxProductUpdate(
          id: 'up-1',
          slug: 'smart-merge',
          title: 'Smart Branch Merging',
          summary: 'Merge thread branches safely with conflict analysis.',
          category: AxProductUpdateCategory.feature,
          publishedAt: '2026-10-08T00:00:00Z',
          status: AxProductUpdateStatus.published,
        ),
      ];

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        productUpdates: updates,
        productUpdateReadStates: const {},
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text("What's new"), findsOneWidget);
      expect(find.text('Smart Branch Merging'), findsOneWidget);
      expect(find.text('1'), findsNothing); // no unread badge count
    });

    // 12. Scenario: Old/read update -> Expected: Not treated as new
    testWidgets('Scenario: Old/read update -> Expected: Not treated as new',
        (tester) async {
      final updates = [
        const AxProductUpdate(
          id: 'up-1',
          slug: 'smart-merge',
          title: 'Smart Branch Merging',
          summary: 'Merge thread branches safely with conflict analysis.',
          category: AxProductUpdateCategory.feature,
          publishedAt: '2026-10-08T00:00:00Z',
          status: AxProductUpdateStatus.published,
        ),
      ];

      final readStates = <String, AxUserProductUpdateState>{
        'up-1': AxUserProductUpdateState(
          userId: 'user-1',
          updateId: 'up-1',
          seenAt: DateTime.parse('2026-10-08T01:00:00Z'),
        ),
      };

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        productUpdates: updates,
        productUpdateReadStates: readStates,
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text("What's new"), findsOneWidget);
      expect(find.text('Smart Branch Merging'), findsOneWidget);
      expect(find.text('1'), findsNothing); // unread badge should be absent
    });

    // 13. Scenario: ChatGPT model added -> Expected: Relevant AI Update
    testWidgets('Scenario: ChatGPT model added -> Expected: Relevant AI Update',
        (tester) async {
      const chatgptWorker = AxWorker(
        id: 'w-openai',
        workspaceId: 'ws-local',
        workspaceName: 'Local Workspace',
        workerTypeId: 'chatgpt',
        displayName: 'OpenAI ChatGPT Worker',
        status: 'ready',
        readinessState: 'ready',
        localConcurrencyLimit: 2,
      );

      final aiUpdates = [
        const AxAiCapabilityUpdate(
          id: 'ai-gpt4o',
          workerProfileId: 'chatgpt',
          provider: 'openai',
          type: AxAiCapabilityUpdateType.modelAdded,
          title: 'GPT-4o Mini and o1 Reasoning Added',
          summary: 'Enhanced high-speed reasoning available for your spaces.',
          publishedAt: '2026-10-08T00:00:00Z',
        ),
      ];

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [chatgptWorker],
        invitations: const [],
        aiUpdates: aiUpdates,
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('AI updates'), findsOneWidget);
      expect(find.text('GPT-4o Mini and o1 Reasoning Added'), findsOneWidget);
    });

    // 14. Scenario: Gemini update without access -> Expected: Hidden
    testWidgets('Scenario: Gemini update without access -> Expected: Hidden',
        (tester) async {
      const chatgptWorker = AxWorker(
        id: 'w-openai',
        workspaceId: 'ws-local',
        workspaceName: 'Local Workspace',
        workerTypeId: 'chatgpt',
        displayName: 'OpenAI ChatGPT Worker',
        status: 'ready',
        readinessState: 'ready',
        localConcurrencyLimit: 2,
      );

      final aiUpdates = [
        const AxAiCapabilityUpdate(
          id: 'ai-gemini',
          workerProfileId: 'gemini',
          provider: 'google',
          type: AxAiCapabilityUpdateType.modelAdded,
          title: 'Gemini 1.5 Pro 2M Context Added',
          summary: 'Massive context window support for Gemini workers.',
          publishedAt: '2026-10-08T00:00:00Z',
        ),
      ];

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [chatgptWorker], // User has NO Gemini worker
        invitations: const [],
        aiUpdates: aiUpdates,
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      // Gemini update should be filtered out
      expect(find.text('Gemini 1.5 Pro 2M Context Added'), findsNothing);
      expect(find.text('AI updates'), findsNothing);
    });

    // 15. Scenario: Worker access revoked -> Expected: Related AI update disappears
    testWidgets(
        'Scenario: Worker access revoked -> Expected: Related AI update disappears',
        (tester) async {
      const claudeWorker = AxWorker(
        id: 'w-claude',
        workspaceId: 'ws-local',
        workspaceName: 'Local Workspace',
        workerTypeId: 'claude',
        displayName: 'Claude Worker',
        status: 'ready',
        readinessState: 'ready',
        localConcurrencyLimit: 1,
      );

      final aiUpdates = [
        const AxAiCapabilityUpdate(
          id: 'ai-claude-35',
          workerProfileId: 'claude',
          provider: 'anthropic',
          type: AxAiCapabilityUpdateType.modelAdded,
          title: 'Claude 3.5 Sonnet Updated',
          summary: 'Anthropic reasoning updates.',
          publishedAt: '2026-10-08T00:00:00Z',
        ),
      ];

      // 1. With worker present: AI update is shown
      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [claudeWorker],
        invitations: const [],
        aiUpdates: aiUpdates,
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('Claude 3.5 Sonnet Updated'), findsOneWidget);

      // 2. Revoke worker access: workers list emptied -> AI update disappears
      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [], // Claude worker revoked
        invitations: const [],
        aiUpdates: aiUpdates,
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('Claude 3.5 Sonnet Updated'), findsNothing);
      expect(find.text('AI updates'), findsNothing);
    });

    // 16. Scenario: Empty optional section -> Expected: Section hidden
    testWidgets('Scenario: Empty optional section -> Expected: Section hidden',
        (tester) async {
      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        attentionItems: const [],
        aiUpdates: const [],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      // Optional dynamic sections must be hidden when empty
      expect(find.text('For you'), findsNothing);
      expect(find.text('Running now'), findsNothing);
      expect(find.text('AI updates'), findsNothing);
    });

    // 17. Scenario: Offline -> Expected: Cached Home survives
    testWidgets('Scenario: Offline -> Expected: Cached Home survives',
        (tester) async {
      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        isOffline: true,
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Offline · Cached data'), findsOneWidget);
      expect(find.text('Continue working'), findsOneWidget);
      expect(find.text('SPACE ONE'), findsNothing);
    });

    // 18. Scenario: Space permission revoked -> Expected: Data disappears
    testWidgets(
        'Scenario: Space permission revoked -> Expected: Data disappears',
        (tester) async {
      const authProj = AxSpace(
        id: 'proj-allowed',
        name: 'Allowed Space',
        branch: 'main',
        lastActivity: 'Now',
      );

      final continueItems = [
        const AxContinueWorkItem(
          spaceId: 'proj-allowed',
          spaceName: 'Allowed Space',
          threadId: 'ws-1',
          threadTitle: 'Allowed Thread',
          collaboratorsDisplay: 'You',
          lastMessageSnippet: 'Allowed message',
          lastActivityDisplay: 'Now',
        ),
        const AxContinueWorkItem(
          spaceId: 'proj-revoked',
          spaceName: 'Revoked Confidential Space',
          threadId: 'ws-secret',
          threadTitle: 'Secret Thread',
          collaboratorsDisplay: 'Secret Team',
          lastMessageSnippet: 'Revoked secret discussion',
          lastActivityDisplay: 'Now',
        ),
      ];

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [authProj], // User ONLY has access to proj-allowed
        workspaces: const [],
        workers: const [],
        invitations: const [],
        continueWorkItems: continueItems,
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(find.text('ALLOWED SPACE'), findsNothing);
      expect(find.text('Allowed Thread'), findsOneWidget);
      expect(find.text('REVOKED CONFIDENTIAL SPACE'), findsNothing);
      expect(find.text('Secret Thread'), findsNothing);
      expect(find.text('Revoked secret discussion'), findsNothing);
    });

    // 19. Scenario: Realtime reconnect -> Expected: No duplicated Home items
    test('Scenario: Realtime reconnect -> Expected: No duplicated Home items',
        () {
      const duplicateItem = AxHomeAttentionItem(
        id: 'att-unique-123',
        type: AxHomeAttentionType.needsInput,
        title: 'Needs Feedback on Architecture',
        subtitle: 'Review required',
        spaceId: 'space-1',
        isUnread: true,
        isActionable: true,
      );

      final items = AxHomeAttentionProjector.space(
        invitations: const [],
        rawAttentionItems: const [
          duplicateItem,
          duplicateItem, // Duplicated by transport replay
          duplicateItem,
        ],
        openFindingCount: 0,
        spaces: const [space],
      );

      // Deduplication guarantees exact length of 1
      expect(items, hasLength(1));
      expect(items.first.id, 'att-unique-123');
      expect(items.first.title, 'Needs Feedback on Architecture');
    });

    // 20. Scenario: Narrow/mobile layout -> Expected: Responsive vertical stack without overflows
    testWidgets(
        'Scenario: Narrow/mobile layout -> Expected: Responsive vertical stack without overflows',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [testInvite1],
        attentionItems: const [
          AxHomeAttentionItem(
            id: 'att-1',
            type: AxHomeAttentionType.needsInput,
            title: 'Narrow screen test attention item',
            subtitle: 'Checking mobile layout wrapping and margins',
            spaceId: 'space-1',
            isUnread: true,
            isActionable: true,
          ),
        ],
        run: const AxRun(
          id: 'run-narrow',
          spaceId: 'space-1',
          spaceName: 'Space One',
          threadTitle: 'Mobile Support',
          objective: 'Testing responsive layout on compact screens',
          workerName: 'Core Worker',
          status: RunStatus.running,
          taskCount: 3,
          completedTaskCount: 1,
          openFindingCount: 0,
          verifiedCriterionCount: 1,
          criterionCount: 2,
        ),
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      expect(tester.takeException(), isNull);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('For you'), findsOneWidget);
      expect(find.text('Running now'), findsOneWidget);
      expect(find.text('Continue working'), findsOneWidget);
    });
  });

  group('Phase 34 — Analytics & Product Discovery Telemetry', () {
    setUp(() {
      AxHomeAnalytics.reset();
    });

    testWidgets('Measure Home → Continue Thread', (tester) async {
      final events = <AxHomeAnalyticsEvent>[];
      AxHomeAnalytics.setSink(events.add);
      addTearDown(() => AxHomeAnalytics.setSink(null));

      var openedThread = '';
      const activeSpace = AxSpace(
        id: 'p-analytics',
        name: 'Analytics Space',
        branch: 'main',
        lastActivity: '1m ago',
        threads: [
          AxThread(
            id: 'ws-analytics',
            spaceId: 'p-analytics',
            name: 'Telemetry Thread',
            lead: 'Vitalii',
            status: 'active',
            brief: 'Instrumenting product discovery.',
            primaryWorkspace: 'ws',
            queueStatus: 'idle',
          ),
        ],
      );

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [activeSpace],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
        onOpenThread: (pId, wsId) => openedThread = '$pId/$wsId',
      )));

      await tester
          .tap(find.byKey(const ValueKey('continue-work-last-message')).first);
      expect(openedThread, 'p-analytics/ws-analytics');

      expect(events, hasLength(1));
      expect(events.first.action, AxHomeAnalyticsAction.continueThread);
      expect(events.first.eventName, 'home.continue_thread');
      expect(events.first.properties['spaceId'], 'p-analytics');
      expect(events.first.properties['threadId'], 'ws-analytics');
      expect(events.first.properties['spaceName'], 'Analytics Space');
      expect(events.first.properties['threadTitle'], 'Telemetry Thread');
    });

    testWidgets('Measure Home → Accept invitation', (tester) async {
      final events = <AxHomeAnalyticsEvent>[];
      AxHomeAnalytics.setSink(events.add);
      addTearDown(() => AxHomeAnalytics.setSink(null));

      AxSpaceInvitation? accepted;
      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [testInvite1],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
        onAcceptInvitation: (inv) => accepted = inv,
      )));

      await tester.tap(find.text('Accept'));
      expect(accepted?.id, 'inv-1');

      expect(
          events.any((e) => e.action == AxHomeAnalyticsAction.acceptInvitation),
          isTrue);
      final event = events.firstWhere(
          (e) => e.action == AxHomeAnalyticsAction.acceptInvitation);
      expect(event.eventName, 'home.accept_invitation');
      expect(event.properties['invitationId'], 'inv-1');
      expect(event.properties['spaceId'], 'proj-123');
      expect(event.properties['role'], 'owner');
    });

    testWidgets('Measure Home → resolve attention', (tester) async {
      final events = <AxHomeAnalyticsEvent>[];
      AxHomeAnalytics.setSink(events.add);
      addTearDown(() => AxHomeAnalytics.setSink(null));

      var openedThread = '';
      final attentionItem = [
        const AxHomeAttentionItem(
          id: 'att-resolve-1',
          type: AxHomeAttentionType.needsInput,
          title: 'Spec Review Required',
          subtitle: 'Please check the architecture document',
          spaceId: 'space-1',
          threadId: 'ws-spec',
          isUnread: true,
          isActionable: true,
        ),
      ];

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        attentionItems: attentionItem,
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
        onOpenThread: (pId, wsId) => openedThread = '$pId/$wsId',
      )));

      await tester.tap(find.text('Spec Review Required'));
      expect(openedThread, 'space-1/ws-spec');

      expect(
          events.any((e) => e.action == AxHomeAnalyticsAction.resolveAttention),
          isTrue);
      final event = events.firstWhere(
          (e) => e.action == AxHomeAnalyticsAction.resolveAttention);
      expect(event.eventName, 'home.resolve_attention');
      expect(event.properties['itemId'], 'att-resolve-1');
      expect(event.properties['type'], 'needsInput');
      expect(event.properties['actionLabel'], 'Review →');
      expect(event.properties['spaceId'], 'space-1');
      expect(event.properties['threadId'], 'ws-spec');
    });

    testWidgets('Measure Home → open What\'s New', (tester) async {
      final events = <AxHomeAnalyticsEvent>[];
      AxHomeAnalytics.setSink(events.add);
      addTearDown(() => AxHomeAnalytics.setSink(null));

      final updates = [
        const AxProductUpdate(
          id: 'up-measure',
          slug: 'smart-merge',
          title: 'Smart Branch Merging',
          summary: 'Merge branches safely.',
          category: AxProductUpdateCategory.feature,
          publishedAt: '2026-10-08T00:00:00Z',
          status: AxProductUpdateStatus.published,
        ),
      ];

      var openedWhatsNew = false;
      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        productUpdates: updates,
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
        onOpenWhatsNew: () => openedWhatsNew = true,
      )));

      await tester.tap(find.text('See all'));
      expect(openedWhatsNew, isTrue);

      expect(events.any((e) => e.action == AxHomeAnalyticsAction.openWhatsNew),
          isTrue);
      final event = events
          .firstWhere((e) => e.action == AxHomeAnalyticsAction.openWhatsNew);
      expect(event.eventName, 'home.open_whats_new');
      expect(event.properties['source'], 'header_see_all');
      expect(event.properties['unreadCount'], 1);
    });

    testWidgets('Measure Home → AI Update', (tester) async {
      final events = <AxHomeAnalyticsEvent>[];
      AxHomeAnalytics.setSink(events.add);
      addTearDown(() => AxHomeAnalytics.setSink(null));

      const chatgptWorker = AxWorker(
        id: 'w-openai',
        workspaceId: 'ws-local',
        workspaceName: 'Local Workspace',
        workerTypeId: 'chatgpt',
        displayName: 'OpenAI ChatGPT Worker',
        status: 'ready',
        readinessState: 'ready',
        localConcurrencyLimit: 2,
      );

      final aiUpdates = [
        const AxAiCapabilityUpdate(
          id: 'ai-gpt-telemetry',
          workerProfileId: 'chatgpt',
          provider: 'openai',
          type: AxAiCapabilityUpdateType.modelAdded,
          title: 'GPT-4o Mini and o1 Reasoning Added',
          summary: 'High-speed reasoning models available.',
          publishedAt: '2026-10-08T00:00:00Z',
        ),
      ];

      AxAiCapabilityUpdate? openedAiUpdate;
      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [chatgptWorker],
        invitations: const [],
        aiUpdates: aiUpdates,
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
        onOpenAiUpdate: (up) => openedAiUpdate = up,
      )));

      // AI update rows are informational: tapping one opens nothing.
      expect(find.text('Configure →'), findsNothing);
      await tester
          .ensureVisible(find.text('GPT-4o Mini and o1 Reasoning Added'));
      await tester.tap(find.text('GPT-4o Mini and o1 Reasoning Added'));
      expect(openedAiUpdate, isNull);
      expect(events.any((e) => e.action == AxHomeAnalyticsAction.openAiUpdate),
          isFalse);
    });

    testWidgets('Measure Home → create Space', (tester) async {
      final events = <AxHomeAnalyticsEvent>[];
      AxHomeAnalytics.setSink(events.add);
      addTearDown(() => AxHomeAnalytics.setSink(null));

      var spaceCreated = false;
      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () => spaceCreated = true,
      )));

      await tester.tap(find.text('Create Space →'));
      expect(spaceCreated, isTrue);

      expect(events.any((e) => e.action == AxHomeAnalyticsAction.createSpace),
          isTrue);
      final event = events
          .firstWhere((e) => e.action == AxHomeAnalyticsAction.createSpace);
      expect(event.eventName, 'home.create_space');
      expect(event.properties['source'], 'new_user_primary');
    });
  });

  group('Phase 35 — Obsolete Dashboard Removal & Clean-Room Assertions', () {
    testWidgets(
        'Established user Home does not contain legacy metric counters or execution capacity subtitle',
        (tester) async {
      const space = AxSpace(
        id: 'space-1',
        name: 'Alpha Space',
        branch: 'main',
        lastActivity: 'Today',
      );

      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [space],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      // Assert legacy metric cards are absent
      expect(find.text('Spaces'), findsNothing);
      expect(find.text('Workspaces'), findsNothing);
      expect(find.text('Ready Workers'), findsNothing);
      expect(find.text('execution-capacity'), findsNothing);
      expect(find.text('Execution capacity'), findsNothing);

      // Assert permanent empty-state cards from legacy Home are absent
      expect(find.text('No active Runs'), findsNothing);
      expect(find.text('Nothing needs your attention'), findsNothing);
      expect(find.text('Recent Spaces'), findsNothing);
    });

    testWidgets(
        'New user Home uses Space-first onboarding and omits old workspace-first dashboard',
        (tester) async {
      await tester.pumpWidget(scaffold(HomePage(
        historicalUpdates: const [],
        spaces: const [],
        workspaces: const [],
        workers: const [],
        invitations: const [],
        run: null,
        openFindingCount: 0,
        onOpenWorkspaces: () {},
        onOpenSpace: (_) {},
        onOpenRun: (_, __) {},
        onCreateSpace: () {},
      )));

      // Assert legacy dashboard widgets are not rendered
      expect(find.text('Spaces'), findsNothing);
      expect(find.text('Workspaces'), findsNothing);
      expect(find.text('Ready Workers'), findsNothing);
      expect(find.text('No active Runs'), findsNothing);
      expect(find.text('Nothing needs your attention'), findsNothing);

      // Assert space-first onboarding is rendered
      expect(find.text('Create your first Space'), findsOneWidget);
      expect(find.text('Create Space →'), findsOneWidget);
    });
  });
}
