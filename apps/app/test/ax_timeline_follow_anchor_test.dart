import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';
import 'package:syntila_app/src/ax/sync/ax_discussion_cache.dart';
import 'package:syntila_app/src/ax/sync/ax_work_history.dart';
import 'package:syntila_app/src/ax/sync/persistence/ax_thread_view_state.dart';
import 'package:syntila_app/src/ax/sync/persistence/ax_thread_view_state_store_base.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'package:syntila_app/src/features/spaces/timeline_follow_anchor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('inactive anchor falls back until it can be mounted again',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final anchor = AxTimelineFollowAnchor();
    var retry = false;
    Widget view(bool visible) => MaterialApp(
          home: ListView(controller: controller, children: [
            const SizedBox(height: 1000),
            if (visible)
              _DeactivationProbe(
                key: anchor.keyFor('incoming'),
                onDeactivate: () => retry = anchor.reveal(controller),
              ),
          ]),
        );
    await tester.pumpWidget(view(false));
    anchor.observe('incoming', controller);
    await tester.pumpWidget(view(true));
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.pumpWidget(view(false));
    expect(tester.takeException(), isNull);
    expect(retry, isTrue);
  });

  testWidgets('anchorAt reveals the last-seen item at the top and releases',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final anchor = AxTimelineFollowAnchor();
    Widget view() => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: ListView(controller: controller, children: [
                for (var i = 0; i < 20; i++)
                  SizedBox(
                      key: anchor.keyFor('m$i'),
                      height: 100,
                      child: Text('m$i')),
              ]),
            ),
          ),
        );
    await tester.pumpWidget(view());
    anchor.anchorAt('m12', fraction: 0.6);
    await tester.pumpWidget(view());
    // The unmounted row is first approached by estimate, then revealed.
    while (anchor.reveal(controller)) {
      await tester.pump();
    }
    expect(controller.offset, 1200);
    // Released: a later arrival may anchor again.
    anchor.observe('m19', controller);
    expect(anchor.keyFor('m19'), isNotNull);
  });

  for (final nestedResponse in [false, true]) {
    testWidgets(
        '${nestedResponse ? 'Work response' : 'Chat message'} reveals its beginning and preserves it during growth',
        (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final anchor = AxTimelineFollowAnchor();
      var height = 0.0;
      var extraMessage = false;
      final firstNew = nestedResponse ? ('request', 'response') : 'new-message';
      Widget view() => MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  height: 300,
                  child: AxTimelineContainer(
                    scrollKey: const ValueKey('history'),
                    controller: controller,
                    itemCount: nestedResponse
                        ? 1
                        : 10 + (height > 0 ? 1 : 0) + (extraMessage ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (nestedResponse) {
                        return Column(children: [
                          const SizedBox(
                              height: 700, child: Text('Request and activity')),
                          if (height > 0)
                            SizedBox(
                              key: anchor.keyFor(firstNew),
                              height: height,
                              child: const Align(
                                  alignment: Alignment.topLeft,
                                  child: Text('Opening line')),
                            ),
                          if (extraMessage) const SizedBox(height: 900),
                        ]);
                      }
                      if (index < 10) {
                        return SizedBox(height: 70, child: Text('Old $index'));
                      }
                      if (index == 10) {
                        return SizedBox(
                          key: anchor.keyFor(firstNew),
                          height: height,
                          child: const Align(
                              alignment: Alignment.topLeft,
                              child: Text('Opening line')),
                        );
                      }
                      return const SizedBox(
                          height: 900, child: Text('Later message'));
                    },
                  ),
                ),
              ),
            ),
          );
      Future<void> reveal() async {
        for (var attempt = 0; attempt < 4; attempt++) {
          if (!anchor.reveal(controller)) break;
          await tester.pump();
        }
        await tester.pump();
      }

      await tester.pumpWidget(view());
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      anchor.observe(firstNew, controller);
      height = 1200;
      await tester.pumpWidget(view());
      await reveal();
      final viewport = tester.getRect(find.byKey(const ValueKey('history')));
      expect(tester.getTopLeft(find.text('Opening line')).dy,
          closeTo(viewport.top, 1));
      expect(controller.position.extentAfter, greaterThan(500));
      anchor.observe('later-message', controller);
      height = 1800;
      extraMessage = true;
      await tester.pumpWidget(view());
      await reveal();
      expect(tester.getTopLeft(find.text('Opening line')).dy,
          closeTo(viewport.top, 1));
      expect(controller.position.extentAfter, greaterThan(1000));
    });
  }
  testWidgets('ThreadPage holds a long Work answer at its first line',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chat = AxDiscussionCache(null);
    final work = AxWorkHistoryCache(null);
    AxWorkRequest request(String id, {String? response, String? prompt}) =>
        AxWorkRequest(
          id: id,
          requestedByName: 'You',
          prompt: prompt ?? 'Prompt $id',
          workflowId: 'direct',
          workflowVersion: 2,
          status: response == null ? 'running' : 'completed',
          createdAt: '2026-10-15T00:0${id.length}:00.000Z',
          steps: const [],
          finalText: response,
        );
    final earlier = [
      for (var i = 0; i < 8; i++)
        request('r$i', response: 'Earlier answer $i\n\n${'Line.\n\n' * 6}')
    ];
    chat.engine.update(chat.query('thread'),
        (_) => AxDiscussionHistory(messages: const [], initialLoaded: true));
    work.engine.update(
        work.query('thread'),
        (_) => AxWorkHistory(
            requests: [...earlier, request('latest')], initialLoaded: true));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'space', name: 'Space', branch: '', lastActivity: ''),
      thread: const AxThread(
          id: 'thread',
          spaceId: 'space',
          name: 'Thread',
          lead: '',
          status: 'active',
          brief: '',
          queueStatus: ''),
      discussionCache: chat,
      workHistoryCache: work,
      onBackToSpace: () {},
      onArchive: () {},
    ))));
    await tester.pumpAndSettle();
    final history = find.byKey(const ValueKey('chat-history-scroll'));
    final controller = tester.widget<CustomScrollView>(history).controller!;
    expect(controller.position.extentAfter, lessThan(1));

    final longWork =
        'Answer opening\n\n${List.filled(80, 'Answer body paragraph.').join('\n\n')}';
    work.replace('thread', [...earlier, request('latest', response: longWork)]);
    await tester.pumpAndSettle();
    // The answer starts at the top of the view instead of its last line.
    final viewport = tester.getRect(history);
    final opening = find.descendant(
        of: history,
        matching: find.textContaining('Answer opening', findRichText: true));
    expect(opening, findsOneWidget);
    expect(tester.getTopLeft(opening).dy,
        inInclusiveRange(viewport.top - 1, viewport.top + 120));
    expect(controller.position.extentAfter, greaterThan(500));
    await tester.pumpWidget(const SizedBox());
    chat.clear();
    work.clear();
  });

  testWidgets(
      'ThreadPage holds a long answer to your own request at its first line',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chat = AxDiscussionCache(null);
    final work = AxWorkHistoryCache(null);
    AxWorkRequest request(String id, {String? response}) => AxWorkRequest(
          id: id,
          requestedByName: 'You',
          requestedByUserId: 'me',
          prompt: 'Prompt $id',
          workflowId: 'direct',
          workflowVersion: 2,
          status: response == null ? 'running' : 'completed',
          createdAt: '2026-10-15T00:0${id.length}:00.000Z',
          steps: const [],
          finalText: response,
        );
    final earlier = [
      for (var i = 0; i < 8; i++)
        request('r$i', response: 'Earlier answer $i\n\n${'Line.\n\n' * 6}')
    ];
    chat.engine.update(chat.query('thread'),
        (_) => AxDiscussionHistory(messages: const [], initialLoaded: true));
    work.engine.update(work.query('thread'),
        (_) => AxWorkHistory(requests: earlier, initialLoaded: true));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'space', name: 'Space', branch: '', lastActivity: ''),
      thread: const AxThread(
          id: 'thread',
          spaceId: 'space',
          name: 'Thread',
          lead: '',
          status: 'active',
          brief: '',
          queueStatus: ''),
      discussionCache: chat,
      workHistoryCache: work,
      onBackToSpace: () {},
      onArchive: () {},
      currentUserId: 'me',
    ))));
    await tester.pumpAndSettle();
    final history = find.byKey(const ValueKey('chat-history-scroll'));
    final controller = tester.widget<CustomScrollView>(history).controller!;
    expect(controller.position.extentAfter, lessThan(1));

    work.replace('thread', [...earlier, request('latest')]);
    await tester.pumpAndSettle();
    expect(controller.position.extentAfter, lessThan(1));
    final longWork =
        'Answer opening\n\n${List.filled(80, 'Answer body paragraph.').join('\n\n')}';
    work.replace('thread', [...earlier, request('latest', response: longWork)]);
    await tester.pumpAndSettle();
    // The answer starts at the top of the view instead of its last line.
    final viewport = tester.getRect(history);
    final opening = find.descendant(
        of: history,
        matching: find.textContaining('Answer opening', findRichText: true));
    expect(opening, findsOneWidget);
    expect(tester.getTopLeft(opening).dy,
        inInclusiveRange(viewport.top - 1, viewport.top + 120));
    expect(controller.position.extentAfter, greaterThan(500));
    // Rows settling height without new data, such as text rewrapping in a
    // narrower window, keep the held answer's first line in view.
    await tester.binding.setSurfaceSize(const Size(700, 800));
    await tester.pumpAndSettle();
    expect(
        tester.getTopLeft(opening).dy,
        inInclusiveRange(tester.getRect(history).top - 1,
            tester.getRect(history).top + 120));
    await tester.pumpWidget(const SizedBox());
    chat.clear();
    work.clear();
  });

  testWidgets(
      'ThreadPage reveals incoming Chat from its sender line and respects manual scrolling',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chat = AxDiscussionCache(null);
    final work = AxWorkHistoryCache(null);
    AxDiscussionMessage message(String id, String body) => AxDiscussionMessage(
          id: id,
          threadId: 'thread',
          authorUserId: 'other',
          body: body,
          createdAt: id.startsWith('old-')
              ? '2026-10-15T00:00:00.000Z'
              : '2026-10-15T00:01:00.000Z',
        );
    AxWorkRequest request({String? response}) => AxWorkRequest(
          id: 'request',
          requestedByName: 'You',
          prompt: 'A short request',
          workflowId: 'direct',
          workflowVersion: 2,
          status: 'completed',
          createdAt: '2026-10-15T00:00:00.000Z',
          steps: const [],
          finalText: response,
        );
    final old = List.generate(
        15, (index) => message('old-$index', 'Earlier message $index'));
    chat.engine.update(chat.query('thread'),
        (_) => AxDiscussionHistory(messages: old, initialLoaded: true));
    work.engine.update(work.query('thread'),
        (_) => AxWorkHistory(requests: [request()], initialLoaded: true));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'space', name: 'Space', branch: '', lastActivity: ''),
      thread: const AxThread(
          id: 'thread',
          spaceId: 'space',
          name: 'Thread',
          lead: '',
          status: 'active',
          brief: '',
          queueStatus: ''),
      discussionCache: chat,
      workHistoryCache: work,
      onBackToSpace: () {},
      onArchive: () {},
    ))));
    await tester.pumpAndSettle();
    final longChat =
        'Chat opening\n\n${List.filled(80, 'Chat body paragraph.').join('\n\n')}';
    chat.engine.update(
        chat.query('thread'),
        (_) => AxDiscussionHistory(
            messages: [...old, message('incoming', longChat)],
            initialLoaded: true));
    await tester.pumpAndSettle();
    // A reader at the latest content sees a long arrival from its sender
    // line rather than its last paragraph.
    {
      final history = find.byKey(const ValueKey('chat-history-scroll'));
      final controller = tester.widget<CustomScrollView>(history).controller!;
      expect(controller.position.extentAfter, greaterThan(100));
      final opening = find.descendant(
          of: history,
          matching: find.textContaining('Chat opening', findRichText: true));
      expect(opening, findsOneWidget);
      final top = tester.getTopLeft(history).dy;
      expect(tester.getTopLeft(opening).dy, greaterThan(top));
      expect(tester.getTopLeft(opening).dy, lessThan(top + 120));
    }
    final history = find.byKey(const ValueKey('chat-history-scroll'));
    await tester.drag(history, const Offset(0, 150));
    await tester.pumpAndSettle();
    final controller = tester.widget<CustomScrollView>(history).controller!;
    final readingOffset = controller.offset;
    chat.engine.update(
        chat.query('thread'),
        (_) => AxDiscussionHistory(messages: [
              ...old,
              message('incoming', longChat),
              message('later', 'Later Chat')
            ], initialLoaded: true));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(readingOffset, 1));
    await tester.pumpWidget(const SizedBox());
    chat.clear();
    work.clear();
  });

  testWidgets(
      'opening a Thread with unread messages starts at the first unread sender line',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chat = AxDiscussionCache(null);
    final work = AxWorkHistoryCache(null);
    final store = MemoryAxThreadViewStateStore();
    AxDiscussionMessage message(int minute, String id, String body) =>
        AxDiscussionMessage(
          id: id,
          threadId: 'thread',
          authorUserId: 'other',
          authorName: 'Dana',
          body: body,
          createdAt: '2026-10-15T00:${'$minute'.padLeft(2, '0')}:00.000Z',
        );
    final paragraphs = List.filled(80, 'Unread body paragraph.').join('\n\n');
    chat.engine.update(
        chat.query('thread'),
        (_) => AxDiscussionHistory(messages: [
              for (var i = 0; i < 15; i++) message(i, 'old-$i', 'Earlier $i'),
              message(20, 'unread-1', 'Unread opening\n\n$paragraphs'),
              message(21, 'unread-2', 'Second unread'),
            ], initialLoaded: true));
    work.engine.update(work.query('thread'),
        (_) => AxWorkHistory(requests: const [], initialLoaded: true));
    await store.save(
        userId: 'me',
        threadId: 'thread',
        state: const AxThreadViewState(chatSeenId: 'old-14'));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'space', name: 'Space', branch: '', lastActivity: ''),
      thread: const AxThread(
          id: 'thread',
          spaceId: 'space',
          name: 'Thread',
          lead: '',
          status: 'active',
          brief: '',
          queueStatus: ''),
      currentUserId: 'me',
      threadViewStateStore: store,
      discussionCache: chat,
      workHistoryCache: work,
      onBackToSpace: () {},
      onArchive: () {},
    ))));
    await tester.pumpAndSettle();
    final history = find.byKey(const ValueKey('chat-history-scroll'));
    final controller = tester.widget<CustomScrollView>(history).controller!;
    expect(controller.position.extentAfter, greaterThan(100));
    final opening = find.descendant(
        of: history,
        matching: find.textContaining('Unread opening', findRichText: true));
    expect(opening, findsOneWidget);
    final top = tester.getTopLeft(history).dy;
    expect(tester.getTopLeft(opening).dy, greaterThan(top));
    expect(tester.getTopLeft(opening).dy, lessThan(top + 120));
    await tester.pumpWidget(const SizedBox());
    chat.clear();
    work.clear();
  });

  for (final lateArrival in [false, true]) {
    testWidgets(
        'switching to a Thread with unread messages starts at the first unread '
        '(late arrival: $lateArrival)', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1300, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final chat = AxDiscussionCache(null);
      final work = AxWorkHistoryCache(null);
      final store = MemoryAxThreadViewStateStore();
      AxDiscussionMessage message(
              String thread, int minute, String id, String body) =>
          AxDiscussionMessage(
            id: id,
            threadId: thread,
            authorUserId: 'other',
            authorName: 'Dana',
            body: body,
            createdAt: '2026-10-15T00:${'$minute'.padLeft(2, '0')}:00.000Z',
          );
      final paragraphs = List.filled(80, 'Unread body paragraph.').join('\n\n');
      final oldB = [
        for (var i = 0; i < 15; i++) message('b', i, 'b-old-$i', 'Earlier $i')
      ];
      final unreadB = [
        ...oldB,
        message('b', 20, 'b-unread-1', 'Unread opening\n\n$paragraphs'),
        message('b', 21, 'b-unread-2', 'Second unread'),
      ];
      for (final thread in ['a', 'b']) {
        work.engine.update(work.query(thread),
            (_) => AxWorkHistory(requests: const [], initialLoaded: true));
      }
      chat.engine.update(
          chat.query('a'),
          (_) => AxDiscussionHistory(messages: [
                for (var i = 0; i < 15; i++) message('a', i, 'a-$i', 'A $i')
              ], initialLoaded: true));
      chat.engine.update(
          chat.query('b'),
          (_) => AxDiscussionHistory(
              messages: lateArrival ? oldB : unreadB, initialLoaded: true));
      await store.save(
          userId: 'me',
          threadId: 'b',
          state: const AxThreadViewState(chatSeenId: 'b-old-14'));
      Widget page(String id) => MaterialApp(
              home: Scaffold(
                  body: ThreadPage(
            space: const AxSpace(
                id: 'space', name: 'Space', branch: '', lastActivity: ''),
            thread: AxThread(
                id: id,
                spaceId: 'space',
                name: 'Thread $id',
                lead: '',
                status: 'active',
                brief: '',
                queueStatus: ''),
            currentUserId: 'me',
            threadViewStateStore: store,
            discussionCache: chat,
            workHistoryCache: work,
            onBackToSpace: () {},
            onArchive: () {},
          )));
      await tester.pumpWidget(page('a'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(page('b'));
      await tester.pumpAndSettle();
      if (lateArrival) {
        chat.engine.update(chat.query('b'),
            (_) => AxDiscussionHistory(messages: unreadB, initialLoaded: true));
        await tester.pumpAndSettle();
      }
      final history = find.byKey(const ValueKey('chat-history-scroll'));
      final controller = tester.widget<CustomScrollView>(history).controller!;
      expect(controller.position.extentAfter, greaterThan(100));
      final opening = find.descendant(
          of: history,
          matching: find.textContaining('Unread opening', findRichText: true));
      expect(opening, findsOneWidget);
      final top = tester.getTopLeft(history).dy;
      expect(tester.getTopLeft(opening).dy, greaterThan(top));
      expect(tester.getTopLeft(opening).dy, lessThan(top + 120));
      await tester.pumpWidget(const SizedBox());
      chat.clear();
      work.clear();
    });
  }

  testWidgets('switching to a Thread with an unread AI answer starts at it',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chat = AxDiscussionCache(null);
    final work = AxWorkHistoryCache(null);
    final store = MemoryAxThreadViewStateStore();
    AxDiscussionMessage message(
            String thread, int minute, String id, String body) =>
        AxDiscussionMessage(
          id: id,
          threadId: thread,
          authorUserId: 'other',
          authorName: 'Dana',
          body: body,
          createdAt: '2026-10-15T00:${'$minute'.padLeft(2, '0')}:00.000Z',
        );
    final paragraphs = List.filled(80, 'Answer body paragraph.').join('\n\n');
    work.engine.update(work.query('a'),
        (_) => AxWorkHistory(requests: const [], initialLoaded: true));
    work.engine.update(
        work.query('b'),
        (_) => AxWorkHistory(requests: [
              AxWorkRequest(
                id: 'ask',
                requestedByName: 'Dana',
                prompt: 'Short question',
                workflowId: 'direct',
                workflowVersion: 2,
                status: 'completed',
                createdAt: '2026-10-15T00:20:00.000Z',
                steps: const [],
                finalText: 'Answer opening\n\n$paragraphs',
              ),
            ], initialLoaded: true));
    chat.engine.update(
        chat.query('a'),
        (_) => AxDiscussionHistory(messages: [
              for (var i = 0; i < 15; i++) message('a', i, 'a-$i', 'A $i')
            ], initialLoaded: true));
    chat.engine.update(
        chat.query('b'),
        (_) => AxDiscussionHistory(messages: [
              for (var i = 0; i < 15; i++)
                message('b', i, 'b-old-$i', 'Earlier $i')
            ], initialLoaded: true));
    await store.save(
        userId: 'me',
        threadId: 'b',
        state: const AxThreadViewState(chatSeenId: 'b-old-14'));
    Widget page(String id) => MaterialApp(
            home: Scaffold(
                body: ThreadPage(
          space: const AxSpace(
              id: 'space', name: 'Space', branch: '', lastActivity: ''),
          thread: AxThread(
              id: id,
              spaceId: 'space',
              name: 'Thread $id',
              lead: '',
              status: 'active',
              brief: '',
              queueStatus: ''),
          currentUserId: 'me',
          threadViewStateStore: store,
          discussionCache: chat,
          workHistoryCache: work,
          onBackToSpace: () {},
          onArchive: () {},
        )));
    await tester.pumpWidget(page('a'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page('b'));
    await tester.pumpAndSettle();
    final history = find.byKey(const ValueKey('chat-history-scroll'));
    final controller = tester.widget<CustomScrollView>(history).controller!;
    expect(controller.position.extentAfter, greaterThan(100));
    final opening = find.descendant(
        of: history,
        matching: find.textContaining('Answer opening', findRichText: true));
    expect(opening, findsOneWidget);
    // The unread request leads, so its prompt sits at the top and its
    // answer opens just below it.
    final question = find.descendant(
        of: history,
        matching: find.textContaining('Short question', findRichText: true));
    final top = tester.getTopLeft(history).dy;
    expect(tester.getTopLeft(question).dy, greaterThan(top));
    expect(tester.getTopLeft(question).dy, lessThan(top + 120));
    expect(tester.getTopLeft(opening).dy, lessThan(top + 400));
    await tester.pumpWidget(const SizedBox());
    chat.clear();
    work.clear();
  });

  testWidgets('short incoming messages fit fully above the composer',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final anchor = AxTimelineFollowAnchor();
    Widget view(bool incoming) => MaterialApp(
            home: Scaffold(
                body: SizedBox(
          height: 300,
          child: ListView(
              controller: controller,
              padding: EdgeInsets.zero,
              children: [
                const SizedBox(height: 700),
                if (incoming)
                  SizedBox(
                      key: anchor.keyFor('short'),
                      height: 60,
                      child: const Text('Short message')),
              ]),
        )));
    await tester.pumpWidget(view(false));
    controller.jumpTo(controller.position.maxScrollExtent);
    anchor.observe('short', controller);
    await tester.pumpWidget(view(true));
    anchor.reveal(controller);
    await tester.pump();
    expect(controller.position.extentAfter, 0);
    expect(tester.getTopLeft(find.text('Short message')).dy,
        greaterThanOrEqualTo(0));
  });
  testWidgets('a later message does not replace a short first unread anchor',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final anchor = AxTimelineFollowAnchor();
    Widget view(int incoming) => MaterialApp(
            home: Scaffold(
                body: SizedBox(
          height: 300,
          child: ListView(
              controller: controller,
              padding: EdgeInsets.zero,
              children: [
                const SizedBox(height: 700),
                if (incoming > 0)
                  SizedBox(
                      key: anchor.keyFor('first'),
                      height: 60,
                      child: const Text('First unread')),
                if (incoming > 1)
                  SizedBox(
                      key: anchor.keyFor('second'),
                      height: 600,
                      child: const Text('Second unread')),
              ]),
        )));
    await tester.pumpWidget(view(0));
    controller.jumpTo(controller.position.maxScrollExtent);
    anchor.observe('first', controller);
    await tester.pumpWidget(view(1));
    anchor.reveal(controller);
    await tester.pump();
    anchor.observe('second', controller);
    await tester.pumpWidget(view(2));
    anchor.reveal(controller);
    await tester.pump();
    expect(tester.getTopLeft(find.text('First unread')).dy, closeTo(0, 1));
  });

  testWidgets('reopening a Thread returns to where the reader left the chat',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chat = AxDiscussionCache(null);
    final work = AxWorkHistoryCache(null);
    final store = MemoryAxThreadViewStateStore();
    work.engine.update(work.query('b'),
        (_) => AxWorkHistory(requests: const [], initialLoaded: true));
    chat.engine.update(
        chat.query('b'),
        (_) => AxDiscussionHistory(messages: [
              for (var i = 0; i < 60; i++)
                AxDiscussionMessage(
                  id: 'b-$i',
                  threadId: 'b',
                  authorUserId: 'other',
                  authorName: 'Dana',
                  body: 'Message number $i',
                  createdAt: '2026-10-15T00:${'$i'.padLeft(2, '0')}:00.000Z',
                ),
            ], initialLoaded: true));
    Widget page() => MaterialApp(
            home: Scaffold(
                body: ThreadPage(
          space: const AxSpace(
              id: 'space', name: 'Space', branch: '', lastActivity: ''),
          thread: const AxThread(
              id: 'b',
              spaceId: 'space',
              name: 'Thread b',
              lead: '',
              status: 'active',
              brief: '',
              queueStatus: ''),
          currentUserId: 'me',
          threadViewStateStore: store,
          discussionCache: chat,
          workHistoryCache: work,
          onBackToSpace: () {},
          onArchive: () {},
        )));
    final history = find.byKey(const ValueKey('chat-history-scroll'));

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    var controller = tester.widget<CustomScrollView>(history).controller!;
    // At the end there is nothing to resume.
    expect(controller.position.extentAfter, lessThan(24));
    controller.jumpTo((controller.position.minScrollExtent +
            controller.position.maxScrollExtent) /
        2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final resumeId = store.loadSync(userId: 'me', threadId: 'b')?.chatResumeId;
    expect(resumeId, isNotNull);
    expect(resumeId, startsWith('b-'));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    controller = tester.widget<CustomScrollView>(history).controller!;
    expect(controller.position.extentAfter, greaterThan(100));
    final number = resumeId!.substring(2);
    final resumed = find.descendant(
        of: history,
        matching:
            find.textContaining('Message number $number', findRichText: true));
    expect(resumed, findsOneWidget);
    final top = tester.getTopLeft(history).dy;
    expect(tester.getTopLeft(resumed).dy, greaterThanOrEqualTo(top));
    expect(tester.getTopLeft(resumed).dy, lessThan(top + 120));

    // A real scroll releases the anchor; reaching the end clears the resume
    // point.
    await tester.drag(history, const Offset(0, -100));
    await tester.pump();
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(store.loadSync(userId: 'me', threadId: 'b')?.chatResumeId, isNull);
    await tester.pumpWidget(const SizedBox());
    chat.clear();
    work.clear();
  });
}

class _DeactivationProbe extends StatefulWidget {
  const _DeactivationProbe({super.key, required this.onDeactivate});
  final VoidCallback onDeactivate;

  @override
  State<_DeactivationProbe> createState() => _DeactivationProbeState();
}

class _DeactivationProbeState extends State<_DeactivationProbe> {
  @override
  void deactivate() {
    super.deactivate();
    widget.onDeactivate();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 800);
}
