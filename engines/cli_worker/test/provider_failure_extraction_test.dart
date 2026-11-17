import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('Engine provider failure details', () {
    test('preserves both provider error text and failed-run response on 4.4', () {
      final details = sanitizeProviderFailureDetails(
        nativeErrorCode: 'MODEL_ERROR',
        providerErrorText: 'Permission denied for: bash',
        failedRunResponse: 'I could not run bash, here is what I found.',
        source: 'structured_error',
      ).toJson();

      final frame = WorkerErrorFrame(
        requestId: 'req-1',
        assignmentId: 'asg-1',
        code: WorkerIssueCode.providerFailure,
        message: 'Provider execution failed.',
        protocolVersion: providerFailureDetailsProtocolVersion,
        providerFailure: details,
      );

      final decoded = WorkerErrorFrame.fromJson(frame.toJson());
      expect(decoded.providerFailure?['nativeErrorCode'], 'MODEL_ERROR');
      expect(
        decoded.providerFailure?['providerErrorText'],
        'Permission denied for: bash',
      );
      expect(
        decoded.providerFailure?['failedRunResponse'],
        'I could not run bash, here is what I found.',
      );
      expect(decoded.providerFailure?['source'], 'structured_error');
    });

    test('supports stderr-only failure and omits credentials explicitly', () {
      final details = sanitizeProviderFailureDetails(
        providerErrorText: 'fatal: auth failed with Bearer secret_token_1234567890',
        source: 'stderr',
      ).toJson();

      expect(details['source'], 'stderr');
      expect(details['providerErrorText'], isNull);
      expect(details['omitted'], isTrue);
      expect(details['omittedFields'], ['providerErrorText']);
    });

    test('bounds oversized responses and marks truncated', () {
      final details = sanitizeProviderFailureDetails(
        failedRunResponse: 'x' * 40000,
        source: 'result_message',
      ).toJson();

      expect(details['truncated'], isTrue);
      expect((details['failedRunResponse'] as String).length, 32768);
    });
  });
}
