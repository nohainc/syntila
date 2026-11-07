import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';

void main() {
  AxWorkRequest createRequest({
    required List<AxWorkRequestStep> steps,
    String status = 'completed',
    String workflowId = 'chat',
    int workflowVersion = 2,
  }) {
    return AxWorkRequest(
      id: 'req-1',
      conversationId: 'conv-1',
      workflowId: workflowId,
      workflowVersion: workflowVersion,
      status: status,
      prompt: 'Summarize file',
      createdAt: DateTime.now().toIso8601String(),
      requestedByUserId: 'usr-1',
      requestedByName: 'Vitalii',
      steps: steps,
    );
  }

  Widget harness(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: child,
        ),
      ),
    );
  }

  group('AxToolCallStepCards', () {
    testWidgets('renders nothing when request has no tool_call steps', (tester) async {
      final request = createRequest(steps: [
        const AxWorkRequestStep(
          kind: 'chat',
          stepId: 'chat',
          status: 'completed',
          workerId: 'worker-1',
        ),
      ]);

      await tester.pumpWidget(
        harness(
          AxToolCallStepCards(
            request: request,
            color: Colors.grey,
          ),
        ),
      );

      expect(find.byKey(const ValueKey('tool-call-step-cards')), findsNothing);
    });

    testWidgets('renders completed tool call with parsed tool label and resultText', (tester) async {
      final request = createRequest(steps: [
        const AxWorkRequestStep(
          kind: 'tool_call',
          stepId: 'tool',
          status: 'completed',
          workerId: null,
          resultText: 'Tool read_file on filesystem: completed',
          elapsedMs: 2500,
        ),
        const AxWorkRequestStep(
          kind: 'chat',
          stepId: 'chat',
          status: 'completed',
          workerId: 'worker-1',
          resultText: 'Here is the file summary',
        ),
      ]);

      await tester.pumpWidget(
        harness(
          AxToolCallStepCards(
            request: request,
            color: Colors.grey,
          ),
        ),
      );

      expect(find.byKey(const ValueKey('tool-call-step-cards')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('tool-call-step-tool-completed')),
        findsOneWidget,
      );
      expect(find.text('Tool read_file (filesystem) · Completed'), findsOneWidget);
      expect(find.text('Deterministic tool call · 2s'), findsOneWidget);

      // Expand the card
      await tester.tap(find.text('Tool read_file (filesystem) · Completed'));
      await tester.pumpAndSettle();

      expect(find.text('Tool read_file on filesystem: completed'), findsOneWidget);
    });

    testWidgets('renders running tool call step initially expanded', (tester) async {
      final request = createRequest(
        status: 'running',
        steps: [
          const AxWorkRequestStep(
            kind: 'tool_call',
            stepId: 'tool',
            status: 'running',
            workerId: null,
            resultText: 'Tool fetch on web: running',
            elapsedMs: 1200,
          ),
        ],
      );

      await tester.pumpWidget(
        harness(
          AxToolCallStepCards(
            request: request,
            color: Colors.blueGrey,
          ),
        ),
      );

      expect(find.byKey(const ValueKey('tool-call-step-cards')), findsOneWidget);
      expect(find.text('Tool fetch (web) · Running'), findsOneWidget);
      // Initially expanded for running steps:
      expect(find.text('Tool fetch on web: running'), findsOneWidget);
    });

    testWidgets('renders failed tool call step with error guidance', (tester) async {
      final request = createRequest(
        status: 'failed',
        steps: [
          const AxWorkRequestStep(
            kind: 'tool_call',
            stepId: 'tool',
            status: 'failed',
            workerId: null,
            errorCode: 'workspace_not_granted',
            errorMessage: 'Workspace grant expired or was revoked',
            elapsedMs: 500,
          ),
        ],
      );

      await tester.pumpWidget(
        harness(
          AxToolCallStepCards(
            request: request,
            color: Colors.grey,
          ),
        ),
      );

      expect(find.byKey(const ValueKey('tool-call-step-cards')), findsOneWidget);
      expect(find.text('Connected Tool Call · Failed'), findsOneWidget);
      // Initially expanded for failed steps:
      expect(find.text('Workspace grant expired or was revoked'), findsOneWidget);
    });
  });
}
