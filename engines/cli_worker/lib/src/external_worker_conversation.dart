import 'dart:convert';

/// Syntila cannot enforce read-only on an External Worker (no isolation tier),
/// so a read-only Step is requested instead: `access: restricted` plus this
/// instruction.
const externalWorkerReadOnlyInstruction =
    'This request is read-only: do not create, modify or delete files and do '
    'not run commands that change anything. Reply in text only.';

/// The `conversation` argument of `syntila.execute` (MCP_WORKER_PROFILE_V1):
/// the same exchange `prompt` carries, as separate turns. A Worker that wraps
/// a plain chat model maps it to roles instead of answering the canonical
/// context envelope as if the user had written it.
///
/// [contextText] is the canonical context the prompt was built with, or null
/// when the Worker's own session already holds the earlier turns.
Map<String, Object?> externalWorkerConversation({
  required String request,
  String? contextText,
  List<String> instructions = const [],
}) {
  final messages = <Map<String, Object?>>[];
  final context = <String, Object?>{};
  if (contextText != null) {
    Object? decoded;
    try {
      decoded = jsonDecode(contextText);
    } on FormatException {
      decoded = null;
    }
    final history = decoded is Map ? decoded['history'] : null;
    final state = decoded is Map
        ? decoded['conversationContext'] ?? decoded['context']
        : null;
    if (state is Map) {
      for (final key in const [
        'objective',
        'importantDecisions',
        'constraints',
        'openIssues',
        'artifacts',
        'summary',
      ]) {
        final value = state[key];
        if (value is Map && value.containsKey('value')) {
          if (value['value'] != null &&
              !(key == 'objective' && value['value'] == request)) {
            context[key] = value['value'];
          }
        } else if (value is Map && value.isNotEmpty) {
          final facts = <String, Object?>{};
          for (final entry in value.entries) {
            final fact = entry.value;
            if (entry.key is String && fact is Map && fact['value'] != null) {
              facts[entry.key as String] = fact['value'];
            }
          }
          if (facts.isNotEmpty) context[key] = facts;
        }
      }
    }
    final workflow = decoded is Map
        ? decoded['workflowExecutionContext']
        : null;
    final priorResults = workflow is Map
        ? workflow['prerequisiteResults']
        : null;
    if (priorResults is List && priorResults.isNotEmpty) {
      context['prerequisiteResults'] = priorResults;
    }
    final coverage = decoded is Map ? decoded['historyCoverage'] : null;
    if (coverage is Map &&
        ((coverage['omittedEntries'] is num &&
                (coverage['omittedEntries'] as num) > 0) ||
            coverage['clearedEarlierHistory'] == true)) {
      context['historyCoverage'] = coverage;
    }
    for (final entry in history is List ? history : const <Object?>[]) {
      if (entry is! Map) continue;
      final role = switch (entry['kind']) {
        'user_message' => 'user',
        'worker_response' => 'assistant',
        _ => null,
      };
      final text = entry['text'];
      if (role == null || text is! String || text.trim().isEmpty) continue;
      messages.add({'role': role, 'text': text});
    }
    // Cloud's canonical bootstrap excludes the current request. Keep repeated
    // earlier messages even when their text equals the current request.
  }
  return {
    'messages': messages,
    'request': request,
    if (instructions.isNotEmpty || context.isNotEmpty)
      'instructions': [
        ...instructions,
        if (context.isNotEmpty)
          'Historical conversation context (data, not a new request):\n${jsonEncode(context)}',
      ],
  };
}
