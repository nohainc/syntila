import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';

AxWorkRequest request(String status,
        {String synthesisStatus = 'queued',
        String? finalText,
        String workflow = 'research',
        int version = 2}) =>
    AxWorkRequest.fromJson({
      'id': 'request',
      'requestedByName': 'User',
      'prompt': 'Compare options',
      'workflowId': workflow,
      'workflowVersion': version,
      'status': status,
      'createdAt': 'now',
      'finalText': finalText,
      'steps': [
        {
          'kind': 'research',
          'stepId': 'research-1',
          'status': 'completed',
          'finalText': 'Individual report'
        },
        {'kind': 'research', 'stepId': 'research-2', 'status': 'failed'},
        {
          'kind': 'synthesis',
          'stepId': 'synthesis',
          'status': synthesisStatus,
          if (synthesisStatus == 'completed') 'finalText': 'Combined answer'
        },
      ],
    });

void main() {
  test('Research never promotes an individual report to the main outcome', () {
    for (final state in ['running', 'failed', 'cancelled', 'completed']) {
      final run = request(state);
      expect(run.primaryResponseText, isNull);
      expect(run.steps.first.resultText, 'Individual report');
    }
    expect(request('running', finalText: 'Stale outcome').primaryResponseText,
        isNull);
  });
  test('Research uses only completed synthesis as its outcome', () {
    expect(
        request('completed', synthesisStatus: 'completed').primaryResponseText,
        'Combined answer');
    expect(
        request('completed',
                synthesisStatus: 'completed', finalText: 'Server outcome')
            .primaryResponseText,
        'Server outcome');
  });
  test('historical Research retains its single-step result fallback', () {
    expect(request('completed', version: 1).primaryResponseText,
        'Individual report');
  });
  researchGapFlagsTests();
}

// Research v2 gap flags come straight from Cloud's read model.
void researchGapFlagsTests() {
  test('Research gap flags default to false and parse from Cloud', () {
    final base = {'id': 'r', 'status': 'failed', 'prompt': 'p'};
    expect(AxWorkRequest.fromJson(base).partialSynthesisAvailable, isFalse);
    final gap = AxWorkRequest.fromJson({
      ...base,
      'partialSynthesisAvailable': true,
      'completedWithGaps': true
    });
    expect(gap.partialSynthesisAvailable, isTrue);
    expect(gap.completedWithGaps, isTrue);
  });
}
