import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages/provider_failure_panel.dart';

void main() {
  final path = Platform.environment['SYNTILA_TEST_FAILURE_WORK'];
  testWidgets(
      'renders authenticated Work read produced by the provider failure chain',
      (tester) async {
    final work =
        jsonDecode(File(path!).readAsStringSync()) as Map<String, dynamic>;
    final request = AxWorkRequest.fromJson(work);
    final step = request.steps.single;
    expect(step.status, 'failed');
    final codex = Platform.environment['SYNTILA_TEST_FAILURE_SHAPE'] == 'codex';
    final sensitive =
        Platform.environment['SYNTILA_TEST_FAILURE_SHAPE'] == 'agy-sensitive';
    final stderrOnly =
        Platform.environment['SYNTILA_TEST_FAILURE_SHAPE'] == 'agy-stderr';
    final stderrResponse = Platform.environment['SYNTILA_TEST_FAILURE_SHAPE'] ==
        'agy-stderr-response';
    final whitespace =
        Platform.environment['SYNTILA_TEST_FAILURE_SHAPE'] == 'agy-whitespace';
    expect(step.errorCode, codex ? 'permission_denied' : 'execution_failed');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProviderFailurePanel(
          canonicalMessage: step.errorMessage!,
          errorCode: step.errorCode,
          providerFailure: step.providerFailure,
          providerFailureUnavailable: step.providerFailureUnavailable,
        ),
      ),
    ));
    expect(find.byKey(const ValueKey('canonical-failure-message')),
        findsOneWidget);
    if (codex) {
      expect(find.text('permission denied by sandbox'), findsOneWidget);
      expect(find.byKey(const ValueKey('provider-native-error-code')),
          findsNothing);
      expect(
          find.byKey(const ValueKey('failed-run-response-text')), findsNothing);
    } else if (stderrOnly || stderrResponse) {
      expect(find.text('Provider stderr'), findsOneWidget);
      expect(find.text('fixture stderr-only failure'), findsOneWidget);
      if (stderrOnly) {
        expect(find.byKey(const ValueKey('provider-native-error-code')),
            findsNothing);
        expect(find.byKey(const ValueKey('failed-run-response-text')),
            findsNothing);
      } else {
        expect(find.text('Native code: OUTPUT_LIMIT'), findsOneWidget);
        expect(find.text('Partial answer'), findsOneWidget);
      }
    } else if (whitespace) {
      expect(find.text('  '), findsOneWidget);
      expect(find.text('\n \n'), findsOneWidget);
      expect(find.text('Response from failed run'), findsOneWidget);
    } else if (sensitive) {
      expect(find.text('Native code: OUTPUT_LIMIT'), findsOneWidget);
      expect(find.text('Truncated to size limit.'), findsOneWidget);
      expect(find.text('Omitted sensitive field(s): providerErrorText.'),
          findsOneWidget);
      expect(find.textContaining('secret_token_1234567890'), findsNothing);
      await tester.tap(find.text('Show full response'));
      await tester.pump();
      expect(find.text('界' * 10922), findsOneWidget);
    } else {
      expect(
          find.text('The assignment could not be completed.'), findsOneWidget);
      expect(find.text('Native code: OUTPUT_LIMIT'), findsOneWidget);
      expect(find.text('Output limit reached'), findsOneWidget);
      expect(find.text('Response from failed run'), findsOneWidget);
      expect(find.text('Partial answer'), findsOneWidget);
    }
  }, skip: path == null);
}
