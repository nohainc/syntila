import 'package:flutter/foundation.dart';
import 'dart:async';

import 'package:syntila_design/syntila_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/features/common/attachment_cards.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/ax/sync/ax_work_history.dart';

import 'ax_fixture_data.dart';
import 'conversation_turn_fixture.dart';
import 'package:syntila_app/src/features/common/syntila_markdown_body.dart';
import 'package:syntila_app/src/features/common/markdown_composer.dart';

void main() {
  tearDown(ThreadPage.resetWorkQueues);
  for (final workflow in [
    ('chat', 1, 'chat', 0),
    ('direct', 2, 'implement', 1)
  ]) {
    testWidgets('Space filters active and archived Threads at narrow widths',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const active = AxThread(
          id: 'active',
          spaceId: 'p-1',
          name: 'Active Thread',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: '');
      final archived = const AxThread(
          id: 'archived',
          spaceId: 'p-1',
          name: 'Archived Thread',
          lead: '',
          status: 'archived',
          brief: '',
          primaryWorkspace: '',
          queueStatus: '');
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: SpacePage(
        space: const AxSpace(
            id: 'p-1',
            name: 'A very long Space name that must wrap beside its actions',
            branch: '',
            lastActivity: ''),
        dataSource: _SpaceStreamsSource([active, archived]),
        onOpenThread: (_) {},
        onArchive: () {},
        onDelete: () {},
      )))));
      await tester.pumpAndSettle();
      expect(find.text('Active Thread'), findsOneWidget);
      expect(find.text('Archived Thread'), findsNothing);
      expect(find.text('Restore'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('space-thread-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archived').last);
      await tester.pumpAndSettle();
      expect(find.text('Active Thread'), findsNothing);
      expect(find.text('Archived Thread'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Restore'), findsNothing);
      await tester.tap(find.byTooltip('Thread actions'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(MenuItemButton, 'Restore'), findsOneWidget);
      expect(find.widgetWithText(MenuItemButton, 'Delete'), findsOneWidget);
      expect(find.byIcon(Icons.unarchive_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.text('Rename'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('space-thread-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Active').last);
      await tester.pumpAndSettle();
      expect(find.text('Active Thread'), findsOneWidget);
      expect(find.text('Archived Thread'), findsNothing);
    });

    testWidgets('${workflow.$1} keeps run and step metadata internal',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final turn = {
        ...turnFixture().toJson(),
        'workflowId': workflow.$1,
        'workflowVersion': workflow.$2,
        'stepKind': workflow.$3,
        'modelName': 'Original Model Name',
        'catalogRevision': 'a' * 64
      };
      final request = AxWorkRequest.fromJson({
        'id': 'R',
        'conversationId': 'conversation-C',
        'requestedByName': 'You',
        'requestedByUserId': 'user-owner',
        'prompt': 'Hello from the user',
        'attachments': [
          {'kind': 'file', 'name': 'photo.jpg', 'sizeBytes': 2048},
          {'kind': 'file', 'name': 'notes.txt', 'sizeBytes': 12},
        ],
        'workflowId': workflow.$1,
        'workflowVersion': workflow.$2,
        'status': 'completed',
        'createdAt': '2026-10-07T10:00:00Z',
        'turns': [turn],
        'workflowRun': {
          'schemaVersion': 1,
          'id': 'internal-workflow-run',
          'conversationId': 'conversation-C',
          'userMessageId': 'message-user-R',
          'triggerMessageId': 'message-user-R',
          'workRequestId': 'R',
          'workflowId': workflow.$1,
          'workflowVersion': workflow.$2,
          'status': 'completed',
          'startedAt': '2026-10-07T10:00:00Z',
          'completedAt': '2026-10-07T10:01:00Z',
          'runtimeRunIds': ['internal-runtime-run'],
          'workerTurnIds': [turn['id']],
          'createdAt': 'now',
          'updatedAt': 'now',
          'stepRuns': [
            {
              'schemaVersion': 1,
              'id': 'internal-step-run',
              'workflowRunId': 'internal-workflow-run',
              'taskId': 'task-R',
              'stepId': workflow.$3,
              'role': workflow.$3,
              'workerId': 'worker-a',
              'modelId': 'model-x',
              'effort': 'medium',
              'workerSessionId': 'internal-session',
              'baseContextRevision': 0,
              'status': 'completed',
              'result': '**Recorded answer**',
              'workerTurnIds': [turn['id']]
            },
            for (final role in ['verify', 'correct'])
              {
                'schemaVersion': 1,
                'id': 'internal-$role-step',
                'workflowRunId': 'internal-workflow-run',
                'taskId': 'task-$role',
                'stepId': role,
                'role': role,
                'workerId': 'future-worker',
                'modelId': 'future-model',
                'effort': 'high',
                'workerSessionId': null,
                'baseContextRevision': 0,
                'status': 'queued',
                'result': null,
                'workerTurnIds': []
              }
          ]
        },
        'steps': [
          {
            'kind': workflow.$3,
            'status': 'completed',
            'workerId': 'worker-a',
            'workerTypeId': 'chatgpt',
            'workerDisplayName': 'ChatGPT',
            'assignmentId': turn['assignmentId'],
            'model': 'model-x',
            'reasoningEffort': 'medium'
          }
        ],
      });
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
                  space: const AxSpace(
                      id: 'space-1',
                      name: 'Space',
                      branch: '',
                      lastActivity: '',
                      role: 'owner'),
                  thread: const AxThread(
                      id: 'thread-1',
                      spaceId: 'space-1',
                      name: 'Stream',
                      lead: '',
                      status: 'active',
                      brief: '',
                      primaryWorkspace: '',
                      queueStatus: ''),
                  dataSource: _SimpleConversationDataSource(request),
                  currentUserId: 'user-owner',
                  currentUserName: 'You',
                  initialTab: 1,
                  onBackToSpace: _noop,
                  onArchive: _noop))));
      await tester.pumpAndSettle();
      await _openAiHistory(tester);
      expect(_inAiHistory(find.text('Hello from the user')), findsOneWidget);
      expect(_inAiHistory(find.byType(AttachmentCard)), findsNWidgets(2));
      expect(_inAiHistory(find.byIcon(Icons.info_outline)), findsNothing);
      expect(_inAiHistory(find.text('2.0 KB')), findsNothing);
      expect(_inAiHistory(find.text('12 B')), findsNothing);
      expect(find.text('Original Model Name'), findsWidgets);
      expect(find.text('· Medium'), findsWidgets);
      expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
      expect(
          find.byWidgetPredicate((widget) =>
              widget is Image &&
              widget.semanticLabel == 'Original Model Name icon'),
          findsWidgets);
      expect(
          tester
              .widgetList<SyntilaMarkdownBody>(find.byType(SyntilaMarkdownBody))
              .map((body) => body.data),
          contains('**Recorded answer**'));
      for (final label in [
        'Workflow run',
        'Step 1/1',
        'Execution graph',
        'Agent orchestration',
        'internal-workflow-run',
        'internal-step-run',
        'internal-runtime-run',
        'internal-session',
        'Implement'
      ]) {
        expect(find.textContaining(label), findsNothing);
      }
      expect(find.byTooltip('Report issue'), findsNothing);
    });
  }

  testWidgets('a user-cancelled request is shown as cancelled, not failed',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Send now from the queue cancels the running request; its stopped Step
    // still carries an error code.
    const step = AxWorkRequestStep(
        kind: 'implement',
        status: 'failed',
        workerId: 'worker-a',
        workerDisplayName: 'ChatGPT',
        errorCode: 'execution_failed',
        errorMessage: 'process terminated');
    const request = AxWorkRequest(
        id: 'cancelled-request',
        requestedByName: 'User',
        prompt: 'Continue',
        workflowId: 'direct',
        workflowVersion: 2,
        status: 'cancelled',
        createdAt: '2026-10-07T10:00:00Z',
        error:
            'A Step could not be completed. Open Run details for the safe error code.',
        steps: [step]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'stream-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: _ContinuityFailureDataSource(request, step),
      onBackToSpace: _noop,
      onArchive: _noop,
    ))));
    await tester.pumpAndSettle();
    expect(find.text('Request cancelled.'), findsOneWidget);
    expect(find.textContaining('could not be completed'), findsNothing);
  });

  for (final (platform, targetSize) in [
    (TargetPlatform.macOS, 32.0),
    (TargetPlatform.android, 48.0),
  ]) {
    testWidgets(
        'in-progress request actions use $targetSize px targets on $platform',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const request = AxWorkRequest(
        id: 'request-in-progress',
        requestedByName: 'You',
        prompt: 'Continue the implementation',
        workflowId: 'direct',
        workflowVersion: 1,
        status: 'running',
        createdAt: '2026-10-07T10:00:00Z',
        steps: [],
      );
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: ThreadPage(
            initialTab: 1,
            space: const AxSpace(
              id: 'space-1',
              name: 'Space',
              branch: '',
              lastActivity: '',
              role: 'owner',
            ),
            thread: const AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Thread',
              lead: '',
              status: 'active',
              brief: '',
              primaryWorkspace: '',
              queueStatus: '',
            ),
            dataSource: _WorkHistoryDataSource([request]),
            onBackToSpace: _noop,
            onArchive: _noop,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Cancel keeps the Work card's action size; the message actions beside
      // the prompt are slightly smaller.
      final messageTargetSize = targetSize == 48.0 ? 40.0 : 28.0;
      for (final (tooltip, size) in [
        ('Cancel request', targetSize),
        ('Reply', messageTargetSize),
        ('Copy', messageTargetSize),
      ]) {
        final action = find.byTooltip(tooltip);
        expect(action, findsOneWidget);
        expect(tester.getSize(action), Size.square(size));
        final icon = tester.widget<Icon>(
          find.descendant(of: action, matching: find.byType(Icon)),
        );
        expect(icon.size, 16);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final workflow in ['chat', 'direct']) {
    for (final code in [
      'session_resume_failed',
      'quota_exhausted',
      'context_limit_exceeded',
      'execution_failed',
      'unknown_code'
    ]) {
      testWidgets('$workflow $code hides technical diagnostics',
          (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const raw = 'Session C123 failed with resume status XYZ';
        final step = AxWorkRequestStep(
            kind: workflow == 'chat' ? 'chat' : 'implement',
            status: 'failed',
            workerId: 'worker-a',
            workerDisplayName: 'ChatGPT',
            errorCode: code,
            failureCategoryMessage: code == 'quota_exhausted'
                ? 'The provider could not start'
                : null,
            errorMessage: raw,
            assignmentId: 'secret-assignment',
            sessionPolicy: 'durable_session',
            engineVersion: 'secret-engine-version');
        final request = AxWorkRequest(
            id: 'failed-request',
            requestedByName: 'User',
            prompt: 'Continue',
            workflowId: workflow,
            workflowVersion: workflow == 'chat' ? 1 : 2,
            status: 'failed',
            createdAt: '2026-10-07T10:00:00Z',
            error: raw,
            steps: [step]);
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: ThreadPage(
          initialTab: 1,
          space: const AxSpace(
              id: 'space-1',
              name: 'Space',
              branch: '',
              lastActivity: '',
              role: 'owner'),
          thread: const AxThread(
              id: 'stream-1',
              spaceId: 'space-1',
              name: 'Stream',
              lead: '',
              status: 'active',
              brief: '',
              primaryWorkspace: '',
              queueStatus: ''),
          dataSource: _ContinuityFailureDataSource(request, step),
          onBackToSpace: _noop,
          onArchive: _noop,
        ))));
        await tester.pumpAndSettle();
        // The step offers no Retry, so the text must not promise one.
        final friendly = code == 'session_resume_failed'
            ? 'The worker could not continue the previous conversation. Send a new message to try again.'
            : code == 'quota_exhausted'
                ? 'The provider’s usage limit has been reached. Wait for the limit to reset or choose another worker, then retry.'
                : code == 'context_limit_exceeded'
                    ? 'This conversation no longer fits the AI model’s context window. Retry to compact the Worker session or to clear AI History.'
                    : 'Your request could not be completed. Send a new message to try again.';
        expect(find.text(friendly), findsOneWidget);
        expect(find.textContaining('C123'), findsNothing);
        for (final hidden in [
          raw,
          code,
          'secret-assignment',
          'secret-engine-version',
          'Advanced technical details',
          'Session mode'
        ]) {
          expect(find.textContaining(hidden), findsNothing);
        }
        expect(find.textContaining('restored'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final retryAllowed in [true, false]) {
    testWidgets(
        'failure text promises Retry only when it is offered '
        '(retryAllowed: $retryAllowed)', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final step = AxWorkRequestStep(
          kind: 'chat',
          status: 'failed',
          workerId: 'worker-a',
          workerDisplayName: 'ChatGPT',
          errorCode: 'execution_failed',
          retryAllowed: retryAllowed);
      final request = AxWorkRequest(
          id: 'failed-request',
          requestedByName: 'User',
          prompt: 'Continue',
          workflowId: 'chat',
          workflowVersion: 1,
          status: 'failed',
          createdAt: '2026-10-07T10:00:00Z',
          steps: [step]);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
        initialTab: 1,
        space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: const AxThread(
            id: 'stream-1',
            spaceId: 'space-1',
            name: 'Stream',
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: ''),
        dataSource: _ContinuityFailureDataSource(request, step),
        onBackToSpace: _noop,
        onArchive: _noop,
      ))));
      await tester.pumpAndSettle();
      expect(
          find.text(retryAllowed
              ? 'Your request could not be completed. Please retry.'
              : 'Your request could not be completed. Send a new message to try again.'),
          findsOneWidget);
    });
  }

  for (final workflow in ['chat', 'direct']) {
    testWidgets('$workflow response header names the Worker owner',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final rows = [
        AxWorkRequest.fromJson({
          'id': 'O',
          'requestedByName': 'User',
          'prompt': 'Request O',
          'workflowId': workflow,
          'workflowVersion': workflow == 'chat' ? 1 : 2,
          'workflowName': workflow == 'chat' ? 'Chat' : 'Work',
          'status': 'completed',
          'createdAt': '2026-10-07T10:00:00Z',
          'turns': [
            turnFixture(id: 'O', requestId: 'O').toJson()
              ..['workflowId'] = workflow
              ..['workflowVersion'] = workflow == 'chat' ? 1 : 2
              ..['workerOwnerName'] = 'Alice'
          ],
          'steps': [
            {
              'kind': 'implement',
              'status': 'completed',
              'workerId': 'worker-a',
              'assignmentId': 'assignment-O',
              'workerTypeId': 'chatgpt',
              'workerDisplayName': 'ChatGPT',
            }
          ],
        })
      ];
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
        initialTab: 1,
        space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: const AxThread(
            id: 'stream-1',
            spaceId: 'space-1',
            name: 'Stream',
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: ''),
        dataSource: _WorkHistoryDataSource(rows),
        onBackToSpace: _noop,
        onArchive: _noop,
      ))));
      await tester.pumpAndSettle();
      expect(_inConversation(find.text('model-x')), findsOneWidget);
      expect(_inConversation(find.text("· Alice's Worker")), findsOneWidget);
      expect(_inConversation(find.byTooltip('Worker owned by Alice')),
          findsOneWidget);
    });
    testWidgets('$workflow response details use immutable model and effort',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final rows = [
        for (final config in [
          ('X', 'model-x', 'medium'),
          ('Y', 'model-y', 'high'),
          ('Default', null, null)
        ])
          AxWorkRequest.fromJson({
            'id': config.$1,
            'requestedByName': 'User',
            'prompt': 'Request ${config.$1}',
            'workflowId': workflow,
            'workflowVersion': workflow == 'chat' ? 1 : 2,
            'workflowName': workflow == 'chat' ? 'Chat' : 'Work',
            'status': 'completed',
            'createdAt': '2026-10-07T10:00:00Z',
            'turns': [
              turnFixture(
                      id: config.$1,
                      requestId: config.$1,
                      model: config.$2,
                      effort: config.$3)
                  .toJson()
                ..['workflowId'] = workflow
                ..['workflowVersion'] = workflow == 'chat' ? 1 : 2
            ],
            'steps': [
              {
                'kind': 'implement',
                'status': 'completed',
                'workerId': 'worker-a',
                'assignmentId': 'assignment-${config.$1}',
                'workerTypeId': 'gemini',
                'workerDisplayName': 'Wrong current worker',
                'model': 'wrong-current-model',
                'reasoningEffort': 'low'
              }
            ],
          })
      ];
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
        initialTab: 1,
        space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: const AxThread(
            id: 'stream-1',
            spaceId: 'space-1',
            name: 'Stream',
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: ''),
        dataSource: _WorkHistoryDataSource(rows),
        onBackToSpace: _noop,
        onArchive: _noop,
      ))));
      await tester.pumpAndSettle();
      expect(_inConversation(find.text('model-x')), findsOneWidget);
      expect(_inConversation(find.text('model-y')), findsOneWidget);
      expect(_inConversation(find.text('ChatGPT')), findsOneWidget);
      expect(_inConversation(find.text('· Medium')), findsOneWidget);
      expect(_inConversation(find.text('· High')), findsOneWidget);
      expect(_inConversation(find.text('· Default effort')), findsOneWidget);
      expect(_inConversation(find.byIcon(Icons.info_outline_rounded)),
          findsNothing);
      for (final width in [390.0, 1200.0]) {
        await tester.binding.setSurfaceSize(Size(width, 1400));
        await tester.pumpAndSettle();
        expect(_inConversation(find.text('· Medium')), findsOneWidget);
        expect(_inConversation(find.text('· High')), findsOneWidget);
        final senderIcons = tester.widgetList<Image>(_inConversation(
            find.byWidgetPredicate((widget) =>
                widget is Image &&
                widget.semanticLabel?.endsWith(' icon') == true)));
        expect(senderIcons, isNotEmpty);
        for (final icon in senderIcons) {
          expect(tester.getSize(find.byWidget(icon)), const Size(24, 24));
        }
        expect(tester.takeException(), isNull);
      }
      expect(find.textContaining('Model changed'), findsNothing);
      expect(find.textContaining('Effort changed'), findsNothing);
      expect(find.text('Wrong current worker'), findsNothing);
      expect(find.textContaining('wrong-current-model'), findsNothing);
    });
  }

  testWidgets('composer does not resurrect obsolete Thread execution choices',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final choices in [
      (true, false, true),
      (false, true, true),
      (true, true, false)
    ]) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
        key: ValueKey(choices),
        initialTab: 1,
        space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: const AxThread(
            id: 'stream-1',
            spaceId: 'space-1',
            name: 'Stream',
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: '',
            workConfig: {
              'defaultWorkflowId': 'policy-fixture',
              'bindings': {
                'policy-binding': {'workerId': 'w-chatgpt', 'model': 'o3'}
              },
            }),
        dataSource: _PolicyWorkflowDataSource(
            model: choices.$1, effort: choices.$2, binding: choices.$3),
        onBackToSpace: _noop,
        onArchive: _noop,
      ))));
      await tester.pumpAndSettle();
      expect(find.text('o3'), findsNothing);
      expect(find.byTooltip('Choose model'), findsNothing);
      expect(find.byTooltip('Choose reasoning effort'), findsNothing);
    }
  });
  testWidgets('history names remain accurate without a loaded catalog',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'stream-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: _SnapshotHistoryDataSource(),
      onBackToSpace: _noop,
      onArchive: _noop,
    ))));
    await tester.pumpAndSettle();
    await _openAiHistory(tester);
    for (final name in ['Direct', 'Work', 'Chat']) {
      expect(find.text('· $name'), findsOneWidget);
    }
  });
  testWidgets(
      'AI History starts after its clear while the Conversation keeps all',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'stream-cleared',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: _ClearedHistoryDataSource(),
      onBackToSpace: _noop,
      onArchive: _noop,
    ))));
    await tester.pumpAndSettle();
    // The Conversation shows both exchanges with their full Work cards.
    expect(_inConversation(find.text('Before clear')), findsOneWidget);
    expect(_inConversation(find.text('After clear')), findsOneWidget);
    await _openAiHistory(tester);
    final history = find.byKey(const ValueKey('work-history-scroll'));
    expect(find.descendant(of: history, matching: find.text('Before clear')),
        findsNothing);
    expect(find.descendant(of: history, matching: find.text('After clear')),
        findsOneWidget);
  });
  testWidgets('narrow composer lists every workflow in one selector',
      (tester) async {
    tester.view
      ..physicalSize = const Size(420, 1000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'stream-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: _CurrentWorkflowUiDataSource(),
      onBackToSpace: _noop,
      onArchive: _noop,
      onRunWork: (_, __, ___, ____) => Completer<String>().future,
    ))));
    await tester.pumpAndSettle();
    await _askAi(tester);
    expect(find.byKey(const ValueKey('work-toggle-chat')), findsNothing);
    expect(find.byKey(const ValueKey('work-toggle-direct')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('work-choose-workflow')));
    await tester.pumpAndSettle();
    final menu = find.byType(SyntilaMenuEntry<String>);
    final chat = find.descendant(of: menu, matching: find.text('Chat'));
    expect(chat, findsOneWidget);
    expect(
        find.descendant(of: menu, matching: find.text('Work')), findsOneWidget);
    final colors = tester
        .widgetList<Text>(
            find.descendant(of: menu, matching: find.byType(Text)))
        .map((text) => text.style?.color)
        .toSet();
    // All workflow items share the normal text color.
    expect(colors, hasLength(1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('Chat Work and More switch workflows and submit Markdown',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = _CurrentWorkflowUiDataSource();
    final submission = Completer<String>();
    String? sentWorkflow;
    String? sentSource;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      viewerEmail: 'vitalii@nohainc.com',
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'stream-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: data,
      onBackToSpace: _noop,
      onArchive: _noop,
      onRunWork: (source, workflow, _, key) {
        sentSource = source;
        sentWorkflow = workflow;
        return submission.future;
      },
    ))));
    await tester.pumpAndSettle();
    final markdown = tester
        .widgetList<SyntilaMarkdownBody>(find.byType(SyntilaMarkdownBody))
        .map((body) => body.data)
        .toList();
    expect(markdown, containsAll(['**Chat answer**', '**Work answer**']));
    await _askAi(tester);
    expect(find.byKey(const ValueKey('work-toggle-chat')), findsOneWidget);
    expect(find.byKey(const ValueKey('work-toggle-direct')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('work-choose-workflow')));
    await tester.pumpAndSettle();
    final menu = find.byType(SyntilaMenuEntry<String>);
    expect(
        find.descendant(of: menu, matching: find.text('Chat')), findsNothing);
    expect(
        find.descendant(of: menu, matching: find.text('Work')), findsNothing);
    expect(
        find.descendant(of: menu, matching: find.text('Direct')), findsNothing);
    final menuOrder = tester
        .widgetList<Text>(
            find.descendant(of: menu, matching: find.byType(Text)))
        .map((text) => text.data)
        .toList();
    await tester.tap(
        find.descendant(of: menu, matching: find.text('Plan & Implement')));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('work-choose-workflow')),
            matching: find.text('Plan & Implement')),
        findsOneWidget);
    expect(
        tester
            .widget<Semantics>(
                find.byKey(const ValueKey('work-choose-workflow')))
            .properties
            .selected,
        isTrue);
    await tester.tap(find.byKey(const ValueKey('work-toggle-direct')));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('work-choose-workflow')),
            matching: find.text('More')),
        findsOneWidget);
    // More keeps catalog order regardless of the selection; names only.
    await tester.tap(find.byKey(const ValueKey('work-choose-workflow')));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuDivider), findsNothing);
    expect(
        tester
            .widgetList<Text>(find.descendant(
                of: find.byType(SyntilaMenuEntry<String>),
                matching: find.byType(Text)))
            .map((text) => text.data)
            .toList(),
        menuOrder);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('work-toggle-chat')));
    await tester.pumpAndSettle();

    const source = '## Question\n\n**Explain** this `code`.';
    await tester.enterText(find.byType(TextField).first, source);
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(sentWorkflow, 'chat');
    expect(sentSource, source);
    expect(data.discussionWrites, 0);
    await tester.pumpWidget(const SizedBox());
    submission.complete('chat-saved');
    await tester.pump();
  });
  testWidgets('current Work selection preserves historical Direct labels',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final submission = Completer<String>();
    String? sentWorkflow;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'stream-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: _VersionedWorkflowDataSource(),
      onBackToSpace: _noop,
      onArchive: _noop,
      onRunWork: (_, workflow, ___, key) {
        sentWorkflow = workflow;
        return submission.future;
      },
    ))));
    await tester.pumpAndSettle();
    expect(find.text('· Direct'), findsOneWidget);
    await _askAi(tester);
    // No other workflows are enabled, so the More menu is hidden.
    expect(find.byKey(const ValueKey('work-choose-workflow')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('work-toggle-direct')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Work settings'), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'New work');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(sentWorkflow, 'direct');
    expect(find.text('· Work'), findsOneWidget);
    expect(find.text('· Direct'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    submission.complete('saved-new');
    await tester.pump();
  });

  testWidgets('Thread is one conversation with an optional AI History panel',
      (tester) async {
    tester.view.physicalSize = const Size(1800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final width in [600.0, 999.0, 1000.0, 1800.0]) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Center(
        child: SizedBox(
            width: width,
            child: ThreadPage(
              key: ValueKey(width),
              space: const AxSpace(
                  id: 'space-1',
                  name: 'Space',
                  branch: '',
                  lastActivity: '',
                  role: 'owner'),
              thread: const AxThread(
                  id: 'thread-1',
                  spaceId: 'space-1',
                  name: 'Stream',
                  lead: '',
                  status: 'active',
                  brief: '',
                  primaryWorkspace: '',
                  queueStatus: ''),
              dataSource: _PinnedHistoryDataSource(),
              onBackToSpace: _noop,
              onArchive: _noop,
            )),
      ))));
      await tester.pumpAndSettle();
      final chat = find.byKey(const ValueKey('chat-history-scroll'));
      final work = find.byKey(const ValueKey('work-history-scroll'));
      final history = find.byKey(const ValueKey('thread-AI History-pane'));
      expect(find.byType(TabBar), findsNothing);
      expect(tester.getSize(chat).width, lessThanOrEqualTo(800));
      expect(
          tester
              .widget<Padding>(
                  find.byKey(const ValueKey('thread-Conversation-padding')))
              .padding,
          const EdgeInsets.fromLTRB(20, 0, 20, 20));
      expect(work, findsNothing);
      expect(find.byType(MarkdownComposer), findsOneWidget);
      final mode = find.byKey(const ValueKey('conversation-composer-mode'));
      expect(find.descendant(of: find.byType(MarkdownComposer), matching: mode),
          findsOneWidget);
      expect(tester.getRect(mode).right,
          lessThanOrEqualTo(tester.getRect(find.byType(TextField)).left));
      final messageSwitch =
          tester.getRect(find.byKey(const ValueKey('composer-mode-message')));
      final aiSwitch =
          tester.getRect(find.byKey(const ValueKey('composer-mode-ai')));
      expect(messageSwitch.center.dx, aiSwitch.center.dx);
      expect(messageSwitch.bottom, lessThanOrEqualTo(aiSwitch.top));
      bool selected(String mode) => tester
          .widget<IconButton>(find.byKey(ValueKey('composer-mode-$mode')))
          .isSelected!;
      void expectIconOnlySelection(String activeMode) {
        for (final mode in ['message', 'ai']) {
          final button = tester
              .widget<IconButton>(find.byKey(ValueKey('composer-mode-$mode')));
          expect(
              button.style!.backgroundColor!.resolve({}), Colors.transparent);
          expect(button.style!.backgroundColor!.resolve({WidgetState.disabled}),
              Colors.transparent);
          if (mode == activeMode) {
            expect((button.icon as Icon).color,
                SyntilaColors.primaryForegroundLight);
          }
        }
      }

      expect(selected('message'), isTrue);
      expect(selected('ai'), isFalse);
      expectIconOnlySelection('message');
      final addFiles = find.byKey(const ValueKey('message-add-attachments'));
      final emoji = find.byKey(const ValueKey('emoji-picker-button'));
      expect(
          tester.getCenter(addFiles).dx, lessThan(tester.getCenter(emoji).dx));
      expect(tester.getCenter(addFiles).dy, tester.getCenter(emoji).dy);
      final markup = find.ancestor(
          of: find.byIcon(Icons.text_format),
          matching: find.byType(IconButton));
      final send = find.byKey(const ValueKey('composer-send-Send message'));
      expect(tester.getRect(emoji).left - tester.getRect(addFiles).right,
          lessThanOrEqualTo(8));
      expect(tester.getRect(markup).left - tester.getRect(emoji).right,
          inInclusiveRange(0, 8));
      expect(tester.getCenter(markup).dy, tester.getCenter(emoji).dy);
      expect(tester.getRect(send).left - tester.getRect(markup).right,
          greaterThan(40));

      expect(find.byIcon(Icons.attach_file), findsNothing);
      await tester.tap(addFiles);
      await tester.pumpAndSettle();
      expect(find.text('Add files'), findsOneWidget);
      expect(find.byIcon(Icons.attach_file), findsOneWidget);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(messageSwitch.width, 32);
      await tester.tap(find.byKey(const ValueKey('composer-mode-ai')));
      await tester.pumpAndSettle();
      expect(selected('ai'), isTrue);
      expectIconOnlySelection('ai');
      expect(find.descendant(of: find.byType(MarkdownComposer), matching: mode),
          findsOneWidget);
      expect(find.byKey(const ValueKey('emoji-picker-button')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('composer-mode-message')));
      await tester.pumpAndSettle();
      expect(selected('message'), isTrue);

      final conversationTab = find.byKey(const ValueKey('conversation-tab'));
      final historyTab = find.byKey(const ValueKey('ai-history-toggle'));
      Color? tabColor(Finder tab) =>
          tester.widget<TextButton>(tab).style!.foregroundColor!.resolve({});
      FontWeight? tabWeight(Finder tab) => tester
          .widget<TextButton>(tab)
          .style!
          .textStyle!
          .resolve({})!.fontWeight;
      expect(tabColor(conversationTab), SyntilaColors.textPrimaryLight);
      expect(tabWeight(conversationTab), FontWeight.bold);
      expect(tabWeight(historyTab), FontWeight.normal);
      expect(tabColor(historyTab), SyntilaColors.textPrimaryLight);
      expect(find.descendant(of: conversationTab, matching: find.byType(Icon)),
          findsNothing);
      expect(tester.getRect(conversationTab).right,
          lessThanOrEqualTo(tester.getRect(historyTab).left));

      await tester.tap(find.byKey(const ValueKey('ai-history-toggle')));
      await tester.pump();
      final visibility = find.byKey(const ValueKey('thread-view-visibility'));
      expect(tester.widget<Opacity>(visibility).opacity, 0);
      await tester.pumpAndSettle();
      expect(tester.widget<Opacity>(visibility).opacity, 1);
      final workPosition = tester
          .state<ScrollableState>(find
              .descendant(of: work, matching: find.byType(Scrollable))
              .first)
          .position;
      final settledOffset = workPosition.pixels;
      await tester.pump();
      expect(workPosition.pixels, settledOffset);
      expect(work, findsOneWidget);
      expect(tabColor(find.byKey(const ValueKey('ai-history-tab'))),
          SyntilaColors.textPrimaryLight);
      expect(tabColor(find.byKey(const ValueKey('ai-history-conversation'))),
          SyntilaColors.textPrimaryLight);
      expect(tabWeight(find.byKey(const ValueKey('ai-history-tab'))),
          FontWeight.bold);
      expect(tabWeight(find.byKey(const ValueKey('ai-history-conversation'))),
          FontWeight.normal);
      expect(find.text('Read-only'), findsNothing);
      expect(find.byTooltip('Close AI History'), findsNothing);
      // AI History never accepts input.
      expect(find.descendant(of: history, matching: find.byType(TextField)),
          findsNothing);
      // Only one pane is shown at any width.
      expect(chat, findsNothing);
      expect(find.byType(VerticalDivider), findsNothing);
      // Both panes stay mounted once positioned: switching back is instant
      // and AI History keeps its scroll position.
      await tester.tap(find.byKey(const ValueKey('ai-history-conversation')));
      await tester.pump();
      expect(tester.widget<Opacity>(visibility).opacity, 1);
      expect(work, findsNothing);
      expect(chat, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-history-toggle')));
      await tester.pump();
      expect(tester.widget<Opacity>(visibility).opacity, 1);
      expect(work, findsOneWidget);
      expect(workPosition.pixels, settledOffset);
      await tester.tap(find.byKey(const ValueKey('ai-history-conversation')));
      await tester.pumpAndSettle();
      expect(chat, findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Space opt-in hides AI History even when saved open',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'space-1', name: 'Space', branch: '', lastActivity: ''),
      thread: const AxThread(
          id: 'thread-1',
          spaceId: 'space-1',
          name: 'Thread',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      showAiHistory: false,
      initialAiHistoryOpen: true,
      dataSource: _PinnedHistoryDataSource(),
      onBackToSpace: _noop,
      onArchive: _noop,
    ))));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ai-history-toggle')), findsNothing);
    expect(find.byKey(const ValueKey('thread-AI History-pane')), findsNothing);
    expect(
        find.byKey(const ValueKey('thread-Conversation-pane')), findsOneWidget);
  });
  testWidgets('edited chat messages show the modified marker and time',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThreadPage(
          space: const AxSpace(
            id: 'space-1',
            name: 'Space One',
            branch: '',
            lastActivity: 'today',
            role: 'collaborator',
          ),
          thread: const AxThread(
            id: 'thread-1',
            spaceId: 'space-1',
            name: 'Research',
            lead: 'Owner',
            status: 'active',
            brief: 'Understand the problem.',
            primaryWorkspace: 'Workspace One',
            queueStatus: 'Idle',
          ),
          dataSource:
              _DiscussionDataSource(editedAt: '2026-10-06T12:00:00.000Z'),
          currentUserId: 'user-owner',
          onBackToSpace: _noop,
          onArchive: _noop,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Edited 2026-10-06 ·'), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) =>
          widget is Text && widget.data?.startsWith('2026-10-05 ·') == true),
      findsNothing,
    );
  });

  testWidgets(
      'Work appears before validation and progress becomes result or error',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final reject in [false, true]) {
      final data = _SlowSubmissionDataSource();
      const previous = AxWorkRequest(
        id: 'previous-response',
        requestedByName: 'You',
        prompt: 'Earlier request',
        workflowId: 'direct',
        workflowVersion: 1,
        status: 'completed',
        createdAt: '2026-10-05T10:00:00Z',
        steps: [],
        finalText: 'Earlier completed response',
      );
      data.requests = [previous];
      final submitted = Completer<String>();
      var sends = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
        key: ValueKey(reject),
        initialTab: 1,
        space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: const AxThread(
            id: 'thread-1',
            spaceId: 'space-1',
            name: 'Stream',
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: ''),
        dataSource: data,
        currentUserId: 'user-owner',
        onBackToSpace: _noop,
        onArchive: _noop,
        onRunWork: (_, __, ___, key) {
          sends++;
          return submitted.future;
        },
      ))));
      await tester.pumpAndSettle();
      await _askAi(tester);
      final previousBody = find.byWidgetPredicate((widget) =>
          widget is SyntilaMarkdownBody &&
          widget.data == 'Earlier completed response');
      final previousElement = tester.element(previousBody);
      void expectPreviousUnchanged() {
        expect(tester.element(previousBody), same(previousElement));
        expect(tester.widget<SyntilaMarkdownBody>(previousBody).data,
            'Earlier completed response');
        expect(
            tester.widget<SyntilaMarkdownBody>(previousBody).key,
            const ValueKey(
                ('previous-response', 'Earlier completed response')));
      }

      await tester.enterText(
          find.byType(TextField).first, '**Immediate request**');
      await tester
          .tap(find.byKey(const ValueKey('composer-send-Send request')));
      await tester.pump();
      // The new request is revealed by the follow jump on the next frame.
      await tester.pump();
      expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          isEmpty);
      expect(
          _inConversation(find.byType(SyntilaMarkdownBody)).evaluate().where(
              (element) =>
                  (element.widget as SyntilaMarkdownBody).data ==
                  '**Immediate request**'),
          hasLength(1));
      expect(
          _inConversation(find.byType(SyntilaMarkdownBody)).evaluate().any(
              (element) =>
                  (element.widget as SyntilaMarkdownBody).data ==
                  'Checking that everything is ready…'),
          isTrue);
      expectPreviousUnchanged();
      // A concurrent history insertion moves the completed response while the
      // new request is still displaying progress.
      AxWorkHistoryCache.forSource(data).patchRequest(
          'thread-1',
          const AxWorkRequest(
            id: 'older-response',
            requestedByName: 'You',
            prompt: 'Older request',
            workflowId: 'direct',
            workflowVersion: 1,
            status: 'completed',
            createdAt: '2026-10-04T10:00:00Z',
            steps: [],
            finalText: 'Older completed response',
          ));
      await tester.pump();
      expectPreviousUnchanged();
      expect(sends, 0);
      expect(find.byTooltip('Refresh Work history'), findsNothing);
      final pendingInput =
          tester.widget<TextField>(find.byType(TextField).first);
      expect(pendingInput.enabled, isTrue);
      await tester.tap(find.byType(TextField).first);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.enterText(find.byType(TextField).first, 'Next draft');
      expect(pendingInput.controller!.text, 'Next draft');
      expect(
          tester
              .widget<IconButton>(
                  find.widgetWithIcon(IconButton, Icons.send_rounded))
              .onPressed,
          isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sends, 0);
      // Leave the input empty so validation failure restores the original.
      await tester.enterText(find.byType(TextField).first, '');
      await AxWorkHistoryCache.forSource(data).refresh('thread-1');
      await tester.pumpAndSettle();
      expect(
          _inConversation(find.byType(SyntilaMarkdownBody)).evaluate().where(
              (element) =>
                  (element.widget as SyntilaMarkdownBody).data ==
                  '**Immediate request**'),
          hasLength(1));
      data.ready.complete(reject ? ['Space access is required.'] : []);
      await tester.pumpAndSettle();
      if (reject) {
        expect(sends, 0);
        expect(
            _inConversation(find.textContaining('Space access is required.')),
            findsOneWidget);
        expect(
            tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!
                .text,
            '**Immediate request**');
      } else {
        expect(sends, 1);
        expect(tester.widget<TextField>(find.byType(TextField).first).enabled,
            isTrue);
        await tester.enterText(
            find.byType(TextField).first, 'Draft while sending');
        expect(
            _inConversation(find.byType(SyntilaMarkdownBody)).evaluate().any(
                (element) =>
                    (element.widget as SyntilaMarkdownBody).data ==
                    'Sending your request…'),
            isTrue);
        data.requests = [
          previous,
          const AxWorkRequest(
              id: 'saved-1',
              requestedByName: 'You',
              requestedByUserId: 'user-owner',
              prompt: '**Immediate request**',
              workflowId: 'direct',
              workflowVersion: 1,
              status: 'running',
              createdAt: '2026-10-06T10:00:00Z',
              steps: [],
              finalText: null)
        ];
        submitted.complete('saved-1');
        await tester.pumpAndSettle();
        expectPreviousUnchanged();
        expect(
            _inConversation(find
                .textContaining('A previous request is still in progress.')),
            findsNothing);
        expect(find.text('Cancel pending request'), findsNothing);
        expect(
            tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!
                .text,
            'Draft while sending');
        await tester.enterText(find.byType(TextField).first, 'Next request');
        expect(
            tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!
                .text,
            'Next request');
        expect(
            tester
                .widget<IconButton>(
                    find.widgetWithIcon(IconButton, Icons.send_rounded))
                .onPressed,
            isNotNull);
        await tester
            .tap(find.byKey(const ValueKey('composer-send-Send request')));
        await tester.pumpAndSettle();
        // Sending while a request processes queues the message.
        expect(sends, 1);
        expect(find.byKey(const ValueKey('work-queue-panel')), findsOneWidget);
        expect(find.text('Next request'), findsOneWidget);
        await tester.tap(find.byTooltip('Send now'));
        await tester.pumpAndSettle();
        expect(find.text('Cancel previous request?'), findsOneWidget);
        expect(find.text('Cancel and send'), findsOneWidget);
        await tester.tap(find.text('Cancel and send'));
        await tester.pumpAndSettle();
        expect(sends, 2);
        expect(data.cancelledWorkRequestIds, ['saved-1']);
        data.requests = [
          previous,
          const AxWorkRequest(
            id: 'saved-1',
            requestedByName: 'You',
            requestedByUserId: 'user-owner',
            prompt: '**Immediate request**',
            workflowId: 'direct',
            workflowVersion: 1,
            status: 'completed',
            createdAt: '2026-10-06T10:00:00Z',
            steps: [],
            finalText: 'Completed answer',
          )
        ];
        await AxWorkHistoryCache.forSource(data).refresh('thread-1');
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<IconButton>(
                    find.widgetWithIcon(IconButton, Icons.send_rounded))
                .onPressed,
            isNotNull);
        expect(
            _inConversation(find.byType(SyntilaMarkdownBody)).evaluate().any(
                (element) =>
                    (element.widget as SyntilaMarkdownBody).data ==
                    'Completed answer'),
            isTrue);
        expect(
            _inConversation(find.byType(SyntilaMarkdownBody)).evaluate().where(
                (element) =>
                    (element.widget as SyntilaMarkdownBody).data ==
                    '**Immediate request**'),
            hasLength(1));
      }
      expect(tester.takeException(), isNull);
    }
  });
  for (final brightness in Brightness.values) {
    testWidgets(
        'messages sent while a request runs are queued and sent next $brightness',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final data = _SlowSubmissionDataSource()..ready.complete([]);
      AxWorkRequest running(String status) => AxWorkRequest(
            id: 'running-1',
            requestedByName: 'You',
            requestedByUserId: 'user-owner',
            prompt: 'First request',
            workflowId: 'direct',
            workflowVersion: 1,
            status: status,
            createdAt: '2026-10-06T10:00:00Z',
            steps: const [],
            finalText: status == 'completed' ? 'First answer' : null,
          );
      data.requests = [running('running')];
      final prompts = <String>[];
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
              body: ThreadPage(
            initialTab: 1,
            space: const AxSpace(
                id: 'space-1',
                name: 'Space',
                branch: '',
                lastActivity: '',
                role: 'owner'),
            thread: const AxThread(
                id: 'thread-1',
                spaceId: 'space-1',
                name: 'Stream',
                lead: '',
                status: 'active',
                brief: '',
                primaryWorkspace: '',
                queueStatus: ''),
            dataSource: data,
            currentUserId: 'user-owner',
            onBackToSpace: _noop,
            onArchive: _noop,
            onRunWork: (prompt, __, ___, key) async {
              prompts.add(prompt);
              return 'saved-${prompts.length}';
            },
          ))));
      await tester.pumpAndSettle();
      await _askAi(tester);
      final send = find.byKey(const ValueKey('composer-send-Send request'));
      for (final text in ['Second', 'Third', 'Dropped']) {
        await tester.enterText(find.byType(TextField).first, text);
        await tester.tap(send);
        await tester.pumpAndSettle();
      }
      expect(prompts, isEmpty);
      expect(find.text('Cancel previous request?'), findsNothing);
      expect(find.byKey(const ValueKey('work-queue-panel')), findsOneWidget);
      expect(find.textContaining('Queued · 3'), findsOneWidget);

      final divider = find.byKey(const ValueKey('work-queue-panel-divider'));
      expect(divider, findsNothing);

      // Usage, history and queue can coexist. Only the queue nearest the input
      // extends behind it; the upper layers meet the next panel without overlap.
      final usage =
          tester.widget<AxWorkerUsagePanel>(find.byType(AxWorkerUsagePanel));
      usage.controller.showMessage('Usage alongside queued requests');
      await tester.pumpAndSettle();
      expect(divider, findsOneWidget);
      expect(find.textContaining('Queued · 3'), findsOneWidget);
      await tester.showKeyboard(find.byType(TextField).first);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      final usageLayer = tester
          .getRect(find.byKey(const ValueKey('worker-usage-layer-background')));
      final historyLayer = tester.getRect(
          find.byKey(const ValueKey('request-history-layer-background')));
      final queuePanel =
          tester.getRect(find.byKey(const ValueKey('work-queue-panel')));
      expect(usageLayer.bottom, historyLayer.top);
      expect(historyLayer.bottom, queuePanel.top);
      expect(usageLayer.left, historyLayer.left);
      expect(historyLayer.left, queuePanel.left);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
          tester
              .getRect(
                  find.byKey(const ValueKey('worker-usage-layer-background')))
              .bottom,
          tester.getTopLeft(find.byKey(const ValueKey('work-queue-panel'))).dy);
      usage.controller.dismiss();
      await tester.pumpAndSettle();
      expect(divider, findsNothing);

      // History alone also separates its content from the visible queue.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(divider, findsOneWidget);
      expect(find.textContaining('Queued · 3'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(divider, findsNothing);

      final queueHeader = tester
          .widget<Container>(find.byKey(const ValueKey('work-queue-header')));
      final isDark = brightness == Brightness.dark;
      expect(queueHeader.color, SyntilaColors.composerRail(isDark));

      // The queue is an inset back layer of the input, with no gap. Its
      // decorative overlap must not cover the input or hide the queue controls.
      for (final width in [1200.0, 390.0]) {
        await tester.binding.setSurfaceSize(Size(width, 1400));
        await tester.pumpAndSettle();
        final queue =
            tester.getRect(find.byKey(const ValueKey('work-queue-panel')));
        final layer = tester
            .getRect(find.byKey(const ValueKey('work-queue-layer-background')));
        final composer = tester.getRect(find.byType(MarkdownComposer));
        expect(queue.bottom, composer.top);
        expect(queue.left, composer.left + 40);
        expect(queue.right, composer.right - 40);
        expect(layer.bottom, composer.top + 10);
        expect(find.byTooltip('Pause queue').hitTestable(), findsOneWidget);
        expect(find.byTooltip('Edit').hitTestable(), findsNWidgets(3));
        expect(find.byTooltip('Send now').hitTestable(), findsNWidgets(3));
        expect(find.byTooltip('Remove from queue').hitTestable(),
            findsNWidgets(3));
        expect(send.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }

      // Remove one; edit another back into the composer and queue it again.
      await tester.tap(find.byTooltip('Remove from queue').last);
      await tester.pumpAndSettle();
      expect(find.text('Dropped'), findsNothing);
      await tester.tap(find.byTooltip('Edit').last);
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          'Third');
      await tester.enterText(find.byType(TextField).first, 'Third edited');
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(find.textContaining('Queued · 2'), findsOneWidget);

      data.requests = [running('completed')];
      await AxWorkHistoryCache.forSource(data).refresh('thread-1');
      await tester.pumpAndSettle();
      // Only the head of the queue is sent; the next waits for it to finish.
      expect(prompts, ['Second']);
      expect(find.textContaining('Queued · 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Leaving with messages queued would start the background sender.
      ThreadPage.resetWorkQueues();
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('queued messages are still sent after leaving the Thread',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = _SlowSubmissionDataSource()..ready.complete([]);
    AxWorkRequest running(String status) => AxWorkRequest(
          id: 'running-1',
          requestedByName: 'You',
          requestedByUserId: 'user-owner',
          prompt: 'First request',
          workflowId: 'direct',
          workflowVersion: 1,
          status: status,
          createdAt: '2026-10-06T10:00:00Z',
          steps: const [],
          finalText: status == 'completed' ? 'First answer' : null,
        );
    data.requests = [running('running')];
    final prompts = <String>[];
    Widget page(String threadId) => MaterialApp(
            home: Scaffold(
                body: ThreadPage(
          initialTab: 1,
          space: const AxSpace(
              id: 'space-1',
              name: 'Space',
              branch: '',
              lastActivity: '',
              role: 'owner'),
          thread: AxThread(
              id: threadId,
              spaceId: 'space-1',
              name: 'Stream',
              lead: '',
              status: 'active',
              brief: '',
              primaryWorkspace: '',
              queueStatus: ''),
          dataSource: data,
          currentUserId: 'user-owner',
          onBackToSpace: _noop,
          onArchive: _noop,
          onRunWork: (prompt, __, ___, key) async {
            prompts.add(prompt);
            return 'saved-${prompts.length}';
          },
        )));
    await tester.pumpWidget(page('thread-1'));
    await tester.pumpAndSettle();
    await _askAi(tester);
    await tester.enterText(find.byType(TextField).first, 'Queued while away');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Queued · 1'), findsOneWidget);

    // Leave the Thread page entirely, then let the running request finish.
    await tester.pumpWidget(const SizedBox());
    data.requests = [running('completed')];
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(prompts, ['Queued while away']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the request queue is shared with members and kept in Cloud',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = _SharedQueueDataSource()..ready.complete([]);
    data.requests = [
      const AxWorkRequest(
        id: 'r1',
        requestedByName: 'Mia',
        requestedByUserId: 'user-mia',
        prompt: 'Running for Mia',
        workflowId: 'direct',
        workflowVersion: 1,
        status: 'running',
        createdAt: '2026-10-06T10:00:00Z',
        steps: [],
      )
    ];
    data.queue =
        AxThreadQueue(items: [data.item('m1', 'user-mia', 'Mia asks next')]);
    final realtime = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(realtime.close);
    final prompts = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'thread-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: data,
      currentUserId: 'user-owner',
      realtimeEvents: realtime.stream,
      onBackToSpace: _noop,
      onArchive: _noop,
      onRunWork: (prompt, __, ___, key) async {
        prompts.add(prompt);
        return 'saved-${prompts.length}';
      },
    ))));
    await tester.pumpAndSettle();
    await _askAi(tester);

    // Another member's queued request is shown with its author, read-only.
    expect(find.text('Mia: Mia asks next'), findsOneWidget);
    expect(find.byTooltip('Remove from queue'), findsNothing);
    expect(find.byTooltip('Edit'), findsNothing);

    // A new message joins the shared queue in Cloud instead of being sent.
    await tester.enterText(find.byType(TextField).first, 'Mine next');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(prompts, isEmpty);
    expect(data.calls, ['enqueue:Mine next']);
    expect(find.textContaining('Queued · 2'), findsOneWidget);
    expect(find.byTooltip('Remove from queue'), findsOneWidget);

    // Any member pauses the shared queue.
    await tester.tap(find.byTooltip('Pause queue'));
    await tester.pumpAndSettle();
    expect(data.calls.last, 'pause');
    expect(find.textContaining('— paused'), findsOneWidget);

    // Another member's change arrives through realtime.
    data.queue =
        AxThreadQueue(items: [data.item('q2', 'user-owner', 'Mine next')]);
    realtime.add({
      'type': 'thread.queue_updated',
      'payload': {'threadId': 'thread-1', 'entityId': 'thread-1'},
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Queued · 1'), findsOneWidget);
    expect(find.textContaining('paused'), findsNothing);

    // Cloud sends the queue; the page never sends it itself.
    data.requests = [
      for (final request in data.requests)
        AxWorkRequest(
          id: request.id,
          requestedByName: request.requestedByName,
          requestedByUserId: request.requestedByUserId,
          prompt: request.prompt,
          workflowId: 'direct',
          workflowVersion: 1,
          status: 'completed',
          createdAt: request.createdAt,
          steps: const [],
          finalText: 'Done',
        )
    ];
    await AxWorkHistoryCache.forSource(data).refresh('thread-1');
    await tester.pumpAndSettle();
    expect(prompts, isEmpty);

    await tester.tap(find.byTooltip('Remove from queue'));
    await tester.pumpAndSettle();
    expect(data.calls.last, 'remove:q2');
    expect(find.byKey(const ValueKey('work-queue-panel')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('a failed request pauses the queue until the user resumes it',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = _SlowSubmissionDataSource()..ready.complete([]);
    AxWorkRequest request(String id, String status) => AxWorkRequest(
          id: id,
          requestedByName: 'You',
          requestedByUserId: 'user-owner',
          prompt: 'Request $id',
          workflowId: 'direct',
          workflowVersion: 1,
          status: status,
          createdAt: '2026-10-06T10:00:0${id.length % 10}Z',
          steps: const [],
          finalText: status == 'completed' ? 'Answer $id' : null,
        );
    data.requests = [request('r1', 'running')];
    final prompts = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'thread-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: data,
      currentUserId: 'user-owner',
      onBackToSpace: _noop,
      onArchive: _noop,
      onRunWork: (prompt, __, ___, key) async {
        prompts.add(prompt);
        return 'saved-${prompts.length}';
      },
    ))));
    await tester.pumpAndSettle();
    await _askAi(tester);
    final send = find.byKey(const ValueKey('composer-send-Send request'));
    for (final text in ['Second', 'Third']) {
      await tester.enterText(find.byType(TextField).first, text);
      await tester.tap(send);
      await tester.pumpAndSettle();
    }

    // The running request fails: nothing is sent and the queue is paused.
    data.requests = [request('r1', 'failed')];
    await AxWorkHistoryCache.forSource(data).refresh('thread-1');
    await tester.pumpAndSettle();
    expect(prompts, isEmpty);
    expect(find.textContaining('paused after an error'), findsOneWidget);

    // Queueing another message does not resume a paused queue.
    await tester.enterText(find.byType(TextField).first, 'Fourth');
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(prompts, isEmpty);
    expect(find.textContaining('Queued · 3'), findsOneWidget);

    await tester.tap(find.byTooltip('Resume queue'));
    await tester.pumpAndSettle();
    expect(prompts, ['Second']);

    // The user pauses the queue; finishing the request sends nothing.
    await tester.tap(find.byTooltip('Pause queue'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Queued · 2 — paused'), findsOneWidget);
    data.requests = [request('r1', 'failed'), request('saved-1', 'completed')];
    await AxWorkHistoryCache.forSource(data).refresh('thread-1');
    await tester.pumpAndSettle();
    expect(prompts, ['Second']);

    await tester.tap(find.byTooltip('Resume queue'));
    await tester.pumpAndSettle();
    expect(prompts, ['Second', 'Third']);

    // A pause left on an emptied queue does not hold the next first message.
    final finished = [request('r1', 'failed'), request('saved-1', 'completed')];
    data.requests = [...finished, request('saved-2', 'running')];
    await AxWorkHistoryCache.forSource(data).refresh('thread-1');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Fifth');
    await tester.tap(send);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Pause queue'));
    await tester.pumpAndSettle();
    while (find.byTooltip('Remove from queue').evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('Remove from queue').first);
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const ValueKey('work-queue-panel')), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'Sixth');
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(find.textContaining('Queued · 1'), findsOneWidget);
    expect(find.textContaining('paused'), findsNothing);
    data.requests = [...finished, request('saved-2', 'completed')];
    await AxWorkHistoryCache.forSource(data).refresh('thread-1');
    await tester.pumpAndSettle();
    expect(prompts, ['Second', 'Third', 'Sixth']);
    expect(tester.takeException(), isNull);
  });
  testWidgets('sending a queued message scrolls to the latest content',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = _SlowSubmissionDataSource()..ready.complete([]);
    final longAnswer = List.generate(80, (i) => 'Answer line $i').join('\n\n');
    AxWorkRequest running(String status) => AxWorkRequest(
          id: 'running-1',
          requestedByName: 'You',
          requestedByUserId: 'user-owner',
          prompt: 'First request',
          workflowId: 'direct',
          workflowVersion: 1,
          status: status,
          createdAt: '2026-10-06T10:00:00Z',
          steps: const [],
          finalText: status == 'completed' ? 'Done' : null,
        );
    final earlier = AxWorkRequest(
      id: 'earlier-1',
      requestedByName: 'You',
      requestedByUserId: 'user-owner',
      prompt: 'Earlier request',
      workflowId: 'direct',
      workflowVersion: 1,
      status: 'completed',
      createdAt: '2026-10-06T09:00:00Z',
      steps: const [],
      finalText: longAnswer,
    );
    data.requests = [earlier, running('running')];
    Widget page() => MaterialApp(
            home: Scaffold(
                body: ThreadPage(
          initialTab: 1,
          space: const AxSpace(
              id: 'space-1',
              name: 'Space',
              branch: '',
              lastActivity: '',
              role: 'owner'),
          thread: const AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Stream',
              lead: '',
              status: 'active',
              brief: '',
              primaryWorkspace: '',
              queueStatus: ''),
          dataSource: data,
          currentUserId: 'user-owner',
          onBackToSpace: _noop,
          onArchive: _noop,
          onRunWork: (prompt, __, ___, key) async {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            return 'saved-1';
          },
        )));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await _askAi(tester);
    await tester.enterText(find.byType(TextField).first, 'Queued follow-up');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('work-queue-panel')), findsOneWidget);

    // Leaving the Thread page and returning keeps the queued message.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await _askAi(tester);
    expect(find.byKey(const ValueKey('work-queue-panel')), findsOneWidget);
    expect(find.textContaining('Queued follow-up'), findsWidgets);

    ScrollPosition history() => tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .map((state) => state.position)
        .where((position) => position.extentBefore + position.extentAfter > 0)
        .reduce((a, b) =>
            a.extentBefore + a.extentAfter >= b.extentBefore + b.extentAfter
                ? a
                : b);
    // The reader scrolls up while the first request is still running.
    history().jumpTo(history().minScrollExtent);
    await tester.pumpAndSettle();
    expect(history().extentBefore, 0);

    // It finishes; the queued message is sent and the view follows it.
    data.requests = [earlier, running('completed')];
    await AxWorkHistoryCache.forSource(data).refresh('thread-1');
    await tester.pump();
    // The reader is still scrolled up while the queued send is in flight.
    history().jumpTo(history().minScrollExtent);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('work-queue-panel')), findsNothing);
    final position = history();
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    expect(tester.takeException(), isNull);
    // Leaving with messages queued would start the background sender.
    ThreadPage.resetWorkQueues();
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Chat and Work controls stay fixed while history scrolls',
      (tester) async {
    for (final tab in [0, 1]) {
      final data = _PinnedHistoryDataSource();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
        key: ValueKey(tab),
        space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: const AxThread(
            id: 'thread-1',
            spaceId: 'space-1',
            name: 'Stream',
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: ''),
        dataSource: data,
        onBackToSpace: _noop,
        onArchive: _noop,
      ))));
      await tester.pumpAndSettle();
      // Work Requests are part of the one conversation; tab 1 composes them.
      if (tab == 1) await _askAi(tester);
      final history = find.byKey(const ValueKey('chat-history-scroll'));
      final field = find.byType(TextField).last;
      final before = tester.getRect(field);
      final scrollable =
          find.descendant(of: history, matching: find.byType(Scrollable)).first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.extentBefore, greaterThan(0));
      expect(position.extentAfter, closeTo(0, 1));
      await tester.drag(history, const Offset(0, 250));
      await tester.pumpAndSettle();
      expect(position.extentAfter, greaterThan(24));
      final readingOffset = position.pixels;
      // Changing the composer rebuilds the page without pulling the reader down.
      await tester.enterText(field, 'A new draft');
      if (tab == 1) {
        data.requests = [
          ...data.requests,
          _workRequest('new-result', 'completed')
        ];
        await AxWorkHistoryCache.forSource(data).refresh('thread-1');
      }
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(readingOffset, 1));
      await tester.drag(history, const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(position.extentAfter, lessThanOrEqualTo(24));
      if (tab == 1) {
        data.requests = [
          ...data.requests,
          _workRequest('another-result', 'completed')
        ];
        await AxWorkHistoryCache.forSource(data).refresh('thread-1');
        await tester.pumpAndSettle();
        expect(position.extentAfter, closeTo(0, 1));
      }
      expect(position.extentBefore, greaterThan(0));
      expect(tester.getRect(field), before);
      expect(find.ancestor(of: field, matching: history), findsNothing);
      if (tab == 1) {
        expect(find.byKey(const ValueKey('composer-send-Send request')),
            findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }
  });
  for (final missingRequesterId in [false, true]) {
    testWidgets(
        'conversation spaces Work by its visible authors and hides meta backgrounds${missingRequesterId ? ' without requester ID' : ''}',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          home: Scaffold(
              body: ThreadPage(
            space: const AxSpace(
                id: 'space-1',
                name: 'Space',
                branch: '',
                lastActivity: '',
                role: 'owner'),
            thread: const AxThread(
                id: 'thread-1',
                spaceId: 'space-1',
                name: 'Stream',
                lead: '',
                status: 'active',
                brief: '',
                primaryWorkspace: '',
                queueStatus: ''),
            dataSource: _ConversationMixDataSource(
                otherAfter: true, missingRequesterId: missingRequesterId),
            currentUserId: 'user-owner',
            currentUserName: 'Vitalii',
            onBackToSpace: _noop,
            onArchive: _noop,
          ))));
      await tester.pumpAndSettle();
      final before = find.byKey(const ValueKey('m1'));
      final work = find.byKey(const ValueKey('work-R-request'));
      final after = find.byKey(const ValueKey('m2'));
      // The Chat message and prompt share an author despite their hour-long gap.
      expect(tester.getTopLeft(work).dy - tester.getBottomLeft(before).dy, 2);
      // The card ends with a Worker, so the following human starts a new group.
      expect(tester.getTopLeft(after).dy - tester.getBottomLeft(work).dy, 20);

      final backgrounds = find.descendant(
          of: work,
          matching: find.byWidgetPredicate((widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).gradient != null));
      expect(backgrounds, findsNWidgets(2));
      for (final background in backgrounds.evaluate()) {
        final opacity = find
            .ancestor(
                of: find.byElementPredicate((element) => element == background),
                matching: find.byType(AnimatedOpacity))
            .first;
        expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
      }
      final otherBackground = find.descendant(
          of: after,
          matching: find.byWidgetPredicate((widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).gradient != null));
      expect(otherBackground, findsOneWidget);
      final otherOpacity = find
          .ancestor(of: otherBackground, matching: find.byType(AnimatedOpacity))
          .first;
      expect(tester.widget<AnimatedOpacity>(otherOpacity).opacity, 0);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(tester.getCenter(find.text('Use passkeys')));
      await tester.pumpAndSettle();
      final workerBackground = backgrounds.last;
      final workerOpacity = find
          .ancestor(
              of: workerBackground, matching: find.byType(AnimatedOpacity))
          .first;
      expect(tester.widget<AnimatedOpacity>(workerOpacity).opacity, 1);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(workerOpacity).opacity, 0);
      await mouse.moveTo(tester.getCenter(find.text('After AI')));
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(otherOpacity).opacity, 1);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(otherOpacity).opacity, 0);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('five consecutive own messages keep tight gaps after sending',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = _FiveOwnMessagesSource();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'thread-1',
          spaceId: 'space-1',
          name: 'Chat',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: source,
      currentUserId: 'user-owner',
      onBackToSpace: _noop,
      onArchive: _noop,
    ))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Own message 5');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send message')));
    await tester.pumpAndSettle();
    for (var index = 2; index <= 5; index++) {
      final row = find.byKey(ValueKey('own-$index'));
      final previous = find.byKey(ValueKey('own-${index - 1}'));
      expect(tester.getTopLeft(row).dy - tester.getBottomLeft(previous).dy,
          closeTo(2, 0.01),
          reason: 'gap before own message $index');
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets('conversation interleaves Work with Chat and Ask AI runs Work',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? sent;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'thread-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: '',
          canExecuteWork: true),
      dataSource: _ConversationMixDataSource(),
      currentUserId: 'user-owner',
      onBackToSpace: _noop,
      onArchive: _noop,
      onRunWork: (source, _, __, ___) async {
        sent = source;
        return 'request-new';
      },
    ))));
    await tester.pumpAndSettle();
    final history = find.byKey(const ValueKey('chat-history-scroll'));
    double top(String text) => tester
        .getTopLeft(find.descendant(of: history, matching: find.text(text)))
        .dy;
    // Chat and Work read as one timeline in time order.
    expect(top('Before AI'), lessThan(top('Research auth')));
    expect(top('Research auth'), lessThan(top('Use passkeys')));
    expect(top('Use passkeys'), lessThan(top('After AI')));
    expect(find.byKey(const ValueKey('work-history-scroll')), findsNothing);
    // The live request is not a Chat message: only the two Chat messages
    // can be edited or deleted.
    expect(find.byTooltip('Copy'), findsWidgets);
    expect(find.byTooltip('Edit'), findsNWidgets(2));
    expect(find.byTooltip('Delete'), findsNWidgets(2));

    await _askAi(tester);
    await tester.enterText(find.byType(TextField).last, 'Next request');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(sent, 'Next request');
  });
  testWidgets('Thread header scopes clear and reset actions to each tab',
      (tester) async {
    final cleared = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'thread-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: const AxFixtureDataSource(),
      onBackToSpace: _noop,
      onArchive: _noop,
      onClearConversation: () async => cleared.add('conversation'),
      onClearAiHistory: () async => cleared.add('ai'),
    ))));
    await tester.pumpAndSettle();
    final conversation =
        find.byKey(const ValueKey('clear-conversation-history'));
    final reset = find.byKey(const ValueKey('reset-ai-context'));
    expect(conversation, findsOneWidget);
    expect(reset, findsOneWidget);
    expect(find.byTooltip('Reset AI context'), findsOneWidget);
    final clearIcon = tester.widget<Icon>(
      find.descendant(of: conversation, matching: find.byType(Icon)),
    );
    final resetIcon = tester.widget<Icon>(
      find.descendant(of: reset, matching: find.byType(Icon)),
    );
    expect(clearIcon.size, 18);
    expect(resetIcon.size, clearIcon.size);
    // Cancelling the confirmation clears nothing.
    await tester.tap(conversation);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cleared, isEmpty);
    await tester.tap(conversation);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(cleared, ['conversation']);

    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(find.textContaining('The visible conversation stays available'),
        findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(cleared, ['conversation', 'ai']);

    await _openAiHistory(tester);
    expect(find.byKey(const ValueKey('reset-ai-context')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('clear-conversation-history')), findsNothing);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(find.textContaining('The visible conversation stays available'),
        findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(cleared, ['conversation', 'ai', 'ai']);
  });

  testWidgets('Chat shows archived AI exchanges as read-only Worker answers',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                height: 600,
                child: ThreadPage(
                  space: const AxSpace(
                      id: 'space-1',
                      name: 'Space',
                      branch: '',
                      lastActivity: '',
                      role: 'owner'),
                  thread: const AxThread(
                      id: 'stream-1',
                      spaceId: 'space-1',
                      name: 'Chat',
                      lead: '',
                      status: 'active',
                      brief: '',
                      primaryWorkspace: '',
                      queueStatus: ''),
                  dataSource: _ArchivedAiDiscussionDataSource(),
                  currentUserId: 'user-owner',
                  onBackToSpace: _noop,
                  onArchive: _noop,
                )))));
    await tester.pumpAndSettle();
    expect(find.text('Research auth'), findsOneWidget);
    expect(find.text('Use passkeys'), findsOneWidget);
    expect(find.text('ChatGPT'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('chat-history-scroll')),
            matching: find.byIcon(Icons.auto_awesome_rounded)),
        findsOneWidget);
    expect(
        find.byWidgetPredicate((widget) =>
            widget is Text && widget.data?.startsWith('Asked AI · ') == true),
        findsOneWidget);
    // Archived AI entries are history: neither the request nor the answer
    // may be edited.
    expect(find.byTooltip('Edit'), findsNothing);
    // Each entry offers Reply and Copy.
    expect(find.byTooltip('Reply'), findsNWidgets(2));
    expect(find.byTooltip('Copy'), findsNWidgets(2));
  });
  testWidgets('Chat create edit and copy preserve raw Markdown',
      (tester) async {
    final ds = _MarkdownDiscussionDataSource();
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.binding.setSurfaceSize(const Size(1300, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                height: 600,
                child: ThreadPage(
                  space: const AxSpace(
                      id: 'space-1',
                      name: 'Space',
                      branch: '',
                      lastActivity: '',
                      role: 'owner'),
                  thread: const AxThread(
                      id: 'stream-1',
                      spaceId: 'space-1',
                      name: 'Chat',
                      lead: '',
                      status: 'active',
                      brief: '',
                      primaryWorkspace: '',
                      queueStatus: ''),
                  dataSource: ds,
                  currentUserId: 'user-owner',
                  onBackToSpace: _noop,
                  onArchive: _noop,
                )))));
    await tester.pumpAndSettle();
    const source = '  **raw**\n\n```dart\nfinal x = 1;\n```\n';
    await tester.enterText(find.byType(TextField).first, source);
    await tester.tap(find.byKey(const ValueKey('composer-send-Send message')));
    await tester.pumpAndSettle();
    expect(ds.createdSource, source);
    final timestamp = find.byWidgetPredicate((widget) =>
        widget is Text && widget.data?.startsWith('2026-10-06 ·') == true);
    expect(timestamp, findsOneWidget);
    expect(tester.getTopLeft(timestamp).dx,
        lessThan(tester.getTopLeft(find.byTooltip('Reply')).dx));
    await _chooseMessageAction(tester, 'Edit');
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        source);
    const edited = '\n> **edited**\n- [ ] task\n  ';
    await tester.enterText(find.byType(TextField).first, edited);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(ds.editedSource, edited);
    await _chooseMessageAction(tester, 'Copy');
    await tester.pump();
    expect(copied, edited);
  });
  testWidgets('Reply quotes the chosen message in the next message',
      (tester) async {
    final ds = _MarkdownDiscussionDataSource();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                height: 600,
                child: ThreadPage(
                  space: const AxSpace(
                      id: 'space-1',
                      name: 'Space',
                      branch: '',
                      lastActivity: '',
                      role: 'owner'),
                  thread: const AxThread(
                      id: 'stream-1',
                      spaceId: 'space-1',
                      name: 'Chat',
                      lead: '',
                      status: 'active',
                      brief: '',
                      primaryWorkspace: '',
                      queueStatus: ''),
                  dataSource: ds,
                  currentUserId: 'user-owner',
                  onBackToSpace: _noop,
                  onArchive: _noop,
                )))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'First question');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send message')));
    await tester.pumpAndSettle();
    expect(ds.createdReplyTo, isNull);

    await _chooseMessageAction(tester, 'Reply');
    expect(find.byKey(const ValueKey('reply-composer-banner')), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Follow-up');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send message')));
    await tester.pumpAndSettle();
    expect(ds.createdReplyTo, {'kind': 'message', 'id': 'saved-message'});
    final quote = find.byKey(const ValueKey('reply-quote-saved-message'));
    expect(quote, findsOneWidget);
    await tester.tap(quote);
    await tester.pumpAndSettle();
    expect(find.text('Original message unavailable'), findsNothing);
    expect(find.text('First question'), findsWidgets);

    expect(find.byKey(const ValueKey('reply-composer-banner')), findsNothing);

    // The quote jumped back to the first message; the latest one sits under
    // the composer.
    await _chooseMessageAction(tester, 'Reply',
        action: find.byTooltip('Reply').first);
    await tester.tap(find.byKey(const ValueKey('reply-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reply-composer-banner')), findsNothing);
  });
  testWidgets('Work copies exact Markdown for prompt and fallback response',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    const prompt = '  **Prompt** [link](https://example.com)\n';
    const response = '\n**Response**\n\n```json\n{"ready":true}\n```\n  ';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
      height: 700,
      child: ThreadPage(
        space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: const AxThread(
            id: 'thread-1',
            spaceId: 'space-1',
            name: 'Work',
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: ''),
        dataSource: _WorkHistoryDataSource([
          const AxWorkRequest(
              id: 'request-1',
              requestedByName: 'You',
              prompt: prompt,
              workflowId: 'direct',
              workflowVersion: 1,
              status: 'completed',
              createdAt: '2026-10-01T10:00:00Z',
              steps: [
                AxWorkRequestStep(
                    kind: 'implement',
                    status: 'completed',
                    workerId: null,
                    resultText: response),
              ]),
        ]),
        initialTab: 1,
        onBackToSpace: _noop,
        onArchive: _noop,
      ),
    ))));
    await tester.pumpAndSettle();
    final copies = find.byTooltip('Copy');
    expect(copies, findsNWidgets(2));
    expect(find.byTooltip('Edit'), findsNothing);
    expect(find.byTooltip('Delete'), findsNothing);
    final platform = Theme.of(tester.element(copies.first)).platform;
    final side =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android
            ? 40.0
            : 28.0;
    expect(tester.getSize(copies.first), Size.square(side));
    await _chooseMessageAction(tester, 'Copy', action: copies.first);
    expect(copied, prompt);
    expect(find.text('Prompt copied to clipboard'), findsNothing);
    await _chooseMessageAction(tester, 'Copy', action: copies.last);
    expect(copied, response);
    final timestamps = find.byWidgetPredicate((widget) =>
        widget is Text && widget.data?.startsWith('2026-10-01 ·') == true);
    expect(timestamps, findsNWidgets(2));
  });

  testWidgets('Run failure copies the complete message', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    const message =
        'Cannot run Work\n• The Space Workspace grant does not allow the access this Step needs.';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
      height: 600,
      child: ThreadPage(
        space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: const AxThread(
            id: 'thread-1',
            spaceId: 'space-1',
            name: 'Chat',
            lead: 'Owner',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: 'idle',
            canExecuteWork: true),
        dataSource: _WorkFormDataSource(),
        onBackToSpace: _noop,
        onArchive: _noop,
        onRunWork: (_, __, ___, key) async =>
            throw const AxApiException(message),
      ),
    ))));
    await tester.pumpAndSettle();
    await _askAi(tester);
    await tester.enterText(find.byType(TextField).last, 'Implement the change');
    await tester.ensureVisible(
        find.byKey(const ValueKey('composer-send-Send request')));
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    // The failure diagnostic lives in AI History.
    await tester.tap(find.byKey(const ValueKey('ai-history-toggle')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Copy').last);
    await tester.tap(find.byTooltip('Copy').last);
    await tester.pumpAndSettle();
    expect(copied, message);
    final diagnostic = tester.widget<SelectableText>(find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == message));
    final body = SyntilaMessageTypography.fromTheme(
        Theme.of(tester.element(find.byType(ThreadPage))));
    expect(diagnostic.style?.fontFamily, body.fontFamily);
    expect(diagnostic.style?.fontSize, body.fontSize);
    expect(diagnostic.style?.height, body.height);
  });
  testWidgets('Space page exposes actions and only the Threads resource',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    var edited = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: const AxSpace(
              id: 'space-1',
              name: 'Space One',
              description: 'Shared space for Space One',
              instructions: 'Follow standard engineering practices.',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: const AxFixtureDataSource(),
            onOpenThread: (_) {},
            onSaveEdits: (name, description) async {
              edited = true;
              return null;
            },
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Verify Header items
    expect(find.text('Space One'), findsOneWidget);
    expect(find.text('Shared space for Space One'), findsOneWidget);
    expect(find.text('Follow standard engineering practices.'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.byTooltip('Space actions'), findsOneWidget);

    // Open 3-dots popup menu
    await tester.tap(find.byTooltip('Space actions'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    // Editing happens inline in the page header, not in a dialog.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('space-edit-form')), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Space One'), '');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Space name cannot be empty.'), findsOneWidget);
    expect(edited, isFalse);
    await tester.enterText(find.byType(TextField).first, 'Space Two');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(edited, isTrue);
    expect(find.byKey(const ValueKey('space-edit-form')), findsNothing);

    expect(find.byType(TabBar), findsNothing);
    expect(find.text('Threads'), findsOneWidget);
    expect(find.byTooltip('Create Thread'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Space page updates description when switching spaces',
      (tester) async {
    const p1 = AxSpace(
      id: 'space-1',
      name: 'Space One',
      description: 'First space description',
      branch: '',
      lastActivity: 'today',
    );
    const p2 = AxSpace(
      id: 'space-2',
      name: 'Space Two',
      description: 'Second space description',
      branch: '',
      lastActivity: 'today',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: p1,
            dataSource: const AxFixtureDataSource(),
            onOpenThread: (_) {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('First space description'), findsOneWidget);
    expect(find.text('Second space description'), findsNothing);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: p2,
            dataSource: const AxFixtureDataSource(),
            onOpenThread: (_) {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('First space description'), findsNothing);
    expect(find.text('Second space description'), findsOneWidget);
  });

  testWidgets('Thread shell exposes Chat and Work with viewer-safe controls',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: ThreadPage(
            space: AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'viewer',
            ),
            thread: AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Research',
              lead: 'Owner',
              status: 'active',
              brief: 'Understand the problem.',
              primaryWorkspace: 'Not selected',
              queueStatus: 'Idle',
            ),
            onBackToSpace: _noop,
            onArchive: _noop,
            initialTab: 1,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await _openAiHistory(tester);
    expect(find.text('AI History'), findsOneWidget);
    expect(find.text('Read-only'), findsNothing);
    expect(find.text('Archive'), findsNothing);
    expect(find.text('What should Syntila do?'), findsNothing);
    expect(
        find.text(
            'Ask AI to do something for the team. Nothing runs until you send the request.'),
        findsOneWidget);
    expect(find.textContaining('lease'), findsNothing);
    expect(find.textContaining('fencing'), findsNothing);
    expect(find.textContaining('Durable Object'), findsNothing);
    expect(find.textContaining('checkout key'), findsNothing);
    await _askAi(tester);
    expect(find.text('Conversation'), findsOneWidget);
    expect(find.text('Viewer access can read the thread but cannot run Work.'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('composer-send-Send request')),
        findsOneWidget);
  });

  testWidgets('composer icon buttons are 32px with 20px icons in both modes',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: ThreadPage(
            space: const AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            thread: const AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Implementation',
              lead: 'Owner',
              status: 'active',
              brief: 'Implement the requested change.',
              primaryWorkspace: 'Workspace One',
              queueStatus: 'Idle',
              canExecuteWork: true,
            ),
            dataSource: _WorkFormDataSource(),
            onBackToSpace: _noop,
            onArchive: _noop,
            onRunWork: (work, workflowId, attachments, key) async =>
                'request-1',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    void square(String key, {bool icon = true}) {
      final finder = find.byKey(ValueKey(key));
      expect(finder, findsOneWidget, reason: key);
      expect(tester.getSize(finder), const Size(32, 32), reason: key);
      if (icon) {
        final glyph = find.descendant(of: finder, matching: find.byType(Icon));
        expect(tester.widget<Icon>(glyph.first).size, 20, reason: key);
      }
    }

    double bottomPanel() {
      final composer = find.byType(MarkdownComposer);
      return tester.getBottomLeft(composer).dy -
          tester.getBottomLeft(find.byType(TextField).first).dy;
    }

    square('composer-mode-message');
    square('composer-mode-ai');
    square('composer-send-Send message');
    square('message-add-attachments');
    final messagePanel = bottomPanel();
    final messageHeight = tester.getSize(find.byType(MarkdownComposer)).height;

    await _askAi(tester);
    square('composer-mode-message');
    square('composer-mode-ai');
    square('composer-send-Send request');
    square('work-add-attachments');
    // Toggles share the 32px height; their widths follow their labels.
    for (final key in ['work-toggle-chat', 'work-toggle-direct']) {
      expect(tester.getSize(find.byKey(ValueKey(key))).height, 32, reason: key);
    }
    expect(
        tester.getSize(find.byKey(const ValueKey('work-composer-open'))).height,
        32);
    expect(bottomPanel(), 44);
    expect(messagePanel, 44);
    expect(tester.getSize(find.byType(MarkdownComposer)).height, messageHeight);
    debugDefaultTargetPlatformOverride = null;
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('collaborator can explicitly run Work', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    String? submittedWork;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: ThreadPage(
            space: const AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            thread: const AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Implementation',
              lead: 'Owner',
              status: 'active',
              brief: 'Implement the requested change.',
              primaryWorkspace: 'Workspace One',
              queueStatus: 'Idle',
              canExecuteWork: true,
            ),
            dataSource: _WorkFormDataSource(),
            onBackToSpace: _noop,
            onArchive: _noop,
            onRunWork: (work, workflowId, attachments, key) async {
              submittedWork = work;
              return 'request-1';
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await _askAi(tester);

    expect(find.text('What should Syntila do?'), findsNothing);
    expect(find.byKey(const ValueKey('work-add-attachments')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('work-add-attachments')));
    await tester.pumpAndSettle();
    expect(find.text('Add files'), findsOneWidget);
    expect(find.byTooltip('Add attachments'), findsNothing);
    expect(find.byTooltip('Choose workflow'), findsNothing);
    expect(find.byTooltip('Send request'), findsNothing);

    expect(
        find.ancestor(
            of: find.text('Add files'), matching: find.byType(InkWell)),
        findsOneWidget);

    expect(find.text('Add link'), findsNothing);
    expect(
        tester.getBottomLeft(find.text('Add files')).dy,
        lessThan(tester
            .getTopLeft(find.byKey(const ValueKey('work-add-attachments')))
            .dy));
    final menu = find
        .ancestor(
            of: find.text('Add files'),
            matching: find.byWidgetPredicate(
                (widget) => widget is Material && widget.elevation == 12))
        .first;
    expect(
        tester.getBottomLeft(menu).dy,
        closeTo(
            tester
                    .getTopLeft(
                        find.byKey(const ValueKey('work-add-attachments')))
                    .dy -
                8,
            1));
    expect(
        tester.widget<Material>(menu).color,
        SyntilaColors.composerBackground(
            Theme.of(tester.element(menu)).brightness == Brightness.dark));
    expect(
        (tester.widget<Material>(menu).shape as RoundedRectangleBorder)
            .borderRadius,
        BorderRadius.circular(14));
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('work-choose-workflow')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('work-toggle-direct')));
    await tester.pumpAndSettle();
    expect(find.text('More'), findsNothing);
    const markdownPrompt =
        '  ## Implementation\n\n- **Add tests**\n\n```dart\nfinal ready = true;\n```\n';
    expect(find.byTooltip('Show Markdown controls'), findsNothing);
    expect(find.byTooltip('Bold'), findsNothing);
    expect(
        tester
            .widget<TextField>(find.byType(TextField).first)
            .decoration
            ?.hintText,
        'Write a message...');
    await tester.enterText(find.byType(TextField).first, markdownPrompt);
    expect(
        tester
            .getCenter(find.byKey(const ValueKey('composer-send-Send request')))
            .dx,
        greaterThan(tester
            .getCenter(find.byKey(const ValueKey('work-toggle-direct')))
            .dx));
    expect(submittedWork, isNull);
    await tester.ensureVisible(
        find.byKey(const ValueKey('composer-send-Send request')));
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();

    expect(submittedWork, markdownPrompt);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Thread Work tab uses Space Workflows without thread settings',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    final dataSource = _GenericWorkerConfigDataSource();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: ThreadPage(
            space: const AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            thread: const AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Implementation',
              lead: 'Owner',
              status: 'active',
              brief: 'Implement the requested change.',
              primaryWorkspace: 'Not selected',
              queueStatus: 'Idle',
              canConfigureWork: true,
            ),
            dataSource: dataSource,
            onBackToSpace: _noop,
            onArchive: _noop,
            initialTab: 2,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.byTooltip('Work settings'), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('request history lists newest last; Up selects the newest',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 700,
          child: ThreadPage(
            space: const AxSpace(
                id: 'space-1',
                name: 'Space',
                branch: '',
                lastActivity: '',
                role: 'owner'),
            thread: const AxThread(
                id: 'thread-1',
                spaceId: 'space-1',
                name: 'Stream',
                lead: '',
                status: 'active',
                brief: '',
                primaryWorkspace: '',
                queueStatus: ''),
            dataSource: _HistoryPromptDataSource([
              _workRequest('request-1', 'Older prompt'),
              _workRequest('request-2', 'Newer prompt'),
            ]),
            currentUserId: 'user-owner',
            onBackToSpace: _noop,
            onArchive: _noop,
            initialTab: 1,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpAndSettle();
    await _askAi(tester);
    final composer = find.byType(TextField).last;
    await tester.showKeyboard(composer);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('request-history-list'));
    final older =
        find.descendant(of: list, matching: find.text('Older prompt'));
    final newer =
        find.descendant(of: list, matching: find.text('Newer prompt'));
    expect(tester.getTopLeft(older).dy, lessThan(tester.getTopLeft(newer).dy));
    for (final width in [1400.0, 390.0]) {
      await tester.binding.setSurfaceSize(Size(width, 900));
      await tester.pumpAndSettle();
      final history =
          tester.getRect(find.byKey(const ValueKey('request-history-panel')));
      final layer = tester.getRect(
          find.byKey(const ValueKey('request-history-layer-background')));
      final input = tester.getRect(find.byType(MarkdownComposer));
      expect(history.bottom, input.top);
      expect(history.left, input.left + 40);
      expect(history.right, input.right - 40);
      expect(layer.bottom, input.top + 10);
      expect(older.hitTestable(), findsOneWidget);
      expect(newer.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer).controller!.text, 'Newer prompt');
    expect(list, findsNothing);

    await tester.enterText(composer, '');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(list, findsNothing);
    expect(tester.widget<TextField>(composer).focusNode!.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.tap(older);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer).controller!.text, 'Older prompt');
    expect(list, findsNothing);

    // The + menu works with a draft on both phone and desktop widths.
    for (final width in [390.0, 1400.0]) {
      await tester.binding.setSurfaceSize(Size(width, 900));
      await tester.pumpAndSettle();
      await tester.enterText(composer, 'Unsent draft');
      await tester.tap(find.byKey(const ValueKey('work-add-attachments')));
      await tester.pumpAndSettle();
      expect(find.text('Add files'), findsOneWidget);
      await tester.tap(find.text('Request history'));
      await tester.pumpAndSettle();
      expect(list, findsOneWidget);
      expect(
          tester.widget<TextField>(composer).controller!.text, 'Unsent draft');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(list, findsNothing);
      expect(
          tester.widget<TextField>(composer).controller!.text, 'Unsent draft');

      await tester.tap(find.byKey(const ValueKey('work-add-attachments')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Request history'));
      await tester.pumpAndSettle();
      await tester.tap(newer);
      await tester.pumpAndSettle();
      expect(
          tester.widget<TextField>(composer).controller!.text, 'Newer prompt');
      expect(list, findsNothing);
    }
  });

  testWidgets(
      'AI History shows requests; tapping one shows or hides its response',
      (tester) async {
    final dataSource = _WorkHistoryDataSource([
      _workRequest('done', 'Line one\nLine two'),
      _workRequest('busy', 'Still working', status: 'running'),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 800,
          child: ThreadPage(
            space: const AxSpace(
                id: 'space-1',
                name: 'Space One',
                branch: '',
                lastActivity: 'today',
                role: 'owner'),
            thread: const AxThread(
                id: 'thread-1',
                spaceId: 'space-1',
                name: 'Implementation',
                lead: 'Owner',
                status: 'active',
                brief: '',
                primaryWorkspace: '',
                queueStatus: 'Idle'),
            dataSource: dataSource,
            currentUserId: 'user-owner',
            onBackToSpace: _noop,
            onArchive: _noop,
            initialTab: 1,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await _openAiHistory(tester, showResponses: false);
    // Requests use the Conversation's request bubble. A finished response
    // starts hidden; one still processing stays open to show progress.
    expect(_inAiHistory(find.text('Line one\nLine two')), findsOneWidget);
    expect(_inAiHistory(find.text('Still working')), findsOneWidget);
    expect(_inAiHistory(find.text('Request completed.')), findsNothing);

    final done = find.byKey(const ValueKey('ai-history-request-done'));
    final top = tester.getTopLeft(done).dy;
    await tester.tap(done);
    await tester.pumpAndSettle();
    expect(_inAiHistory(find.text('Request completed.')), findsOneWidget);
    // The tapped request stays where it was; its response opens below it.
    expect(tester.getTopLeft(done).dy, top);

    await tester.tap(done);
    await tester.pumpAndSettle();
    expect(_inAiHistory(find.text('Request completed.')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Work history uses slow fallback and scoped reconnect discovery',
      (tester) async {
    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);
    final dataSource = _WorkHistoryDataSource([
      _workRequest('request-1', 'History before reconnect', status: 'running'),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: ThreadPage(
            space: const AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            thread: const AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Implementation',
              lead: 'Owner',
              status: 'active',
              brief: 'Implement the requested change.',
              primaryWorkspace: 'Workspace One',
              queueStatus: 'Idle',
            ),
            dataSource: dataSource,
            currentUserId: 'user-owner',
            realtimeEvents: events.stream,
            onBackToSpace: _noop,
            onArchive: _noop,
            initialTab: 1,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await _openAiHistory(tester);
    expect(find.text('History before reconnect'), findsOneWidget);
    final initialHistoryReads = dataSource.activeOnlyCalls.length;
    events.add({
      'type': 'thread.updated',
      'threadId': 'thread-1',
      'payload': {'threadId': 'thread-1'},
    });
    await tester.pump();
    await tester.pumpAndSettle();
    expect(dataSource.activeOnlyCalls.length, initialHistoryReads);
    events.add({
      'type': 'thread.work_cleared',
      'threadId': 'thread-1',
      'payload': {'threadId': 'thread-1'},
    });
    await tester.pump();
    await tester.pumpAndSettle();
    expect(dataSource.activeOnlyCalls.length, greaterThan(initialHistoryReads));
    dataSource.requests = [
      const AxWorkRequest(
        id: 'request-1',
        requestedByName: 'Owner',
        prompt: 'History before reconnect',
        workflowId: 'direct',
        workflowVersion: 1,
        status: 'completed',
        createdAt: '2026-10-01T10:00:00.000Z',
        steps: [
          AxWorkRequestStep(
              kind: 'implement',
              status: 'completed',
              workerId: 'worker-1',
              resultText: 'The requested change is complete.')
        ],
      )
    ];
    // A missing WebSocket notification must not leave the reply hidden.
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(find.text('The requested change is complete.'), findsOneWidget);
    expect(find.text('Implement'), findsNothing);
    expect(find.text('Syntila'), findsOneWidget);
    expect(
      tester
          .widgetList<SyntilaMarkdownBody>(find.byType(SyntilaMarkdownBody))
          .map((body) => body.data),
      contains('The requested change is complete.'),
    );

    dataSource.requests = [
      _workRequest('request-1', 'History restored after reconnect'),
      _workRequest('request-2', 'Run submitted while the browser was away'),
    ];
    events.add({'type': 'reconnect.required'});
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(dataSource.activeOnlyCalls, contains(false));
    expect(find.text('History before reconnect'), findsNothing);
    expect(find.text('History restored after reconnect'), findsOneWidget);
    expect(
        find.text('Run submitted while the browser was away'), findsOneWidget);
    expect(find.text('Owner'), findsNothing);
  });

  testWidgets('Chat messages can be sent and copied to clipboard',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: ThreadPage(
            space: AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            thread: AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Research',
              lead: 'Owner',
              status: 'active',
              brief: 'Understand the problem.',
              primaryWorkspace: 'Workspace One',
              queueStatus: 'Idle',
            ),
            onBackToSpace: _noop,
            onArchive: _noop,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last,
        'The login failure reproduces on a fresh checkout.');
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('composer-send-Send message')), 500,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const ValueKey('composer-send-Send message')));
    await tester.pumpAndSettle();
    expect(find.text('The login failure reproduces on a fresh checkout.'),
        findsOneWidget);
    expect(find.text('You'), findsNothing);
    final ownMessageBubble = find.ancestor(
      of: find.text('The login failure reproduces on a fresh checkout.'),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).color ==
                SyntilaColors.ownMessageBackground(false),
      ),
    );
    expect(ownMessageBubble, findsOneWidget);
    // The actions are laid over the bubble's bottom-right corner.
    final bubbleRight = tester.getTopRight(ownMessageBubble).dx;
    final actionsRight = tester.getTopRight(find.byTooltip('Copy')).dx;
    expect(bubbleRight - actionsRight, closeTo(14, 0.1));

    // Verify copy message button exists and triggers
    expect(find.byTooltip('Copy'), findsOneWidget);
    await _chooseMessageAction(tester, 'Copy');
    await tester.pumpAndSettle();
    expect(find.text('Message copied to clipboard'), findsNothing);

    // Verify edit message button allows editing in-place
    expect(find.byTooltip('Copy'), findsOneWidget);
    await _chooseMessageAction(tester, 'Edit');
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(
            TextField, 'The login failure reproduces on a fresh checkout.'),
        'The login failure reproduces on a fresh checkout. (Updated)');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'The login failure reproduces on a fresh checkout. (Updated)'),
        findsOneWidget);

    // Verify delete message button shows confirmation and removes message
    expect(find.byTooltip('Copy'), findsOneWidget);
    await _chooseMessageAction(tester, 'Delete');
    await tester.pumpAndSettle();
    expect(find.text('Delete message?'), findsOneWidget);
    expect(
        find.text(
            'Are you sure you want to delete this message? This action cannot be undone.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'The login failure reproduces on a fresh checkout. (Updated)'),
        findsOneWidget);

    await _chooseMessageAction(tester, 'Delete');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'The login failure reproduces on a fresh checkout. (Updated)'),
        findsNothing);

    // Multiline Markdown source is submitted through the Send action.
    await tester.enterText(
        find.byType(TextField).last, 'Line 1\nLine 2 details');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send message')));
    await tester.pumpAndSettle();
    expect(find.text('Line 1\nLine 2 details'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Chat messages show their calendar date', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final config in [
      (true, TargetPlatform.iOS),
      (false, TargetPlatform.android),
      (true, TargetPlatform.macOS),
      (false, TargetPlatform.windows),
    ]) {
      final own = config.$1;
      final touch = config.$2 == TargetPlatform.iOS ||
          config.$2 == TargetPlatform.android;
      await tester.binding.setSurfaceSize(Size(touch ? 390 : 1200, 1200));
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: config.$2),
        home: Scaffold(
          body: ThreadPage(
            key: ValueKey(config),
            space: const AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            thread: const AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Research',
              lead: 'Owner',
              status: 'active',
              brief: 'Understand the problem.',
              primaryWorkspace: 'Workspace One',
              queueStatus: 'Idle',
            ),
            dataSource: _DiscussionDataSource(),
            currentUserId: own ? 'user-owner' : 'another-user',
            onBackToSpace: _noop,
            onArchive: _noop,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text && widget.data?.startsWith('2026-10-05 ·') == true,
        ),
        findsOneWidget,
      );
      final date = find.byWidgetPredicate((widget) =>
          widget is Text && widget.data?.startsWith('2026-10-05 ·') == true);
      final reply = find.byTooltip('Reply');
      final trigger = find.byTooltip('Copy');
      final dateX = tester.getTopLeft(date).dx;
      final bubbleFinder = find
          .ancestor(
              of: find.byType(SyntilaMarkdownBody).first,
              matching: find.byType(Container))
          .first;
      final bubble = tester.widget<Container>(bubbleFinder);
      // The background sits on the wrapper that also carries the overlaid
      // date/time and actions.
      final background = find
          .ancestor(
              of: find.byType(SyntilaMarkdownBody).first,
              matching: find.byWidgetPredicate((widget) =>
                  widget is DecoratedBox &&
                  widget.decoration is BoxDecoration &&
                  (widget.decoration as BoxDecoration).color != null))
          .first;
      final decoration = bubble.decoration as BoxDecoration;
      expect(decoration.border, isNull);
      expect(
          (tester.widget<DecoratedBox>(background).decoration as BoxDecoration)
              .color,
          own ? SyntilaColors.ownMessageBackground(false) : Colors.transparent);
      expect(tester.getRect(background).contains(tester.getCenter(trigger)),
          isTrue);
      expect(dateX, lessThan(tester.getTopLeft(reply).dx));
      expect(tester.getSize(trigger), Size.square(touch ? 40 : 28));
      expect(tester.getCenter(date).dy,
          closeTo(tester.getCenter(trigger).dy, 0.01));
      final opacity = find
          .ancestor(of: trigger, matching: find.byType(AnimatedOpacity))
          .first;
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
      if (touch) {
        // Touch has no hover: tapping the message reveals its actions.
        await tester.tap(bubbleFinder, warnIfMissed: false);
      } else {
        // Keyboard focus reveals the same actions without needing a mouse.
        Focus.of(tester.element(trigger)).requestFocus();
      }
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
      expect(find.byTooltip('Edit'), own ? findsOneWidget : findsNothing);
      expect(find.byTooltip('Delete'), own ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'ThreadPage loads and persists discussions via dataSource and updates when switching threads',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    const dataSource = AxFixtureDataSource();
    const space = AxSpace(
      id: 'space-1',
      name: 'Space One',
      branch: '',
      lastActivity: 'today',
      role: 'collaborator',
    );
    const ws1 = AxThread(
      id: 'ws-1',
      spaceId: 'space-1',
      name: 'Alpha Thread',
      lead: 'Owner',
      status: 'active',
      brief: '',
      primaryWorkspace: 'Workspace One',
      queueStatus: 'Idle',
    );
    const ws2 = AxThread(
      id: 'ws-2',
      spaceId: 'space-1',
      name: 'Beta Thread',
      lead: 'Owner',
      status: 'active',
      brief: '',
      primaryWorkspace: 'Workspace One',
      queueStatus: 'Idle',
    );

    var activeThread = ws1;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => ThreadPage(
            key: ValueKey(activeThread.id),
            space: space,
            thread: activeThread,
            dataSource: dataSource,
            currentUserId: 'user-owner',
            onBackToSpace: _noop,
            onArchive: _noop,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Verify initial empty state for ws1
    expect(find.text('No chat messages yet'), findsOneWidget);

    // Send a message on ws1
    await tester.enterText(find.byType(TextField).last, 'Message for Alpha');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send message')));
    await tester.pumpAndSettle();
    expect(find.text('Message for Alpha'), findsOneWidget);

    // Switch to ws2
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            activeThread = ws2;
            return ThreadPage(
              key: ValueKey(activeThread.id),
              space: space,
              thread: activeThread,
              dataSource: dataSource,
              currentUserId: 'user-owner',
              onBackToSpace: _noop,
              onArchive: _noop,
            );
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Verify ws2 does not have ws1's message and shows empty state
    expect(find.text('Message for Alpha'), findsNothing);
    expect(find.text('No chat messages yet'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Threads are ordered by their most recent update',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    const ws1 = AxThread(
      id: 'ws-1',
      spaceId: 'p-1',
      name: 'Alpha Thread',
      lead: 'Vitalii',
      status: 'active',
      brief: '',
      primaryWorkspace: 'MacBook',
      queueStatus: 'Idle',
      updatedAt: '2026-10-01T10:00:00Z',
    );
    const ws2 = AxThread(
      id: 'ws-2',
      spaceId: 'p-1',
      name: 'Beta Thread',
      lead: 'Vitalii',
      status: 'active',
      brief: '',
      primaryWorkspace: 'MacBook',
      queueStatus: 'Idle',
      updatedAt: '2026-10-03T10:00:00Z',
    );
    const ws3 = AxThread(
      id: 'ws-3',
      spaceId: 'p-1',
      name: 'Gamma Thread',
      lead: 'Vitalii',
      status: 'active',
      brief: '',
      primaryWorkspace: 'MacBook',
      queueStatus: 'Idle',
      updatedAt: '2026-10-02T10:00:00Z',
    );

    const space = AxSpace(
      id: 'p-1',
      name: 'Test Space',
      branch: 'main',
      lastActivity: 'today',
      threads: [ws1, ws2, ws3],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: space,
            dataSource: _SpaceStreamsSource([ws1, ws2, ws3]),
            onOpenThread: (_) {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The read model orders newest updates first: Beta, Gamma, Alpha.
    final listTiles = find.byType(ListTile);
    expect(listTiles, findsNWidgets(3));
    final tiles = tester.widgetList<ListTile>(listTiles).toList();
    expect((tiles[0].title as Text).data, 'Beta Thread');
    expect((tiles[1].title as Text).data, 'Gamma Thread');
    expect((tiles[2].title as Text).data, 'Alpha Thread');

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Space instructions are not rendered or editable',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    AxSpace? updatedSpace;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: const AxSpace(
              id: 'p-1',
              name: 'Test Space',
              description: 'Initial description',
              instructions: 'Initial instructions',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: const AxFixtureDataSource(),
            onOpenThread: (_) {},
            onArchive: () {},
            onDelete: () {},
            onSpaceUpdated: (p) => updatedSpace = p,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Initial instructions'), findsNothing);
    expect(find.text('Space Instructions'), findsNothing);

    // Tap 3-dots popup menu -> Edit
    await tester.tap(find.byTooltip('Space actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(find.text('Edit Space'), findsOneWidget);

    expect(find.text('Instructions'), findsNothing);

    // Click Save
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // Verify update occurred
    expect(updatedSpace, isNotNull);
    expect(updatedSpace!.instructions, 'Initial instructions');

    await tester.pumpAndSettle(const Duration(seconds: 5));
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'Space with empty instructions hides instructions section completely',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: const AxSpace(
              id: 'p-1',
              name: 'Test Space',
              description: 'Initial description',
              instructions: '',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: const AxFixtureDataSource(),
            onOpenThread: (_) {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Space Instructions'), findsNothing);
    expect(find.text('No instructions configured.'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'Creating thread with duplicate name shows warning and stays on dialog',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    var createdCount = 0;

    final customDataSource = _DuplicateTestDataSource(
      onCreateThread: () => createdCount++,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: const AxSpace(
              id: 'p-1',
              name: 'Test Space',
              branch: 'main',
              lastActivity: 'today',
              threads: [
                AxThread(
                  id: 'ws-1',
                  spaceId: 'p-1',
                  name: 'Frontend Design',
                  lead: 'Owner',
                  status: 'active',
                  brief: '',
                  primaryWorkspace: '',
                  queueStatus: 'idle',
                ),
              ],
            ),
            dataSource: customDataSource,
            onOpenThread: (_) {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Tap create thread button
    await tester.tap(find.byTooltip('Create Thread'));
    await tester.pumpAndSettle();

    expect(find.text('Create Thread'), findsNWidgets(2)); // Title and Button

    // Enter existing name (case-insensitive)
    await tester.enterText(find.byType(TextField).first, 'frontend design');
    await tester.pump(); // Create enables once a name is entered.
    await tester.tap(find.widgetWithText(FilledButton, 'Create Thread'));
    await tester.pumpAndSettle();

    // Verify warning is displayed and dialog is still visible
    expect(
        find.text('A thread with this name already exists.'), findsOneWidget);
    expect(find.text('Create Thread'), findsNWidgets(2));
    expect(createdCount, 0);

    // Cancel dialog
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Inviting duplicate member shows warning and stays on dialog',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    var inviteCount = 0;

    final customDataSource = _DuplicateTestDataSource(
      onInviteMember: () => inviteCount++,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            section: SpacePageSection.members,
            space: const AxSpace(
              id: 'p-1',
              name: 'Test Space',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: customDataSource,
            onOpenThread: (_) {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Tap Share Space button
    await tester.tap(find.byTooltip('Share Space'));
    await tester.pumpAndSettle();

    expect(find.text('Invite people'), findsOneWidget); // Dialog title

    // Enter existing member email
    await tester.enterText(
        find.byKey(const ValueKey('invite-new-email')), 'alice@example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Send invitation'));
    await tester.pumpAndSettle();

    // Verify warning is displayed and dialog is still visible
    expect(find.text('This user is already a member of the Space.'),
        findsOneWidget);
    expect(find.text('Invite people'), findsOneWidget);
    expect(inviteCount, 0);

    // Cancel dialog
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.binding.setSurfaceSize(null);
  });

  for (final width in [320.0, 390.0, 1200.0]) {
    testWidgets('Members table keeps controls reachable at width $width',
        (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final source = _MembersTabTestDataSource(
        members: const [
          AxSpaceMember(
            userId: 'mobile-member',
            email: 'member.with.a.long.address@example.com',
            displayName: 'Member with a long display name',
            role: 'collaborator',
            createdAt: '2026-01-01',
          ),
        ],
        invitations: const [],
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SpacePage(
              section: SpacePageSection.members,
              space: const AxSpace(
                  id: 'p-1', name: 'Test Space', branch: '', lastActivity: ''),
              dataSource: source,
              onOpenThread: (_) {},
              onArchive: () {},
              onDelete: () {},
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final table = find.byType(DataTable);
      final viewport = find.byKey(const ValueKey('space-members-scroll'));
      final scrollable =
          find.descendant(of: viewport, matching: find.byType(Scrollable));
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(tester.getSize(table).width,
          greaterThanOrEqualTo(tester.getSize(viewport).width));
      if (width < 600) {
        expect(position.maxScrollExtent, greaterThan(0));
        await tester.drag(viewport, const Offset(-1200, 0));
        await tester.pumpAndSettle();
        expect(position.pixels, greaterThan(0));
      } else {
        expect(position.maxScrollExtent, 0);
      }
      final remove = find.byTooltip('Remove from Space');
      expect(remove.hitTestable(), findsOneWidget);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(find.text('Remove "Member with a long display name"?'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('my latest message shows who has seen it', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThreadPage(
          space: const AxSpace(
            id: 'space-1',
            name: 'Space One',
            branch: '',
            lastActivity: 'today',
            role: 'collaborator',
          ),
          thread: const AxThread(
            id: 'thread-1',
            spaceId: 'space-1',
            name: 'Research',
            lead: 'Owner',
            status: 'active',
            brief: '',
            primaryWorkspace: 'Workspace One',
            queueStatus: 'Idle',
          ),
          dataSource: _ReadReceiptsDataSource(),
          currentUserId: 'user-owner',
          onBackToSpace: _noop,
          onArchive: _noop,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Seen by Ann'), findsOneWidget);
  });

  testWidgets(
      'Owner Members tab distinguishes Members and Pending invitations with Resend and Revoke controls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));

    final customDataSource = _MembersTabTestDataSource(
      members: const [
        AxSpaceMember(
          userId: 'u-vitalii',
          email: 'vitalii@nohainc.com',
          displayName: 'Vitalii Noha',
          role: 'owner',
          createdAt: '2026-01-01',
        ),
      ],
      invitations: const [
        AxSpaceInvitation(
          id: 'pinv-1',
          spaceId: 'p-1',
          email: 'ulikossnokia@gmail.com',
          role: 'collaborator',
          status: 'pending',
          createdAt: '2026-10-07T12:00:00Z',
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            section: SpacePageSection.members,
            space: const AxSpace(
              id: 'p-1',
              name: 'Test Space',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: customDataSource,
            onOpenThread: (_) {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Verify distinct sections
    expect(find.text('Members (1)'), findsNothing);
    expect(find.text('Vitalii Noha'), findsOneWidget);
    expect(find.text('Owner'), findsOneWidget);

    expect(find.text('Pending invitations (1)'), findsOneWidget);
    expect(find.text('ulikossnokia@gmail.com'), findsOneWidget);
    expect(find.text('SENT'), findsOneWidget);

    // Resend action
    expect(find.byTooltip('Resend invitation'), findsOneWidget);
    await tester.tap(find.byTooltip('Resend invitation'));
    await tester.pumpAndSettle();
    expect(customDataSource.resendCount, 1);

    // Revoke action
    expect(find.byTooltip('Revoke invitation'), findsOneWidget);
    await tester.tap(find.byTooltip('Revoke invitation'));
    await tester.pumpAndSettle();

    // Verify confirmation dialog
    expect(find.text('Revoke invitation?'), findsOneWidget);
    expect(find.text('Cancel pending invitation for ulikossnokia@gmail.com?'),
        findsOneWidget);

    // Confirm revoke
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(customDataSource.revokeCount, 2);

    await tester.pump(const Duration(seconds: 5));
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'Work tab shows Worker identity and configuration before and after execution',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    final dataSource = _WorkHistoryDataSource([
      const AxWorkRequest(
        id: 'req-system',
        requestedByName: 'Vitalii',
        prompt: 'Preparing system run',
        workflowId: 'direct',
        workflowVersion: 1,
        workflowName: 'Direct Execution',
        status: 'running',
        createdAt: '2026-10-06T10:00:00Z',
        steps: [
          AxWorkRequestStep(
            kind: 'implement',
            status: 'waiting',
            executionPhase: 'delivered',
            workerId: 'w-1',
            workerTypeId: 'chatgpt',
            workerDisplayName: 'ChatGPT',
            model: 'gpt-4o',
            elapsedMs: 5000,
          )
        ],
      ),
      const AxWorkRequest(
        id: 'req-running',
        requestedByName: 'Vitalii',
        prompt: 'Work is underway',
        workflowId: 'direct',
        workflowVersion: 1,
        workflowName: 'Direct Execution',
        status: 'running',
        createdAt: '2026-10-06T10:00:30Z',
        steps: [
          AxWorkRequestStep(
              kind: 'implement',
              status: 'running',
              workerId: 'w-1',
              workerTypeId: 'chatgpt',
              workerDisplayName: 'ChatGPT')
        ],
      ),
      const AxWorkRequest(
        id: 'req-worker',
        requestedByName: 'Vitalii',
        prompt: 'Build feature',
        workflowId: 'direct',
        workflowVersion: 1,
        workflowName: 'Direct Execution',
        status: 'completed',
        createdAt: '2026-10-06T10:01:00Z',
        finalText: 'Feature implementation complete.',
        steps: [
          AxWorkRequestStep(
            kind: 'implement',
            status: 'completed',
            workerId: 'w-1',
            workerDisplayName: 'Claude 3.7 Sonnet',
            workerTypeId: 'claude',
            model: 'claude-3-7-sonnet',
            elapsedMs: 12000,
            resultText: 'Feature implementation complete.',
          )
        ],
      ),
    ]);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThreadPage(
          initialTab: 1,
          space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner',
          ),
          thread: const AxThread(
            id: 'stream-1',
            spaceId: 'space-1',
            name: 'Implementation',
            lead: 'Vitalii',
            status: 'active',
            brief: '',
            primaryWorkspace: 'Workspace',
            queueStatus: 'idle',
          ),
          onBackToSpace: _noop,
          onArchive: _noop,
          dataSource: dataSource,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Delivered work shows the selected model in the message header.
    expect(_inConversation(find.text('gpt-4o')), findsOneWidget);
    expect(_inConversation(find.text('ChatGPT')), findsOneWidget);
    expect(find.textContaining('Direct Execution · 5s'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
    expect(find.text('· Default effort'), findsWidgets);

    // Model identity stays visible in the message header.
    expect(_inConversation(find.text('claude-3-7-sonnet')), findsOneWidget);
    expect(find.textContaining('Direct Execution · 12s'), findsOneWidget);
    expect(find.byTooltip('claude-3-7-sonnet'), findsNothing);
    // A running response has worker attribution before any result text exists.
    final assetImages = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image)
        .whereType<AssetImage>()
        .map((asset) => asset.assetName);
    expect(assetImages, contains('assets/worker_icons/chatgpt.png'));
    expect(assetImages, contains('assets/worker_icons/claude.png'));

    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('failed Work requests can be reported once and show confirmation',
      (tester) async {
    final request = AxWorkRequest.fromJson({
      'id': 'request-report',
      'requestedByName': 'You',
      'requestedByUserId': 'user-owner',
      'prompt': 'Please investigate this failure',
      'workflowId': 'direct',
      'workflowVersion': 1,
      'status': 'failed',
      'createdAt': '2026-10-11T10:00:00Z',
      'error': 'Run failed',
      'steps': [
        {
          'kind': 'implement',
          'status': 'failed',
          'workerId': 'worker-1',
          'assignmentId': 'assignment-report',
          'errorCode': 'provider_authentication_required',
        }
      ],
    });
    final dataSource = _IssueReportDataSource(request);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThreadPage(
          initialTab: 1,
          space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner',
          ),
          thread: const AxThread(
            id: 'thread-1',
            spaceId: 'space-1',
            name: 'Thread',
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: '',
          ),
          dataSource: dataSource,
          currentUserId: 'user-owner',
          onBackToSpace: _noop,
          onArchive: _noop,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await _chooseMessageAction(tester, 'Report issue');
    expect(dataSource.reportCalls, 1);
    expect(find.text('Reported'), findsOneWidget);
    expect(find.textContaining('sanitized technical diagnostics were sent'),
        findsOneWidget);
    expect(find.byTooltip('Report issue'), findsNothing);
    expect(find.byTooltip('Retry request'), findsNothing);
  });
}

class _IssueReportDataSource extends AxFixtureDataSource {
  _IssueReportDataSource(this.request);

  final AxWorkRequest request;
  var reportCalls = 0;
  var reported = false;

  @override
  Future<AxWorkRequestPage> loadThreadWorkRequestPage({
    required String threadId,
    int limit = 50,
    String? beforeCreatedAt,
    String? beforeId,
    bool activeOnly = false,
  }) async =>
      AxWorkRequestPage(requests: [request]);

  @override
  Future<AxIssueReport?> loadIssueReport({
    required String requestId,
    String? assignmentId,
  }) async =>
      reported
          ? const AxIssueReport(
              id: 'issue-1',
              publicReference: 'ISS-1',
              status: 'open',
              diagnosticState: 'partial',
              createdAt: '2026-10-11T00:00:00Z',
              updatedAt: '2026-10-11T00:00:00Z',
            )
          : null;

  @override
  Future<AxIssueReport> reportIssue({required String requestId}) async {
    reportCalls++;
    reported = true;
    return const AxIssueReport(
      id: 'issue-1',
      publicReference: 'ISS-1',
      status: 'open',
      diagnosticState: 'partial',
      createdAt: '2026-10-11T00:00:00Z',
      updatedAt: '2026-10-11T00:00:00Z',
    );
  }
}

class _DuplicateTestDataSource extends AxFixtureDataSource {
  _DuplicateTestDataSource({
    this.onCreateThread,
    this.onInviteMember,
  });

  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async => [
        AxThread.fromJson({
          'id': 'ws-1',
          'spaceId': spaceId,
          'name': 'Frontend Design',
          'status': 'active'
        })
      ];

  final VoidCallback? onCreateThread;
  final VoidCallback? onInviteMember;

  @override
  Future<List<AxWorkspace>> loadWorkspaces() async => const [
        AxWorkspace(
          id: 'ws-1',
          name: 'MacBook Pro',
          slug: 'macbook-pro',
          status: 'online',
          role: 'owner',
        ),
      ];
  @override
  Future<List<Map<String, dynamic>>> loadSpaceWorkflowWorkspaceGrants({
    required String spaceId,
  }) async =>
      [
        {
          'id': 'grant-1',
          'workspaceId': 'ws-1',
          'workspaceName': 'MacBook Pro',
        }
      ];

  @override
  Future<List<AxSpaceMember>> loadSpaceMembers({
    required String spaceId,
  }) async =>
      const [
        AxSpaceMember(
          userId: 'u-alice',
          email: 'alice@example.com',
          displayName: 'Alice',
          role: 'collaborator',
          createdAt: '2026-01-01',
        ),
      ];

  @override
  Future<AxThread> createThread({
    required String spaceId,
    required String name,
    String? brief,
    String? lead,
    String? primaryWorkspace,
    String? idempotencyKey,
  }) async {
    onCreateThread?.call();
    return AxThread(
      id: 'ws-new',
      spaceId: spaceId,
      name: name,
      lead: lead ?? 'Owner',
      status: 'active',
      brief: brief ?? '',
      primaryWorkspace: primaryWorkspace ?? '',
      queueStatus: 'idle',
    );
  }

  @override
  Future<void> inviteSpaceMemberWithPermissions({
    required String spaceId,
    required String email,
    required String role,
    required AxSpacePermissions permissions,
  }) async {
    onInviteMember?.call();
  }
}

class _WorkHistoryDataSource extends AxFixtureDataSource {
  _WorkHistoryDataSource(this.requests);

  List<AxWorkRequest> requests;
  final List<bool> activeOnlyCalls = [];

  @override
  Future<List<AxWorkRequest>> workRequestRows({
    required String threadId,
    bool activeOnly = false,
  }) async {
    activeOnlyCalls.add(activeOnly);
    return requests;
  }
}

class _DiscussionDataSource extends AxFixtureDataSource {
  _DiscussionDataSource({this.editedAt});

  final String? editedAt;

  @override
  Future<List<AxDiscussionMessage>> discussionRows({
    required String threadId,
  }) async =>
      [
        AxDiscussionMessage(
          id: 'message-1',
          threadId: 'thread-1',
          authorUserId: 'user-owner',
          authorName: 'Vitalii',
          body: 'A dated message',
          editedAt: editedAt,
          createdAt: '2026-10-05T19:18:00.000Z',
          isMe: true,
        ),
      ];
}

class _ReadReceiptsDataSource extends _DiscussionDataSource
    implements AxThreadReadReceiptsDataSource {
  @override
  Future<List<AxThreadReadState>> loadThreadReadStates(String threadId) async =>
      [
        AxThreadReadState(
            userId: 'u-ann',
            displayName: 'Ann',
            readAt: DateTime.parse('2026-10-05T19:20:00.000Z')),
        // Read before the message was sent: not "seen".
        AxThreadReadState(
            userId: 'u-bob',
            displayName: 'Bob',
            readAt: DateTime.parse('2026-10-05T19:00:00.000Z')),
      ];
}

class _MarkdownDiscussionDataSource extends AxFixtureDataSource {
  String? createdSource;
  String? editedSource;
  Map<String, dynamic>? createdReplyTo;

  @override
  Future<AxDiscussionMessage> sendDiscussionMessage(
      {required String threadId,
      required String text,
      List<String> references = const [],
      List<Map<String, dynamic>> attachments = const [],
      String? idempotencyKey,
      Map<String, dynamic>? replyTo}) async {
    createdSource = text;
    createdReplyTo = replyTo;
    return AxDiscussionMessage(
        id: replyTo == null ? 'saved-message' : 'saved-reply',
        replyTo: replyTo == null
            ? null
            : AxReplyReference(
                kind: replyTo['kind'] as String,
                id: replyTo['id'] as String,
                authorName: 'You',
                excerpt: 'First question'),
        threadId: threadId,
        authorUserId: 'user-owner',
        body: text,
        createdAt: '2026-10-06T00:00:00Z');
  }

  @override
  Future<AxDiscussionMessage> editDiscussionMessage(
      {required String messageId,
      required String text,
      List<String> references = const []}) async {
    editedSource = text;
    return AxDiscussionMessage(
        id: messageId,
        threadId: 'stream-1',
        authorUserId: 'user-owner',
        body: text,
        createdAt: '2026-10-06T00:00:00Z');
  }
}

class _ConversationMixDataSource extends _WorkFormDataSource {
  _ConversationMixDataSource(
      {this.otherAfter = false, this.missingRequesterId = false});
  final bool missingRequesterId;
  final bool otherAfter;

  @override
  Future<List<AxDiscussionMessage>> discussionRows({
    required String threadId,
  }) async =>
      [
        for (final (id, body, at) in [
          ('m1', 'Before AI', '2026-10-06T10:00:00Z'),
          ('m2', 'After AI', '2026-10-06T12:00:00Z'),
        ])
          AxDiscussionMessage(
              id: id,
              threadId: threadId,
              authorUserId:
                  otherAfter && id == 'm2' ? 'user-other' : 'user-owner',
              body: body,
              createdAt: at,
              isMe: true),
      ];

  @override
  Future<List<AxWorkRequest>> workRequestRows({
    required String threadId,
    bool activeOnly = false,
  }) async =>
      [
        AxWorkRequest(
          id: 'R',
          requestedByName: missingRequesterId ? 'Vitalii' : 'You',
          requestedByUserId: missingRequesterId ? null : 'user-owner',
          prompt: 'Research auth',
          workflowId: 'direct',
          workflowVersion: 2,
          status: 'completed',
          createdAt: '2026-10-06T11:00:00Z',
          steps: [],
          finalText: 'Use passkeys',
        ),
      ];
}

class _ArchivedAiDiscussionDataSource extends AxFixtureDataSource {
  @override
  Future<List<AxDiscussionMessage>> discussionRows({
    required String threadId,
  }) async =>
      [
        AxDiscussionMessage.fromJson({
          'id': 'discussion-ai-request-R',
          'threadId': threadId,
          'authorUserId': 'user-owner',
          'authorName': 'Vitalii',
          'body': 'Research auth',
          'createdAt': '2026-10-06T00:00:00Z',
          'kind': 'ai_request',
          'workRequestId': 'R',
          'workerDisplayName': 'ChatGPT',
        }, currentUserId: 'user-owner'),
        AxDiscussionMessage.fromJson({
          'id': 'discussion-ai-answer-R',
          'threadId': threadId,
          'authorUserId': 'user-owner',
          'authorName': 'Vitalii',
          'body': 'Use passkeys',
          'createdAt': '2026-10-06T00:01:00Z',
          'kind': 'ai_answer',
          'workRequestId': 'R',
          'workerDisplayName': 'ChatGPT',
        }, currentUserId: 'user-owner'),
      ];
}

class _WorkFormDataSource extends AxFixtureDataSource {
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        AxBuiltinWorkflow.fromJson({
          'id': 'direct',
          'executionPolicy': const {
            'userSelectsWorker': true,
            'userSelectsModel': true,
            'userSelectsEffort': true
          },
          'composerBindingId': 'direct',
          'version': 2,
          'name': 'Work',
          'description': 'Implement the requested work.',
          'steps': [
            {'kind': 'implement', 'order': 0},
          ],
        }),
      ];
}

class _GenericWorkerConfigDataSource extends _WorkFormDataSource {
  Map<String, dynamic>? savedWorkConfig;

  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async => const [
        AxWorker(
          id: 'local-worker-dynamic-test',
          workspaceId: 'workspace-1',
          workspaceName: 'Vitalii’s MacBook Pro',
          workerTypeId: 'dynamic-test-worker',
          displayName: 'Dynamic Test Worker',
          description: 'Catalog-created acceptance Worker.',
          status: 'ready',
          readinessState: 'ready',
          localConcurrencyLimit: 1,
        ),
      ];
  @override
  Future<List<Map<String, dynamic>>> loadSpaceWorkflowWorkspaceGrants({
    required String spaceId,
  }) async =>
      [
        {'workspaceId': 'workspace-1', 'workspaceName': 'Ignored grant label'},
      ];

  @override
  Future<AxThread> updateThread({
    required String threadId,
    String? name,
    String? status,
    Map<String, dynamic>? workConfig,
    Map<String, dynamic>? metadata,
  }) async {
    savedWorkConfig = workConfig;
    return AxThread(
      id: threadId,
      spaceId: 'space-1',
      name: 'Implementation',
      lead: 'Owner',
      status: 'active',
      brief: '',
      primaryWorkspace: 'Not selected',
      queueStatus: 'Idle',
      workConfig: workConfig ?? const {},
    );
  }
}

class _PinnedHistoryDataSource extends _WorkHistoryDataSource {
  _PinnedHistoryDataSource()
      : super(List.generate(
            20,
            (i) => AxWorkRequest(
                  id: 'request-$i',
                  requestedByName: 'You',
                  prompt: 'Work prompt $i',
                  workflowId: 'direct',
                  workflowVersion: 1,
                  status: 'completed',
                  createdAt: '2026-10-06T10:00:00Z',
                  steps: const [],
                )));

  @override
  Future<List<AxDiscussionMessage>> discussionRows(
          {required String threadId}) async =>
      List.generate(
          20,
          (i) => AxDiscussionMessage(
                id: 'message-$i',
                threadId: threadId,
                authorUserId: 'user-owner',
                body: 'Chat message $i',
                createdAt: '2026-10-06T10:00:00Z',
              ));
}

/// A Thread whose queue is shared in Cloud with another member.
class _SharedQueueDataSource extends _SlowSubmissionDataSource
    implements AxThreadQueueDataSource {
  AxThreadQueue queue = AxThreadQueue.empty;
  final calls = <String>[];

  AxThreadQueueItem item(String id, String author, String text) =>
      AxThreadQueueItem(
          id: id,
          authorUserId: author,
          authorName: author == 'user-owner' ? 'You' : 'Mia',
          status: 'queued',
          request: {
            'workflowId': 'direct',
            'workflowVersion': 1,
            'input': {'originalRequest': text},
          });

  AxThreadQueue _set(AxThreadQueue next) => queue = next;

  @override
  Future<AxThreadQueue> loadThreadQueue(String threadId) async => queue;

  @override
  Future<AxThreadQueue> enqueueThreadRequest({
    required String threadId,
    required String workflowId,
    required int workflowVersion,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},
    AxReplyReference? replyTo,
  }) async {
    calls.add('enqueue:$prompt');
    return _set(AxThreadQueue(
        paused: queue.paused,
        pauseReason: queue.pauseReason,
        items: [
          ...queue.items,
          item('q${queue.items.length + 1}', 'user-owner', prompt)
        ]));
  }

  @override
  Future<AxThreadQueue> updateThreadQueueItem({
    required String threadId,
    required String itemId,
    required String workflowId,
    required int workflowVersion,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},
    AxReplyReference? replyTo,
  }) async {
    calls.add('update:$itemId');
    return queue;
  }

  @override
  Future<AxThreadQueue> removeThreadQueueItem(
      String threadId, String itemId) async {
    calls.add('remove:$itemId');
    return _set(AxThreadQueue(
        items: queue.items.where((i) => i.id != itemId).toList()));
  }

  @override
  Future<AxThreadQueue> sendThreadQueueItemNow(
      String threadId, String itemId) async {
    calls.add('send-now:$itemId');
    return queue;
  }

  @override
  Future<AxThreadQueue> setThreadQueuePaused(
      String threadId, bool paused) async {
    calls.add(paused ? 'pause' : 'resume');
    return _set(AxThreadQueue(
        paused: paused,
        pauseReason: paused ? 'user' : null,
        items: queue.items));
  }
}

class _SlowSubmissionDataSource extends _WorkFormDataSource {
  final ready = Completer<List<String>>();
  List<AxWorkRequest> requests = [];
  final cancelledWorkRequestIds = <String>[];

  @override
  Future<void> cancelWorkRequest({required String workRequestId}) async {
    cancelledWorkRequestIds.add(workRequestId);
  }

  @override
  Future<AxWorkRequestStatus> loadWorkRequest(
      {required String workRequestId}) async {
    final value = requests.firstWhere((r) => r.id == workRequestId);
    return AxWorkRequestStatus(
        id: value.id,
        status: value.status,
        text: value.finalText,
        originalRequest: value.prompt,
        workflowId: value.workflowId,
        workflowVersion: value.workflowVersion,
        createdAt: value.createdAt,
        steps: value.steps);
  }

  @override
  Future<List<String>> validateWorkRequestEligibility({
    required String threadId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
  }) =>
      ready.future;
  @override
  Future<List<AxWorkRequest>> workRequestRows(
          {required String threadId, bool activeOnly = false}) async =>
      requests;
}

class _VersionedWorkflowDataSource extends _WorkFormDataSource {
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        for (final version in [1, 2])
          AxBuiltinWorkflow.fromJson({
            'id': 'direct',
            'executionPolicy': const {
              'userSelectsWorker': true,
              'userSelectsModel': true,
              'userSelectsEffort': true
            },
            'composerBindingId': 'direct',
            'version': version,
            'name': version == 1 ? 'Direct' : 'Work',
            'description': 'Implement the requested work.',
            'steps': [
              {'kind': 'implement', 'order': 0}
            ],
          }),
      ];
  @override
  Future<List<AxWorkRequest>> workRequestRows(
          {required String threadId, bool activeOnly = false}) async =>
      [
        _workRequest('old-direct', 'Historical request'),
      ];
}

class _CurrentWorkflowUiDataSource extends _VersionedWorkflowDataSource {
  int discussionWrites = 0;

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        for (final entry in [
          ['chat', 1, 'Chat', 'chat'],
          ['direct', 1, 'Direct', 'implement'],
          ['direct', 2, 'Work', 'implement'],
          ['research', 1, 'Research', 'research'],
          ['plan_implement', 1, 'Plan & Implement', 'plan'],
          ['implement_verify', 1, 'Implement & Verify', 'implement'],
          ['full_cycle', 1, 'Full Cycle', 'research'],
        ])
          AxBuiltinWorkflow.fromJson({
            'id': entry[0],
            'executionPolicy': const {
              'userSelectsWorker': true,
              'userSelectsModel': true,
              'userSelectsEffort': true
            },
            'composerBindingId': entry[0] == 'direct' ? 'direct' : entry[3],
            'version': entry[1],
            'name': entry[2],
            'description': 'Dynamic catalog workflow',
            'steps': [
              {'kind': entry[3], 'order': 0}
            ],
          }),
      ];

  @override
  Future<List<AxWorkRequest>> workRequestRows(
          {required String threadId, bool activeOnly = false}) async =>
      [
        for (final id in ['chat', 'direct'])
          AxWorkRequest(
            id: '$id-result',
            requestedByName: 'Owner',
            requestedByUserId: 'user-owner',
            prompt: '**Question**',
            workflowId: id,
            workflowVersion: id == 'chat' ? 1 : 2,
            status: 'completed',
            createdAt: '2026-10-06T00:00:00Z',
            steps: const [],
            finalText: id == 'chat' ? '**Chat answer**' : '**Work answer**',
          ),
      ];

  @override
  Future<AxDiscussionMessage> sendDiscussionMessage(
      {required String threadId,
      required String text,
      List<String> references = const [],
      List<Map<String, dynamic>> attachments = const [],
      String? idempotencyKey,
      Map<String, dynamic>? replyTo}) {
    discussionWrites++;
    return super.sendDiscussionMessage(
        threadId: threadId, text: text, references: references);
  }
}

class _SnapshotHistoryDataSource extends AxFixtureDataSource {
  @override
  Future<List<AxWorkRequest>> workRequestRows(
          {required String threadId, bool activeOnly = false}) async =>
      [
        for (final entry in [
          ['direct', 1, 'Direct'],
          ['direct', 2, 'Work'],
          ['chat', 1, 'Chat']
        ])
          AxWorkRequest.fromJson({
            'id': '${entry[0]}-${entry[1]}',
            'workflowId': entry[0],
            'workflowVersion': entry[1],
            'workflowName': entry[2],
            'status': 'completed',
            'createdAt': '2026-10-06T00:00:00Z',
            'prompt': 'History request',
            'finalText': 'History answer',
          }),
      ];
}

class _ClearedHistoryDataSource extends AxFixtureDataSource {
  @override
  Future<AxWorkRequestPage> loadThreadWorkRequestPage(
          {required String threadId,
          int limit = 50,
          String? beforeCreatedAt,
          String? beforeId,
          bool activeOnly = false}) async =>
      AxWorkRequestPage(
        aiHistoryClearedAt: '2026-10-06T12:00:00Z',
        requests: [
          for (final (id, at, prompt) in [
            ('before', '2026-10-06T10:00:00Z', 'Before clear'),
            ('after', '2026-10-06T14:00:00Z', 'After clear'),
          ])
            AxWorkRequest.fromJson({
              'id': id,
              'workflowId': 'direct',
              'workflowVersion': 2,
              'status': 'completed',
              'createdAt': at,
              'prompt': prompt,
              'finalText': 'Answer',
            }),
        ],
      );
}

class _SpaceStreamsSource extends AxFixtureDataSource {
  _SpaceStreamsSource(this.streams);
  final List<AxThread> streams;
  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async =>
      streams;
}

class _PolicyWorkflowDataSource extends _ModelSelectionTestDataSource {
  _PolicyWorkflowDataSource(
      {required this.model, required this.effort, required this.binding});
  final bool model;
  final bool effort;
  final bool binding;

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        AxBuiltinWorkflow.fromJson({
          'id': 'policy-fixture',
          'version': 1,
          'name': 'Policy fixture',
          'description': '',
          'steps': [
            {'kind': 'implement', 'order': 0}
          ],
          'executionPolicy': {
            'userSelectsWorker': true,
            'userSelectsModel': model,
            'userSelectsEffort': effort,
            'multiStep': !binding
          },
          'composerBindingId': binding ? 'policy-binding' : null,
        })
      ];
}

class _ModelSelectionTestDataSource extends _GenericWorkerConfigDataSource {
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        AxBuiltinWorkflow.fromJson({
          'id': 'direct',
          'executionPolicy': const {
            'userSelectsWorker': true,
            'userSelectsModel': true,
            'userSelectsEffort': true
          },
          'composerBindingId': 'direct',
          'version': 2,
          'name': 'Work',
          'description': 'Implement the requested work.',
          'steps': [
            {'kind': 'implement', 'order': 0},
          ],
        }),
        AxBuiltinWorkflow.fromJson({
          'id': 'research',
          'executionPolicy': const {
            'userSelectsWorker': true,
            'userSelectsModel': true,
            'userSelectsEffort': true
          },
          'composerBindingId': 'research',
          'version': 1,
          'name': 'Research',
          'description': 'Investigate and research codebase.',
          'steps': [
            {'kind': 'research', 'order': 0},
          ],
        }),
      ];

  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async => const [
        AxWorker(
          id: 'w-chatgpt',
          workspaceId: 'workspace-1',
          workspaceName: 'MacBook Pro',
          workerTypeId: 'chatgpt',
          displayName: 'ChatGPT',
          status: 'ready',
          readinessState: 'ready',
          localConcurrencyLimit: 1,
          modelOptions: {
            'catalog': [
              {
                'id': 'gpt-4o',
                'name': 'GPT-4o',
                'supportedReasoningEfforts': []
              },
              {
                'id': 'o3',
                'name': 'o3',
                'supportedReasoningEfforts': ['low', 'high']
              },
            ]
          },
        ),
      ];
}

class _MembersTabTestDataSource extends AxFixtureDataSource {
  _MembersTabTestDataSource({
    required this.members,
    required this.invitations,
  });

  final List<AxSpaceMember> members;
  final List<AxSpaceInvitation> invitations;
  int resendCount = 0;
  int revokeCount = 0;

  @override
  Future<List<AxSpaceMember>> loadSpaceMembers({
    required String spaceId,
  }) async =>
      members;

  @override
  Future<List<AxSpaceInvitation>> loadSpaceInvitations({
    required String spaceId,
  }) async =>
      invitations;

  @override
  Future<void> expireSpaceInvitation({
    required String spaceId,
    required String invitationId,
  }) async {
    revokeCount++;
  }

  @override
  Future<AxSpaceInvitation> inviteSpaceMemberWithPermissions({
    required String spaceId,
    required String email,
    required String role,
    required AxSpacePermissions permissions,
  }) async {
    resendCount++;
    return AxSpaceInvitation(
      id: 'pinv-new',
      spaceId: spaceId,
      email: email,
      role: role,
      status: 'pending',
      createdAt: DateTime.now().toIso8601String(),
    );
  }
}

class _HistoryPromptDataSource extends _WorkHistoryDataSource {
  _HistoryPromptDataSource(super.requests);
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() =>
      _CurrentWorkflowUiDataSource().loadBuiltinWorkflowCatalog();
}

class _SimpleConversationDataSource extends _WorkHistoryDataSource {
  _SimpleConversationDataSource(this.request) : super([request]);
  final AxWorkRequest request;
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() =>
      _CurrentWorkflowUiDataSource().loadBuiltinWorkflowCatalog();
  @override
  Future<AxWorkRequestStatus> loadWorkRequest(
          {required String workRequestId}) async =>
      AxWorkRequestStatus(
          id: request.id,
          conversationId: request.conversationId,
          workflowRun: request.workflowRun,
          turns: request.turns,
          status: request.status,
          originalRequest: request.prompt,
          workflowId: request.workflowId,
          workflowVersion: request.workflowVersion,
          steps: request.steps,
          requestedByName: request.requestedByName);
}

class _ContinuityFailureDataSource extends _WorkHistoryDataSource {
  _ContinuityFailureDataSource(this.request, this.step) : super([request]);
  final AxWorkRequest request;
  final AxWorkRequestStep step;
  @override
  Future<AxWorkRequestStatus> loadWorkRequest(
          {required String workRequestId}) async =>
      AxWorkRequestStatus(
          id: workRequestId,
          status: 'failed',
          errorCode: step.errorCode,
          errorMessage: step.errorMessage,
          steps: [step]);
}

AxWorkRequest _workRequest(String id, String prompt,
        {String status = 'completed'}) =>
    AxWorkRequest(
      id: id,
      requestedByName: 'Owner',
      requestedByUserId: 'user-owner',
      prompt: prompt,
      workflowId: 'direct',
      workflowVersion: 1,
      status: status,
      createdAt: '2026-10-01T10:00:00.000Z',
      steps: const [],
    );

void _noop() {}

/// Restricts [finder] to the read-only AI History panel; the conversation
/// shows the same Work Requests as compact messages.
Finder _inAiHistory(Finder finder) => find.descendant(
    of: find.byKey(const ValueKey('thread-AI History-pane')), matching: finder);

/// Restricts [finder] to the Conversation timeline.
Finder _inConversation(Finder finder) => find.descendant(
    of: find.byKey(const ValueKey('chat-history-scroll')), matching: finder);

/// Opens the read-only AI History panel.
/// Opens AI History and, unless [expand] is false, expands every collapsed
/// request row so tests can inspect its full card.
/// Opens AI History; [showResponses] also opens every hidden response.
Future<void> _openAiHistory(WidgetTester tester,
    {bool showResponses = true}) async {
  await tester.tap(find.byKey(const ValueKey('ai-history-toggle')));
  await tester.pumpAndSettle();
  if (!showResponses) return;
  final hidden = find.byWidgetPredicate(
      (widget) => widget is Tooltip && widget.message == 'Show response');
  for (final tooltip in hidden.evaluate().toList()) {
    await tester.tap(find.byWidget(tooltip.widget), warnIfMissed: false);
  }
  await tester.pumpAndSettle();
}

/// Switches the conversation composer to Ask AI (the Work composer).
Future<void> _askAi(WidgetTester tester) async {
  // A narrow Thread shows AI History instead of the conversation.
  if (find.byKey(const ValueKey('composer-mode-ai')).evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey('ai-history-conversation')));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('composer-mode-ai')));
  await tester.pumpAndSettle();
}

/// Hovers the message that owns the [label] action icon so the
/// hover-revealed actions become tappable, then taps the icon. [action]
/// narrows the icon when several messages are on screen.
Future<void> _chooseMessageAction(WidgetTester tester, String label,
    {Finder? action}) async {
  final target = (action ?? find.byTooltip(label)).last;
  await tester.pumpAndSettle();
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(target));
  await tester.pumpAndSettle();
  await tester.tap(target);
  await mouse.removePointer();
  await tester.pumpAndSettle();
}

class _FiveOwnMessagesSource extends AxFixtureDataSource {
  final messages = [
    for (var i = 1; i <= 4; i++)
      AxDiscussionMessage(
          id: 'own-$i',
          threadId: 'thread-1',
          authorUserId: 'user-owner',
          body: 'Own message $i',
          createdAt: DateTime.now().toIso8601String(),
          isMe: true)
  ];

  @override
  Future<List<AxDiscussionMessage>> discussionRows(
          {required String threadId}) async =>
      List.of(messages);

  @override
  Future<AxDiscussionMessage> sendDiscussionMessage(
      {required String threadId,
      required String text,
      List<String> references = const [],
      List<Map<String, dynamic>> attachments = const [],
      String? idempotencyKey,
      Map<String, dynamic>? replyTo}) async {
    final message = AxDiscussionMessage(
        id: 'own-5',
        threadId: threadId,
        authorUserId: 'user-owner',
        body: text,
        createdAt: DateTime.now().toIso8601String(),
        isMe: true);
    messages.add(message);
    return message;
  }
}
