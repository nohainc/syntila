import 'package:syntila_cli_worker_engine/src/model_discovery.dart';
import 'package:test/test.dart';

/// `copilot --model` output from GitHub Copilot CLI 1.0.103 on Windows.
const _output = '''
error: a value is required for '--model <model>' but none was supplied
  [possible values: auto, claude-sonnet-5.5, claude-sonnet-5, claude-fable-5.1, claude-fable-5, claude-opus-5.5, claude-opus-5, claude-opus-4.8, claude-opus-4.8-fast, claude-sonnet-4.6, claude-haiku-5.5, claude-haiku-4.5, gpt-6.1-sol, gpt-6-sol, gpt-6-luna, gpt-6-astra, gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5, gpt-5.4, gpt-5.4-mini, gpt-5.3-codex, gpt-5-mini, mai-code-1.1-flash, gemini-4-argon, gemini-3.8-flash, gemini-3.7-flash, grok-4.7, grok-4.6, grok-4.5, kimi-k3]

For more information, try '--help'.
''';

void main() {
  test('parses clap possible values with Profile efforts', () {
    final models = parseClapPossibleValues(
      _output,
      '',
      catalog: [
        {'id': 'auto', 'name': 'Auto', 'supportedReasoningEfforts': <String>[]},
        {
          'id': 'kimi-k3',
          'name': 'Kimi K3',
          'supportedReasoningEfforts': ['low', 'high', 'max'],
        },
      ],
      defaultEfforts: const ['low', 'medium', 'high', 'xhigh', 'max'],
      excludeIds: const {'claude-haiku-4.5'},
    );
    final byId = {for (final m in models) m.id: m};
    expect(models, hasLength(31));
    expect(byId.containsKey('claude-haiku-4.5'), isFalse);
    expect(byId['auto']!.supportedReasoningEfforts, isEmpty);
    expect(byId['kimi-k3']!.supportedReasoningEfforts, ['low', 'high', 'max']);
    // A model the Profile does not know gets the standard list.
    expect(byId['grok-4.5']!.supportedReasoningEfforts, [
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
    ]);
    expect(byId['grok-4.5']!.name, 'Grok 4.5');
  });

  test('derives readable names from model IDs', () {
    expect(readableModelName('claude-sonnet-5.5'), 'Claude Sonnet 5.5');
    expect(readableModelName('claude-opus-4.8-fast'), 'Claude Opus 4.8 Fast');
    expect(readableModelName('gpt-5.3-codex'), 'GPT-5.3 Codex');
    expect(readableModelName('gpt-5-mini'), 'GPT-5 Mini');
    expect(readableModelName('mai-code-1.1-flash'), 'MAI Code 1.1 Flash');
    expect(readableModelName('gemini-4-argon'), 'Gemini 4 Argon');
  });

  test('rejects output without a possible values list', () {
    expect(
      () => parseClapPossibleValues('error: unexpected argument', ''),
      throwsFormatException,
    );
  });

  group('Copilot SDK models.list', () {
    test('a Free account (empty list) offers no explicit model', () {
      final models = parseCopilotSdkModels({
        'models': <Object?>[],
        'imageModels': <Object?>[],
      }, '');
      // Nothing is selectable, so no model is required.
      expect(models, isEmpty);
    });

    test('maps names and efforts and skips disabled models', () {
      final models = parseCopilotSdkModels(
        {
          'models': [
            {
              'id': 'claude-sonnet-5.5',
              'name': 'Claude Sonnet 5.5',
              'policy': {'state': 'enabled'},
              'supportedReasoningEfforts': ['low', 'medium', 'high'],
              'defaultReasoningEffort': 'medium',
            },
            {
              'id': 'gpt-5-mini',
              'policy': {'state': 'disabled'},
            },
            {'id': 'grok-4.5'},
          ],
        },
        '',
        excludeIds: const {'grok-4.5'},
      );
      expect(models.map((m) => m.id), ['claude-sonnet-5.5']);
      final sonnet = models.single;
      expect(sonnet.name, 'Claude Sonnet 5.5');
      expect(sonnet.supportedReasoningEfforts, ['low', 'medium', 'high']);
      expect(sonnet.defaultReasoningEffort, 'medium');
    });

    test('rejects a malformed result', () {
      expect(
        () => parseCopilotSdkModels({'data': []}, ''),
        throwsFormatException,
      );
    });
  });
}
