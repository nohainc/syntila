import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'ax_fixture_data.dart';

class RetrySource extends AxFixtureDataSource {
  RetrySource(
      {required this.allowed,
      required this.confirmation,
      this.contextLimit = false,
      this.compactable = false,
      this.quotaExhausted = false,
      this.stepKind = 'verify'});
  final bool allowed;
  final bool confirmation;
  final bool contextLimit;
  final bool compactable;
  final bool quotaExhausted;
  final String stepKind;
  final resets = <bool>[];
  final compactions = <bool>[];
  final approvals = <bool>[];
  final strategies = <String?>[];

  @override
  Future<AxWorkRequestStatus> loadWorkRequest(
          {required String workRequestId}) async =>
      AxWorkRequestStatus(id: workRequestId, status: 'failed', steps: [
        AxWorkRequestStep(
            kind: stepKind,
            status: 'failed',
            workerId: 'worker',
            errorCode: contextLimit
                ? 'context_limit_exceeded'
                : quotaExhausted
                    ? 'quota_exhausted'
                    : null,
            contextCompactionAvailable: compactable)
      ]);

  @override
  Future<List<AxWorkRequest>> workRequestRows(
          {required String threadId, bool activeOnly = false}) async =>
      [
        AxWorkRequest(
            id: 'request',
            requestedByName: 'You',
            prompt: 'Verify changes',
            workflowId: 'direct',
            workflowVersion: 2,
            status: 'failed',
            createdAt: '2026-10-14T10:00:00Z',
            executionPhase: 'failed',
            steps: [
              AxWorkRequestStep(
                  kind: stepKind,
                  status: 'failed',
                  workerId: 'worker',
                  executionPhase: 'failed',
                  workerDisplayName: 'Test Worker',
                  errorCode: contextLimit
                      ? 'context_limit_exceeded'
                      : quotaExhausted
                          ? 'quota_exhausted'
                          : null,
                  failureCategory: 'provider_start_failed',
                  failureCategoryMessage: 'AI provider could not start',
                  retryAllowed: allowed,
                  retryRequiresConfirmation: confirmation)
            ])
      ];

  @override
  Future<void> retryWorkRequestStep(
      {required String workRequestId,
      required String stepKind,
      String? stepId,
      String? sessionStrategy,
      bool clearAiHistory = false,
      bool compactContext = false,
      bool confirmSideEffects = false,
      bool partial = false}) async {
    expect(workRequestId, 'request');
    approvals.add(confirmSideEffects);
    resets.add(clearAiHistory);
    compactions.add(compactContext);
    strategies.add(sessionStrategy);
    if (clearAiHistory) expect(sessionStrategy, 'fresh');
    if (compactContext) expect(sessionStrategy, 'resume');
  }
}

Widget page(RetrySource source,
        {Future<String> Function(String, String, List<Map<String, dynamic>>,
                String, Map<String, dynamic>)?
            onRunWorkWithSelection}) =>
    MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      initialAiHistoryOpen: true,
      space:
          const AxSpace(id: 's', name: 'Space', branch: '', lastActivity: ''),
      thread: const AxThread(
          id: 't',
          spaceId: 's',
          name: 'Thread',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: source,
      onRunWorkWithSelection: onRunWorkWithSelection,
      onBackToSpace: () {},
      onArchive: () {},
    )));

