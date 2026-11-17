import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('Local Worker Protocol 4.4 providerFailure', () {
    test(
        'negotiates 4.4 when both sides support it, and falls back to 4.3 for older peers',
        () {
      expect(
        negotiateProtocolVersion(
          workspaceVersions: ['4.1', '4.2', '4.3', '4.4'],
          workerVersions: ['4.1', '4.2', '4.3', '4.4'],
        ),
        '4.4',
      );
      expect(
        negotiateProtocolVersion(
          workspaceVersions: ['4.1', '4.2', '4.3', '4.4'],
          workerVersions: ['4.1', '4.2', '4.3'],
        ),
        '4.3',
      );
    });

    test('WorkerErrorFrame round-trips with and without providerFailure', () {
      final legacy = WorkerErrorFrame.fromJson(<String, Object?>{
        'type': 'error',
        'requestId': 'req-1',
        'code': WorkerIssueCode.known.first,
        'message': 'Execution failed',
        'retryable': false,
      });
      expect(legacy.providerFailure, isNull);

      final withDetails = WorkerErrorFrame.fromJson(<String, Object?>{
        'type': 'error',
        'requestId': 'req-2',
        'code': WorkerIssueCode.known.first,
        'message': 'Execution failed',
        'retryable': false,
        'providerFailure': <String, Object?>{
          'schemaVersion': 1,
          'nativeErrorCode': 'ERR_QUOTA',
          'providerErrorText': 'Quota exceeded',
          'failedRunResponse': 'Partial response',
          'source': 'structured_error',
        },
      });
      expect(withDetails.providerFailure?['nativeErrorCode'], 'ERR_QUOTA');
    });

    test('WorkerErrorFrame rejects invalid or oversized providerFailure', () {
      expect(
        () => WorkerErrorFrame.fromJson(<String, Object?>{
          'type': 'error',
          'requestId': 'req-3',
          'code': WorkerIssueCode.known.first,
          'message': 'Execution failed',
          'retryable': false,
          'providerFailure': <String, Object?>{
            'schemaVersion': 1,
            'source': 'stderr',
            'nativeErrorCode': 'x' * 129,
          },
        }),
        throwsFormatException,
      );
    });

    test('legacy protocol cannot emit new error fields', () {
      final details = <String, Object?>{'schemaVersion': 1, 'source': 'stderr'};
      expect(
          () => WorkerErrorFrame(
              requestId: 'req',
              code: WorkerIssueCode.providerFailure,
              message: 'failed',
              providerFailure: details),
          throwsFormatException);
      final frame = WorkerErrorFrame(
          requestId: 'req',
          code: WorkerIssueCode.providerFailure,
          message: 'failed',
          providerFailure: details,
          protocolVersion: '4.4');
      expect(frame.toJson()['providerFailure'], details);
    });
  });
}
