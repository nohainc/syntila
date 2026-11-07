import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';

void main() {
  AxWorkRequest request(String status, List<String> steps) =>
      AxWorkRequest.fromJson({
        'id': 'r',
        'status': status,
        'steps': [
          for (final (i, s) in steps.indexed)
            {'id': 's$i', 'kind': 'implement', 'status': s}
        ],
      });
  test('a phase paused for input does not hold new requests back', () {
    expect(request('waiting', ['completed']).isProcessing, isFalse);
    expect(request('waiting', ['waiting']).isProcessing, isTrue);
    expect(request('waiting', []).isProcessing, isTrue);
    expect(request('running', ['completed']).isProcessing, isTrue);
    expect(request('completed', ['completed']).isProcessing, isFalse);
  });
}
