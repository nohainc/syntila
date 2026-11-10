import 'package:syntila_cli_worker_engine/src/model_discovery.dart';
import 'package:test/test.dart';

void main() {
  test('Claude Models API sends the full id and shows display_name', () {
    final models = parseClaudeApiModels({
      'data': [
        {
          'id': 'claude-fable-5-2',
          'display_name': 'Claude Fable 5.2',
          'lifecycle': 'active',
          'capabilities': {
            'effort': {
              'supported': true,
              'low': {'supported': true},
              'medium': {'supported': true},
              'high': {'supported': true},
              'xhigh': {'supported': false},
              'max': {'supported': true},
            },
          },
        },
        {'id': 'claude-old-1', 'display_name': 'Old', 'lifecycle': 'retired'},
        {'id': 'other-model', 'display_name': 'Other'},
      ],
    }, 'claude-');
    expect(models.map((m) => m.id), ['claude-fable-5-2']);
    expect(models.single.name, 'Claude Fable 5.2');
    expect(models.single.supportedReasoningEfforts, [
      'low',
      'medium',
      'high',
      'max',
    ]);
  });
}
