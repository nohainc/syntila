import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('diagnostic events preserve correlation and drop unknown context', () {
    final event = DiagnosticEvent(
      eventId: 'diag-1',
      timestamp: '2026-10-11T12:00:00.000Z',
      requestId: 'request-1',
      assignmentId: 'assignment-1',
      workerTypeId: 'gemini',
      component: 'cli_worker_engine',
      operation: 'execute',
      stage: 'provider_session',
      severity: 'error',
      errorCode: 'session_resume_failed',
      retryable: true,
      context: {
        'providerToolVersion': '1.2.3',
        'processExitCode': 7,
        'traceEpochId': 'trace-12345-42',
        'prompt': 'must not be retained',
        'nested': {'secret': 'must not be retained'},
      },
    );

    final decoded = DiagnosticEvent.fromJson(event.toJson());
    expect(decoded.assignmentId, 'assignment-1');
    expect(decoded.retryable, isTrue);
    expect(decoded.context, {
      'providerToolVersion': '1.2.3',
      'processExitCode': 7,
      'traceEpochId': 'trace-12345-42',
    });
    expect(decoded.toJson(), isNot(contains('prompt')));
  });

  test('invalid timestamps and severities fail closed', () {
    expect(
      () => DiagnosticEvent(
        eventId: 'diag-1',
        timestamp: 'not-a-timestamp',
        component: 'cloud',
        operation: 'execute',
        stage: 'admission',
        severity: 'error',
      ),
      throwsArgumentError,
    );
    expect(
      () => DiagnosticEvent(
        eventId: 'diag-1',
        timestamp: '2026-10-11T12:00:00.000Z',
        component: 'cloud',
        operation: 'execute',
        stage: 'admission',
        severity: 'fatal',
      ),
      throwsArgumentError,
    );
  });
}
