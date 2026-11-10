import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/brand.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';
import 'package:syntila_app/src/ax/ax_work_activity.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';

void main() {
  testWidgets('continue names skipped researchers', (tester) async {
    var continued = false;
    const request = AxWorkRequest(
      id: 'request',
      requestedByName: 'User',
      workflowId: 'research',
      workflowVersion: 2,
      status: 'failed',
      createdAt: '2026-11-02',
      prompt: 'Research',
      partialSynthesisAvailable: true,
      steps: [
        AxWorkRequestStep(
            stepId: 'research-1',
            kind: 'research',
            status: 'completed',
            workerId: 'worker'),
        AxWorkRequestStep(
            stepId: 'research-2',
            kind: 'research',
            status: 'failed',
            workerId: 'worker'),
      ],
    );
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: SingleChildScrollView(
          child: AxResearchStepCards(
        request: request,
        color: Colors.black,
        onSynthesizePartial: (_) async {
          continued = true;
        },
      )),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip failed researcher and continue'));
    expect(continued, isTrue);
  });
  testWidgets('research retry waits for the request to settle', (tester) async {
    var retries = 0;
    AxWorkRequest request(String status, String sibling) => AxWorkRequest(
          id: 'request',
          requestedByName: 'User',
          workflowId: 'research',
          workflowVersion: 2,
          status: status,
          createdAt: '2026-11-02',
          prompt: 'Research',
          steps: [
            const AxWorkRequestStep(
                stepId: 'research-1',
                kind: 'research',
                status: 'failed',
                retryAllowed: true,
                workerId: 'worker'),
            AxWorkRequestStep(
                stepId: 'research-2',
                kind: 'research',
                status: sibling,
                workerId: 'worker'),
          ],
        );
    Future<void> render(AxWorkRequest value) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: AxResearchStepCards(
            request: value,
            color: Colors.black,
            onRetryStep: (_, __) async {
              retries++;
            },
          ))),
        ));
    await render(request('running', 'running'));
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('research-retry-research-1'));
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    expect(find.text('Retry or skip after the other researchers finish.'),
        findsOneWidget);
    await render(request('failed', 'completed'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    expect(retries, 1);
  });
  testWidgets(
      'Research v2 step cards render without ListTile framework assertion',
      (WidgetTester tester) async {
    const request = AxWorkRequest(
      id: 'work-request-1',
      requestedByName: 'Test User',
      workflowId: 'research',
      workflowVersion: 2,
      status: 'running',
      createdAt: '2026-11-02T10:00:00Z',
      prompt: 'Investigate codebase',
      steps: [
        AxWorkRequestStep(
          stepId: 'research-1',
          kind: 'research',
          status: 'running',
          workerId: 'worker-1',
          model: 'model-a',
        ),
        AxWorkRequestStep(
          stepId: 'research-2',
          kind: 'research',
          status: 'completed',
          workerId: 'worker-1',
          model: 'model-b',
          resultText: 'Researcher 2 findings',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: SyntilaBrand.lightTheme(),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: AxResearchStepCards(
              request: request,
              color: SyntilaBrand.accent,
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify both researcher step expansion tiles render.
    expect(find.byKey(const ValueKey('research-step-cards')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('research-step-research-1-running')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('research-step-research-2-completed')),
      findsOneWidget,
    );

    // Verify ExpansionTile and internal ListTile exist and no exception was thrown.
    expect(find.byType(ExpansionTile), findsNWidgets(2));
    expect(find.byType(ListTile), findsWidgets);
  });
  testWidgets('live activity stays in its researcher panel', (tester) async {
    const request = AxWorkRequest(
      id: 'request',
      requestedByName: 'User',
      workflowId: 'research',
      workflowVersion: 2,
      status: 'running',
      createdAt: '2026-11-02',
      prompt: 'Research',
      steps: [
        AxWorkRequestStep(
            stepId: 'research-1',
            kind: 'research',
            status: 'running',
            assignmentId: 'a1',
            workerId: 'worker'),
        AxWorkRequestStep(
            stepId: 'research-2',
            kind: 'research',
            status: 'running',
            assignmentId: 'a2',
            workerId: 'worker'),
      ],
    );
    AxWorkActivity activity(String assignment, String title) => AxWorkActivity(
          eventId: assignment,
          assignmentId: assignment,
          attemptId: 'attempt',
          executionId: 'execution',
          workerId: 'worker',
          activitySequence: 1,
          streamSequence: 1,
          type: 'model.status',
          status: 'running',
          title: title,
          timestamp: DateTime.utc(2026),
        );
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: AxResearchStepCards(
          request: request,
          color: Colors.black,
          activities: [
            activity('a1', 'First action'),
            activity('a2', 'Second action'),
            activity('synthesis', 'Synthesis action')
          ]),
    ))));
    await tester.pump();
    final first =
        find.byKey(const ValueKey('research-step-research-1-running'));
    final second =
        find.byKey(const ValueKey('research-step-research-2-running'));
    expect(find.descendant(of: first, matching: find.text('First action')),
        findsOneWidget);
    expect(find.descendant(of: second, matching: find.text('Second action')),
        findsOneWidget);
    expect(find.descendant(of: first, matching: find.text('Second action')),
        findsNothing);
    expect(find.text('Synthesis action'), findsNothing);
  });
}
