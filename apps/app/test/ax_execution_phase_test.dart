import 'package:flutter_test/flutter_test.dart';

import 'package:syntila_app/src/ax/ax_execution_phase.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';
import 'package:syntila_app/src/ax/ax_work_progress.dart';

AxWorkRequestStep step(Map<String, dynamic> json) =>
    AxWorkRequestStep.fromJson({
      'kind': 'implement',
      'status': 'running',
      'assignmentId': 'asg-1',
      ...json,
    });

void main() {
  group('AxExecutionPhase', () {
    test('only running counts as executing', () {
      for (final phase in const [
        'submitted',
        'waiting_for_service',
        'delivering',
        'delivered',
        'queued',
        'starting',
        'uncertain',
      ]) {
        expect(AxExecutionPhase.isExecuting(phase), isFalse, reason: phase);
      }
      expect(AxExecutionPhase.isExecuting('running'), isTrue);
    });

    test('delivery sub-steps read as Queued, starting as Starting', () {
      expect(AxExecutionPhase.label('delivering'), 'Queued');
      expect(AxExecutionPhase.label('starting'), 'Starting');
      expect(AxExecutionPhase.detail('delivering'), 'Sending to your Worker');
      expect(AxExecutionPhase.detail('starting'), 'Starting your worker');
    });

    test('advances only forward and never from or to a terminal phase', () {
      expect(AxExecutionPhase.advances('queued', 'starting'), isTrue);
      expect(AxExecutionPhase.advances('starting', 'running'), isTrue);
      expect(AxExecutionPhase.advances('running', 'starting'), isFalse);
      expect(AxExecutionPhase.advances('running', 'running'), isFalse);
      expect(AxExecutionPhase.advances('completed', 'running'), isFalse);
      expect(AxExecutionPhase.advances('failed', 'running'), isFalse);
      expect(AxExecutionPhase.advances('running', 'completed'), isFalse);
      expect(AxExecutionPhase.advances('running', 'uncertain'), isFalse);
      expect(AxExecutionPhase.advances('uncertain', 'running'), isFalse);
      expect(AxExecutionPhase.advances('queued', 'bogus'), isFalse);
    });
  });

  group('AxWorkRequestStep', () {
    test('parses Cloud phase, failure category and retry advice', () {
      final value = step({
        'status': 'failed',
        'executionPhase': 'failed',
        'failureCategory': 'startup_timeout',
        'failureCategoryMessage': 'Worker startup timed out',
        'retry': {'allowed': true, 'requiresConfirmation': true},
      });
      expect(value.effectivePhase, 'failed');
      expect(value.failureCategoryMessage, 'Worker startup timed out');
      expect(value.retryAllowed, isTrue);
      expect(value.retryRequiresConfirmation, isTrue);
    });

    test('a step without retry advice cannot be retried', () {
      expect(step({}).retryAllowed, isFalse);
    });

    test('parsed terminal status wins over stale execution phase', () {
      for (final status in AxExecutionPhase.terminal) {
        expect(
            step({'status': status, 'executionPhase': 'running'})
                .effectivePhase,
            status);
      }
      expect(step({}).effectivePhase, 'submitted');
    });

    test('a legacy step never claims a pre-start phase as running', () {
      expect(step({'status': 'queued'}).effectivePhase, 'queued');
    });

    test('a terminal status forces the terminal phase', () {
      final running = step({'executionPhase': 'running'});
      expect(running.withStatus('completed').effectivePhase, 'completed');
      expect(running.withStatus('completed').executionPhaseDetail, isNull);
    });

    test('withExecutionPhase keeps the independent step identity', () {
      final value =
          step({'executionPhase': 'queued', 'workerDisplayName': 'W'});
      final next = value.withExecutionPhase('starting');
      expect(next.effectivePhase, 'starting');
      expect(next.workerDisplayName, 'W');
      expect(next.assignmentId, 'asg-1');
    });
  });

  group('AxWorkRequest', () {
    AxWorkRequest request(String status, {String? phase}) =>
        AxWorkRequest.fromJson({
          'id': 'r1',
          'prompt': 'p',
          'status': status,
          'createdAt': '2026-10-14T10:00:00Z',
          'executionPhase': phase,
          'steps': const [],
        });

    test('a terminal status forces the terminal phase', () {
      expect(
          request('running', phase: 'running')
              .copyWith(status: 'failed')
              .executionPhase,
          'failed');
      expect(
          request('running', phase: 'starting')
              .copyWith(status: 'running')
              .executionPhase,
          'starting');
    });
  });

  group('AxWorkProgress', () {
    AxWorkProgress resolve(String status, String? phase) =>
        AxWorkProgress.resolve(
          requestStatus: status,
          activities: const [],
          now: DateTime.utc(2026, 10, 14, 10),
          executionPhase: phase,
        );

    test('a running request is not Running before provider start', () {
      for (final phase in const [
        'delivering',
        'delivered',
        'queued',
        'starting',
      ]) {
        final progress = resolve('running', phase);
        expect(progress.statusLabel, isNot('Running'), reason: phase);
        expect(progress.currentAction, isNot('Working…'), reason: phase);
        expect(progress.isExecuting, isFalse, reason: phase);
      }
      expect(
          resolve('running', 'starting').currentAction, 'Starting your worker');
    });

    test('Running only once Cloud says running', () {
      final progress = resolve('running', 'running');
      expect(progress.statusLabel, 'Running');
      expect(progress.currentAction, 'Working…');
      expect(progress.isExecuting, isTrue);
    });

    test('a terminal request ignores a stale pre-start phase', () {
      final progress = resolve('failed', 'starting');
      expect(progress.isTerminal, isTrue);
      expect(progress.currentAction, isNull);
      expect(progress.statusLabel, 'Failed');
    });

    test('without a phase the old status behavior is unchanged', () {
      expect(resolve('queued', null).statusLabel, 'Queued');
    });
  });
}
