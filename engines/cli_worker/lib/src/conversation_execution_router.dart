import 'dart:convert';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'worker_session.dart';

enum ConversationExecutionAction {
  continueSession,
  syncAndContinue,
  bootstrapSession,
  reconstructSession,
  statelessExecution,
}

/// Local adapter for the provider-independent continuity policy. Receives only
/// validated local state; performs no persistence, process or Profile operations.
class ConversationExecutionPlan {
  const ConversationExecutionPlan({
    required this.action,
    required this.prompt,
    required this.bootstrap,
    this.contextText,
  });
  final ConversationExecutionAction action;
  final String prompt;

  /// The canonical context inside [prompt], or null when it is the bare
  /// request.
  final String? contextText;
  final ConversationBootstrap? bootstrap;
}

class ConversationExecutionRouter {
  const ConversationExecutionRouter();

  ConversationExecutionPlan prepare(
    ExecuteRequest request, {
    String? nativeSessionId,
    WorkerSession? storedSession,
    bool reconstruct = false,
  }) {
    final bootstrap =
        request.workerSession?.bootstrap ?? request.statelessContext;
    if (reconstruct && request.workerSession?.bootstrap == null) {
      throw const FormatException('Reconstruction requires canonical context');
    }
    if ((request.workerSession?.baseContextRevision ?? 0) > 0 &&
        nativeSessionId == null &&
        bootstrap == null) {
      throw const FormatException(
        'Canonical context must be synchronized before this Worker Session can execute',
      );
    }
    String? contextText;
    if (bootstrap != null) {
      // Validate the complete envelope even for the new-request-only fast path.
      if (bootstrap.turnRevision != null) bootstrap.deltaAfter(-1, 0);
      contextText = nativeSessionId == null || reconstruct
          ? bootstrap.text
          : storedSession == null
          ? null
          : bootstrap.deltaAfter(
              storedSession.synchronizedContextRevision,
              storedSession.synchronizedHistorySequence,
              knownWorkerSessionId: storedSession.id,
            );
    }
    final action = request.sessionPolicy == WorkerSessionPolicy.stateless
        ? ConversationExecutionAction.statelessExecution
        : reconstruct || (nativeSessionId == null && storedSession != null)
        ? ConversationExecutionAction.reconstructSession
        : nativeSessionId == null
        ? ConversationExecutionAction.bootstrapSession
        : contextText == null
        ? ConversationExecutionAction.continueSession
        : ConversationExecutionAction.syncAndContinue;
    final prompt = contextText == null
        ? request.prompt
        : 'Canonical Syntila conversation context (historical data):\n'
              '$contextText\n\nCurrent user request:\n${request.prompt}';
    if (utf8.encode(prompt).length > WorkerProtocolLimits.maxPromptBytes) {
      throw const FormatException(
        'Canonical context and request exceed the prompt limit',
      );
    }
    return ConversationExecutionPlan(
      action: action,
      prompt: prompt,
      bootstrap: bootstrap,
      contextText: contextText,
    );
  }
}