void main() {
  testWidgets('context limit reset requires confirmation and starts fresh',
      (tester) async {
    final source =
        RetrySource(allowed: true, confirmation: false, contextLimit: true);
    await tester.pumpWidget(page(source));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Retry').last);
    await tester.pumpAndSettle();
    expect(find.text('The conversation is too long'), findsOneWidget);
    // This Worker cannot compact, so clearing is the only offer.
    expect(find.textContaining('Compact'), findsNothing);
    expect(source.resets, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(source.resets, isEmpty);
    await tester.tap(find.byTooltip('Retry').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear and retry'));
    await tester.pumpAndSettle();
    expect(source.resets, [true]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('context limit offers compaction when the Worker supports it',
      (tester) async {
    final source = RetrySource(
        allowed: true,
        confirmation: false,
        contextLimit: true,
        compactable: true);
    await tester.pumpWidget(page(source));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Retry').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, 'Clear and retry'), findsOneWidget);
    await tester.tap(
        find.widgetWithText(FilledButton, 'Compact and retry · Recommended'));
    await tester.pumpAndSettle();
    expect(source.compactions, [true]);
    expect(source.resets, [false]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
      'safe retry sends no side-effect approval and shows public failure',
      (tester) async {
    final source = RetrySource(allowed: true, confirmation: false);
    await tester.pumpWidget(page(source));
    await tester.pumpAndSettle();
    expect(find.text('AI provider could not start'), findsOneWidget);
    await tester.tap(find.byTooltip('Retry').last);
    await tester.pumpAndSettle();
    expect(source.approvals, [false]);
    expect(find.text('Retry anyway?'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('ambiguous retry requires approval; cancelling sends nothing',
      (tester) async {
    final source = RetrySource(allowed: true, confirmation: true);
    await tester.pumpWidget(page(source));
    await tester.pumpAndSettle();
    final retry = find.byTooltip('Retry anyway');
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(source.approvals, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(source.approvals, isEmpty);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Retry anyway'));
    await tester.pumpAndSettle();
    expect(source.approvals, [true]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('unconfirmed stop offers no retry', (tester) async {
    final source = RetrySource(allowed: false, confirmation: true);
    await tester.pumpWidget(page(source));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Retry'), findsNothing);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    expect(source.approvals, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'quota exhausted retry dialog offers retry with selected model, resume, and fresh',
      (tester) async {
    final source = RetrySource(
        allowed: true,
        confirmation: false,
        quotaExhausted: true,
        stepKind: 'implement');
    final submittedPrompts = <String>[];
    final submittedSelections = <Map<String, dynamic>>[];
    await tester.pumpWidget(page(source, onRunWorkWithSelection:
        (prompt, workflow, inputs, key, selection) async {
      submittedPrompts.add(prompt);
      submittedSelections.add(selection);
      return 'new-request-id';
    }));
    await tester.pumpAndSettle();

    // Verify failure guidance is displayed
    expect(
        find.text(
            'The provider’s usage limit has been reached. Wait for the limit to reset or choose another worker, then retry.'),
        findsOneWidget);

    // Tap Retry
    await tester.tap(find.byTooltip('Retry').last);
    await tester.pumpAndSettle();

    expect(find.text('Retry request'), findsOneWidget);
    expect(
        find.textContaining(
            'The provider’s usage limit has been reached. You can retry this request with the currently selected model'),
        findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Resume previous session'),
        findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Start fresh'), findsOneWidget);
    expect(
        find.widgetWithText(
            FilledButton, 'Retry with selected model · Recommended'),
        findsOneWidget);

    // Cancel does nothing
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(submittedPrompts, isEmpty);
    expect(source.strategies, isEmpty);

    // Reopen and tap "Retry with selected model · Recommended"
    await tester.tap(find.byTooltip('Retry').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(
        FilledButton, 'Retry with selected model · Recommended'));
    await tester.pumpAndSettle();

    expect(submittedPrompts, ['Verify changes']);
    expect(submittedSelections, isNotEmpty);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('quota exhausted retry allows resuming previous session',
      (tester) async {
    final source = RetrySource(
        allowed: true,
        confirmation: false,
        quotaExhausted: true,
        stepKind: 'implement');
    await tester.pumpWidget(page(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Retry').last);
    await tester.pumpAndSettle();
    await tester.tap(
        find.widgetWithText(TextButton, 'Resume previous session'));
    await tester.pumpAndSettle();
    expect(source.strategies, ['resume']);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('quota exhausted retry allows starting fresh', (tester) async {
    final source = RetrySource(
        allowed: true,
        confirmation: false,
        quotaExhausted: true,
        stepKind: 'implement');
    await tester.pumpWidget(page(source));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Retry').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Start fresh'));
    await tester.pumpAndSettle();
    expect(source.strategies, ['fresh']);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
