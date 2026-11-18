import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages/provider_failure_panel.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';

Widget _wrap(Widget child, {double width = 500}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    );

void main() {
  group('ProviderFailurePanel UI', () {
    testWidgets('shows failure details for each failed research step',
        (tester) async {
      const request = AxWorkRequest(
        id: 'research',
        requestedByName: 'User',
        prompt: 'Research',
        workflowId: 'research',
        workflowVersion: 2,
        status: 'failed',
        createdAt: '2026-01-01T00:00:00Z',
        steps: [
          AxWorkRequestStep(
              kind: 'research',
              stepId: 'research-1',
              status: 'failed',
              workerId: 'one',
              providerFailure: AxProviderFailureDetails(
                  schemaVersion: 1,
                  source: 'stderr',
                  providerErrorText: 'first provider error')),
          AxWorkRequestStep(
              kind: 'research',
              stepId: 'research-2',
              status: 'failed',
              workerId: 'two',
              providerFailure: AxProviderFailureDetails(
                  schemaVersion: 1,
                  source: 'stderr',
                  failedRunResponse: 'second partial response')),
        ],
      );
      await tester.pumpWidget(_wrap(
          const AxResearchStepCards(request: request, color: Colors.grey),
          width: 320));
      await tester.pumpAndSettle();
      expect(find.text('first provider error'), findsOneWidget);
      expect(find.text('second partial response'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    testWidgets('shows an unavailable details notice', (tester) async {
      await tester.pumpWidget(_wrap(const ProviderFailurePanel(
        canonicalMessage: 'Execution failed.',
        providerFailureUnavailable: true,
      )));
      expect(find.text('Provider details are unavailable.'), findsOneWidget);
    });

    testWidgets('does not split a supplementary character in the preview',
        (tester) async {
      final response = '${'a' * 599}🎉${'b' * 5}';
      await tester.pumpWidget(_wrap(ProviderFailurePanel(
        canonicalMessage: 'Execution failed.',
        providerFailure: AxProviderFailureDetails(
          schemaVersion: 1,
          failedRunResponse: response,
          source: 'stderr',
        ),
      )));
      expect(find.text('${'a' * 599}🎉…'), findsOneWidget);
      await tester.tap(find.text('Show full response'));
      await tester.pump();
      expect(find.text(response), findsOneWidget);
    });
    testWidgets(
        'displays canonical failure, native code, provider error, and failed-run response',
        (tester) async {
      const details = AxProviderFailureDetails(
        schemaVersion: 1,
        nativeErrorCode: 'MODEL_CAPACITY',
        providerErrorText: 'Line 1\nLine 2 **not markdown**',
        failedRunResponse: 'Partial answer\n<script>alert(1)</script>',
        source: 'structured_error',
        truncated: true,
        omitted: true,
        omittedFields: ['providerErrorText'],
      );

      await tester.pumpWidget(_wrap(const ProviderFailurePanel(
        canonicalMessage: 'Provider execution failed.',
        errorCode: 'execution_failed',
        providerFailure: details,
      )));

      expect(find.byKey(const ValueKey('canonical-failure-message')),
          findsOneWidget);
      expect(find.text('Provider execution failed.'), findsOneWidget);
      expect(find.text('Native code: MODEL_CAPACITY'), findsOneWidget);
      expect(find.text('Line 1\nLine 2 **not markdown**'), findsOneWidget);
      expect(find.text('Response from failed run'), findsOneWidget);
      expect(find.text('Partial answer\n<script>alert(1)</script>'),
          findsOneWidget);
      expect(find.text('Truncated to size limit.'), findsOneWidget);
      expect(find.text('Omitted sensitive field(s): providerErrorText.'),
          findsOneWidget);
    });

    testWidgets(
        'falls back to canonical message when providerFailure is absent',
        (tester) async {
      await tester.pumpWidget(_wrap(const ProviderFailurePanel(
        canonicalMessage: 'The tool call failed.',
        errorCode: 'execution_failed',
      )));

      expect(find.text('The tool call failed.'), findsOneWidget);
      expect(find.byKey(const ValueKey('provider-native-error-code')),
          findsNothing);
      expect(find.byKey(const ValueKey('provider-error-text')), findsNothing);
      expect(
          find.byKey(const ValueKey('failed-run-response-text')), findsNothing);
    });

    testWidgets(
        'renders long response with expand/collapse and fits narrow 320px layout',
        (tester) async {
      final longResponse = 'A' * 750;
      await tester.pumpWidget(_wrap(
        ProviderFailurePanel(
          canonicalMessage: 'Execution failed.',
          providerFailure: AxProviderFailureDetails(
            schemaVersion: 1,
            failedRunResponse: longResponse,
            source: 'result_message',
          ),
        ),
        width: 320,
      ));

      expect(find.text('Show full response'), findsOneWidget);
      await tester.tap(find.text('Show full response'));
      await tester.pump();
      expect(find.text('Show less'), findsOneWidget);
      expect(find.text(longResponse), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('AxWorkRequestStep providerFailure reload', () {
    test('round-trips providerFailure through fromJson', () {
      final step = AxWorkRequestStep.fromJson({
        'kind': 'implement',
        'status': 'failed',
        'errorCode': 'execution_failed',
        'errorMessage': 'Execution failed.',
        'providerFailure': {
          'schemaVersion': 1,
          'nativeErrorCode': 'ERR_429',
          'providerErrorText': 'Rate limit',
          'failedRunResponse': 'Partial',
          'source': 'structured_error',
        },
      });
      expect(step.providerFailure?.nativeErrorCode, 'ERR_429');
      expect(step.providerFailure?.providerErrorText, 'Rate limit');
      expect(step.providerFailure?.failedRunResponse, 'Partial');
      expect(step.withExecutionPhase('failed').providerFailure?.nativeErrorCode,
          'ERR_429');
      final unavailable = AxWorkRequestStep.fromJson({
        'kind': 'implement',
        'status': 'failed',
        'providerFailureUnavailable': true,
      });
      expect(unavailable.providerFailureUnavailable, isTrue);
      expect(
          unavailable.withExecutionPhase('failed').providerFailureUnavailable,
          isTrue);
    });
  });
}
