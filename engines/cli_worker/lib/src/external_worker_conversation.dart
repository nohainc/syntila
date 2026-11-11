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
  if (contextText != null) {
    Object? decoded;
    try {
      decoded = jsonDecode(contextText);
    } on FormatException {
      decoded = null;
    }
    final history = decoded is Map ? decoded['history'] : null;
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
    // The current request is not history, even when the context lists it.
    if (messages.isNotEmpty &&
        messages.last['role'] == 'user' &&
        request.contains(messages.last['text'] as String)) {
      messages.removeLast();
    }
  }
  return {
    'messages': messages,
    'request': request,
    if (instructions.isNotEmpty) 'instructions': instructions,
  };
}
