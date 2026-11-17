import 'dart:convert';
import 'dart:io';

const _livePrompt = 'Reply with exactly the word OK. Do not use tools.';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == 'usage') {
    stdout.writeln('fixture usage: 0 of 100 requests used');
    return;
  }
  if (arguments.length == 1 && arguments.single == '--version') {
    stdout.writeln('agy 1.2.3');
    return;
  }
  if (arguments.length == 1 && arguments.single == 'models') {
    stdout.write('''gemini-3.8-flash-high\tGemini 3.8 Flash (High)
gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)
gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
gemini-3.7-flash-high\tGemini 3.7 Flash (High)
gemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)
gemini-3.7-flash-low\tGemini 3.7 Flash (Low)
gemini-3.6-flash-high\tGemini 3.6 Flash (High)
gemini-3.6-flash-medium\tGemini 3.6 Flash (Medium)
gemini-3.6-flash-low\tGemini 3.6 Flash (Low)
gemini-3.1-pro-high\tGemini 3.1 Pro (High)
gemini-3.1-pro-low\tGemini 3.1 Pro (Low)\n''');
    return;
  }

  final input = await stdin.transform(utf8.decoder).join();
  final Object? decodedInput;
  try {
    decodedInput = jsonDecode(input);
  } on FormatException {
    stderr.writeln('fixture expected stream-json user input');
    exitCode = 2;
    return;
  }
  if (decodedInput is! Map ||
      decodedInput['event'] != 'user' ||
      decodedInput['message'] is! Map ||
      (decodedInput['message'] as Map)['content'] is! String ||
      !input.endsWith('\n')) {
    stderr.writeln('fixture received invalid stream-json input');
    exitCode = 2;
    return;
  }
  final transportedPrompt =
      (decodedInput['message'] as Map)['content'] as String;
  final separator = transportedPrompt.indexOf('\n\nCurrent user request:\n');
  final prompt = separator < 0
      ? transportedPrompt
      : transportedPrompt.substring(
          separator + '\n\nCurrent user request:\n'.length,
        );
  if (prompt == 'Failure with response') {
    stdout.writeln(
      jsonEncode({
        'event': 'result',
        'result': {
          'status': 'ERROR',
          'error': 'Output limit reached',
          'response': 'Partial answer',
          'code': 'OUTPUT_LIMIT',
        },
      }),
    );
    return;
  }
  if (prompt == 'Switch without resume' ||
      prompt == 'Switch without resume failure') {
    final prefix =
        'Canonical Syntila conversation context (historical data):\n';
    if (!transportedPrompt.startsWith(prefix) || separator < 0) {
      stderr.writeln('Missing canonical bootstrap');
      exitCode = 2;
      return;
    }
    final context = jsonDecode(
      transportedPrompt.substring(prefix.length, separator),
    ) as Map;
    if (jsonEncode(context['history']) !=
        jsonEncode([
          {'kind': 'user_message', 'text': 'Start model A'},
          {'kind': 'worker_response', 'text': 'Gemini answer'},
        ])) {
      stderr.writeln('Wrong canonical history');
      exitCode = 2;
      return;
    }
  }

  if (prompt == 'Bootstrap other worker' ||
      prompt == 'Sync returning worker' ||
      prompt == 'Sync returning worker failure') {
    const prefix =
        'Canonical Syntila conversation context (historical data):\n';
    if (!transportedPrompt.startsWith(prefix) || separator < 0) {
      stderr.writeln('Missing Worker continuity context');
      exitCode = 2;
      return;
    }
    final history = (jsonDecode(
      transportedPrompt.substring(prefix.length, separator),
    ) as Map)['history'];
    final expected = prompt == 'Bootstrap other worker'
        ? [
            {
              'sequence': 1,
              'contextRevision': 1,
              'kind': 'user_message',
              'text': 'Earlier question',
            },
            {
              'sequence': 2,
              'contextRevision': 1,
              'kind': 'worker_response',
              'text': 'ChatGPT answer',
            },
          ]
        : [
            {
              'sequence': 7,
              'contextRevision': 4,
              'kind': 'user_message',
              'text': 'Other Worker follow-up',
            },
            {
              'sequence': 8,
              'contextRevision': 4,
              'kind': 'worker_response',
              'text': 'New ChatGPT answer',
            },
          ];
    if (jsonEncode(history) != jsonEncode(expected)) {
      stderr.writeln('Incorrect full or delta history');
      exitCode = 2;
      return;
    }
  }
  if (prompt == 'Continue current worker' && separator >= 0) {
    stderr.writeln('Current Worker must receive only its new request');
    exitCode = 2;
    return;
  }

  if (prompt == 'Context stateless') {
    const prefix =
        'Canonical Syntila conversation context (historical data):\n';
    if (separator < 0 || !transportedPrompt.startsWith(prefix)) {
      stderr.writeln('Missing stateless context');
      exitCode = 2;
      return;
    }
    final document = jsonDecode(
      transportedPrompt.substring(prefix.length, separator),
    ) as Map;
    if (document['kind'] != 'StatelessContext' ||
        ((((document['context'] as Map)['workflowState'] as Map)['value']
                as Map)['workflowId'] !=
            'chat')) {
      stderr.writeln('Missing stateless workflow state');
      exitCode = 2;
      return;
    }
  }

  if (prompt.startsWith('Recover unavailable')) {
    final resumed = arguments.contains('--conversation');
    if (resumed || prompt == 'Recover unavailable failure') {
      stderr.writeln('Conversation not found');
      exitCode = 1;
      return;
    }
    const prefix =
        'Canonical Syntila conversation context (historical data):\n';
    if (!transportedPrompt.startsWith(prefix) || separator < 0) {
      stderr.writeln('Missing reconstruction context');
      exitCode = 2;
      return;
    }
    final doc = jsonDecode(
      transportedPrompt.substring(prefix.length, separator),
    ) as Map;
    if (jsonEncode(doc['history']) !=
        jsonEncode([
          {
            'sequence': 1,
            'contextRevision': 1,
            'kind': 'user_message',
            'text': 'Earlier question',
          },
          {
            'sequence': 2,
            'contextRevision': 1,
            'kind': 'worker_response',
            'text': 'ChatGPT answer',
          },
        ])) {
      stderr.writeln('Reconstruction did not use full canonical history');
      exitCode = 2;
      return;
    }
    final content = await File(
      'packages/tool-profile/test/fixtures/antigravity-events/success.jsonl',
    ).readAsString();
    stdout.write(
      content.replaceAll('fixture-conversation-1', 'replacement-conversation'),
    );
    return;
  }

  final isLive = prompt == _livePrompt;
  final isResume = arguments.contains('--conversation');
  final isMismatch = prompt == 'Continue safely';
  final isSessionConflict = prompt == 'Conflicting session';
  final isAuthFailure = prompt == 'Provider auth failure';
  final isQuotaExhausted = prompt == 'Provider quota exhausted';
  final isPermissionFailure = prompt == 'Provider permission failure';
  final isMissingTerminal = prompt == 'Missing terminal';
  final expectedResume =
      prompt == 'Continue durable' ||
      prompt == 'Continue safely' ||
      prompt == 'Continue model B' ||
      prompt == 'Continue model A' ||
      prompt == 'Continue reconstructed' ||
      prompt == 'Continue current worker' ||
      prompt == 'Sync returning worker' ||
      prompt == 'Sync returning worker failure';
  final modelCorrect =
      prompt == 'Start model A' ||
          prompt == 'Continue model A' ||
          prompt == 'Bootstrap other worker' ||
          prompt == 'Continue current worker' ||
          prompt == 'Sync returning worker' ||
          prompt == 'Sync returning worker failure'
      ? _hasPair(arguments, '--model', 'model-A')
      : prompt == 'Continue model B' ||
            prompt == 'Switch without resume' ||
            prompt == 'Switch without resume failure' ||
            prompt == 'Continue reconstructed'
      ? _hasPair(arguments, '--model', 'model-B')
      : prompt == 'Say OK'
      ? _hasPair(arguments, '--model', 'gemini-3.8-flash-high')
      : !arguments.contains('--model');
  final argumentsCorrect =
      _hasPair(arguments, '--input-format', 'stream-json') &&
      _hasPair(arguments, '--output-format', 'stream-json') &&
      arguments.contains('--sandbox') &&
      _hasTimeoutPair(arguments, isLive) &&
      isResume == expectedResume &&
      (!isResume ||
          _hasPair(
            arguments,
            '--conversation',
            prompt == 'Continue reconstructed'
                ? 'fixture-conversation-3'
                : 'fixture-conversation-1',
          )) &&
      modelCorrect;
  final environmentCorrect =
      Platform.environment['NO_COLOR'] == null &&
      Platform.environment['AGY_ADC_AUTH'] == 'agy-fixture-adc' &&
      Platform.environment['GEMINI_API_KEY'] == 'gemini-fixture-key' &&
      Platform.environment['GOOGLE_API_KEY'] == 'google-fixture-key' &&
      Platform.environment['GOOGLE_APPLICATION_CREDENTIALS'] ==
          '/fixture/credentials.json' &&
      Platform.environment['GOOGLE_CLOUD_PROJECT'] == 'fixture-project' &&
      Platform.environment['GOOGLE_CLOUD_LOCATION'] == 'fixture-region' &&
      Platform.environment['GOOGLE_GEMINI_BASE_URL'] ==
          'https://fixture.invalid' &&
      Platform.environment['USERPROFILE']?.isNotEmpty == true &&
      Platform.environment['ProgramFiles']?.isNotEmpty == true &&
      Platform.environment['TMP']?.isNotEmpty == true &&
      Platform.environment['TEMP']?.isNotEmpty == true &&
      Platform.environment['TMPDIR']?.isNotEmpty == true &&
      Platform.environment['LANG']?.isNotEmpty == true &&
      Platform.environment['LC_ALL']?.isNotEmpty == true &&
      Platform.environment['SSL_CERT_FILE']?.isNotEmpty == true &&
      Platform.environment['SSL_CERT_DIR']?.isNotEmpty == true;
  if (!argumentsCorrect || !environmentCorrect) {
    stderr.writeln(
      'fixture arguments/environment mismatch: prompt=$prompt '
      'args=$arguments argsOk=$argumentsCorrect envOk=$environmentCorrect',
    );
    exitCode = 2;
    return;
  }

  if (prompt == 'Switch without resume failure' ||
      prompt == 'Sync returning worker failure') {
    stderr.writeln('fixture bootstrap provider failure');
    exitCode = 1;
    return;
  }

  final fixtureName = isLive
      ? 'live-probe'
      : isMismatch
      ? 'session-mismatch'
      : isSessionConflict
      ? 'session-conflict'
      : isAuthFailure
      ? 'auth-error'
      : isQuotaExhausted
      ? 'quota-exhausted'
      : isPermissionFailure
      ? 'permission-error'
      : prompt == 'Continue after incompatible upgrade' ||
            prompt == 'Switch without resume'
      ? 'fresh-session'
      : isMissingTerminal
      ? 'missing-terminal'
      : 'success';
  final fixture = File(
    'packages/tool-profile/test/fixtures/antigravity-events/$fixtureName.jsonl',
  );
  final content = await fixture.readAsString();
  // The success corpus echoes the initial conversation ID on resumed turns so
  // the Engine can verify the stored identity.
  stdout.write(
    prompt == 'Continue reconstructed'
        ? content.replaceAll('fixture-conversation-1', 'fixture-conversation-3')
        : content,
  );
}

bool _hasPair(List<String> arguments, String key, String value) {
  final index = arguments.indexOf(key);
  return index >= 0 &&
      index + 1 < arguments.length &&
      arguments[index + 1] == value;
}

bool _hasTimeoutPair(List<String> arguments, bool isLive) {
  final index = arguments.indexOf('--print-timeout');
  if (index < 0 || index + 1 >= arguments.length) return false;
  final val = arguments[index + 1];
  if (!val.endsWith('s')) return false;
  final seconds = int.tryParse(val.substring(0, val.length - 1));
  if (seconds == null) return false;
  return isLive
      ? (seconds >= 20 && seconds <= 30)
      : (seconds >= 5 && seconds <= 15);
}
