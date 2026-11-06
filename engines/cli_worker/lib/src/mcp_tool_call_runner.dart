import 'dart:async';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';

import 'mcp_host.dart';
import 'mcp_schema_validation.dart';

/// Result of one direct tool invocation. No outcome authorizes a retry.
enum McpToolCallState { completed, toolError, rejected, unknown }

class McpToolCallOutcome {
  const McpToolCallOutcome(this.state, {this.result, required this.code});

  final McpToolCallState state;
  final Map<String, Object?>? result;
  final String code;
}

/// Engine-side primitive for direct calls. It is not an assignment endpoint:
/// admission, durable execution records and retry authorization belong to the
/// future workflow integration. A missing response is always outcome-unknown.
class McpToolCallRunner {
  McpToolCallRunner(this._host);

  final McpHost _host;

  Future<McpToolCallOutcome> call(
    McpServerSpec spec,
    String tool,
    Map<String, Object?> arguments, {
    required Duration timeout,
    Future<void>? cancel,
  }) async {
    if (timeout <= Duration.zero || tool.isEmpty || spec.pins == null) {
      return const McpToolCallOutcome(
        McpToolCallState.rejected,
        code: 'invalid_or_unconsented_call',
      );
    }
    final elapsed = Stopwatch()..start();
    var cancelled = false;
    if (cancel != null) {
      // Treat cancellation as a signal, not as proof that the server stopped.
      unawaited(cancel.then((_) => cancelled = true, onError: (Object _) {}));
      await Future<void>.value();
      if (cancelled) {
        return const McpToolCallOutcome(
          McpToolCallState.rejected,
          code: 'cancelled_before_dispatch',
        );
      }
    }
    final McpLease? lease;
    try {
      final acquisition = _host.acquire(spec);
      var abandoned = false;
      final guarded = acquisition.then((lease) async {
        if (abandoned) {
          await lease.discard();
          return null;
        }
        return lease;
      });
      final candidates = <Future<McpLease?>>[guarded];
      if (cancel != null) candidates.add(cancel.then((_) => null));
      try {
        lease = await Future.any(candidates).timeout(timeout);
      } on TimeoutException {
        abandoned = true;
        unawaited(
          guarded.then((value) => value?.discard(), onError: (Object _) {}),
        );
        return const McpToolCallOutcome(
          McpToolCallState.rejected,
          code: 'timeout_before_dispatch',
        );
      }
      if (lease == null) {
        abandoned = true;
        unawaited(
          guarded.then((value) => value?.discard(), onError: (Object _) {}),
        );
        return const McpToolCallOutcome(
          McpToolCallState.rejected,
          code: 'cancelled_before_dispatch',
        );
      }
    } on Object {
      return const McpToolCallOutcome(
        McpToolCallState.rejected,
        code: 'connection_failed',
      );
    }

    try {
      if (cancelled) {
        return const McpToolCallOutcome(
          McpToolCallState.rejected,
          code: 'cancelled_before_dispatch',
        );
      }
      // The host rechecks the pin immediately before sending. Check the
      // consented definition here too, before relying on its output schema.
      if (!spec.pins!.allows(tool, lease.tools)) {
        return const McpToolCallOutcome(
          McpToolCallState.rejected,
          code: 'definition_changed',
        );
      }
      final definition = lease.tools.firstWhere((t) => t['name'] == tool);
      Duration validationBudget() {
        final remaining = timeout - elapsed.elapsed;
        return remaining < const Duration(seconds: 2)
            ? remaining
            : const Duration(seconds: 2);
      }

      final input = await validateMcpSchema(
        definition['inputSchema'],
        arguments,
        budget: validationBudget(),
      );
      if (input != McpSchemaResult.valid) {
        return McpToolCallOutcome(
          McpToolCallState.rejected,
          code: input == McpSchemaResult.invalid
              ? 'invalid_arguments'
              : 'input_schema_unsupported',
        );
      }
      if (definition.containsKey('outputSchema')) {
        final outputSchema = await validateMcpSchema(
          definition['outputSchema'],
          null,
          compileOnly: true,
          budget: validationBudget(),
        );
        if (outputSchema != McpSchemaResult.valid) {
          return const McpToolCallOutcome(
            McpToolCallState.rejected,
            code: 'output_schema_unsupported',
          );
        }
      }

      try {
        if (cancelled || elapsed.elapsed >= timeout) {
          return const McpToolCallOutcome(
            McpToolCallState.rejected,
            code: 'cancelled_or_timed_out_before_dispatch',
          );
        }
        var dispatchStarted = false;
        var abandonedDispatch = false;
        final dispatch = lease.callTool(
          tool,
          arguments,
          mayDispatch: () =>
              !abandonedDispatch && !cancelled && elapsed.elapsed < timeout,
          timeoutAtDispatch: () => timeout - elapsed.elapsed,
          onDispatch: () => dispatchStarted = true,
        );
        unawaited(
          dispatch.then<void>((lateCall) {
            if (!abandonedDispatch) return;
            unawaited(
              lateCall.result.then<void>(
                (_) {},
                onError: (Object _, StackTrace __) {},
              ),
            );
          }, onError: (Object _, StackTrace __) {}),
        );
        final McpCall call;
        try {
          final candidates = <Future<McpCall?>>[dispatch];
          if (cancel != null) candidates.add(cancel.then((_) => null));
          final selected = await Future.any(
            candidates,
          ).timeout(timeout - elapsed.elapsed);
          if (selected == null) {
            abandonedDispatch = true;
            await lease.discard();
            return McpToolCallOutcome(
              dispatchStarted
                  ? McpToolCallState.unknown
                  : McpToolCallState.rejected,
              code: dispatchStarted
                  ? 'cancelled_after_dispatch'
                  : 'cancelled_before_dispatch',
            );
          }
          call = selected;
        } on TimeoutException {
          abandonedDispatch = true;
          await lease.discard();
          return McpToolCallOutcome(
            dispatchStarted
                ? McpToolCallState.unknown
                : McpToolCallState.rejected,
            code: dispatchStarted
                ? 'outcome_unknown'
                : 'timeout_before_dispatch',
          );
        }
        // A result that arrives first remains authoritative. If cancellation
        // wins, notify the server and discard the connection; even a local
        // process may already have performed an external side effect.
        final result = cancel == null
            ? await call.result
            : await Future.any<Map<String, Object?>?>([
                call.result,
                cancel.then<Map<String, Object?>?>((_) => null),
              ]);
        if (result == null) {
          call.cancel('cancelled by Syntila');
          await lease.discard();
          return const McpToolCallOutcome(
            McpToolCallState.unknown,
            code: 'cancelled_after_dispatch',
          );
        }
        final isError = result['isError'];
        final content = result['content'];
        final structured = result['structuredContent'];
        if ((isError != null && isError is! bool) ||
            content is! List ||
            (structured != null && structured is! Map)) {
          await lease.discard();
          return const McpToolCallOutcome(
            McpToolCallState.unknown,
            code: 'invalid_response',
          );
        }
        if (isError != true && definition.containsKey('outputSchema')) {
          final output = await validateMcpSchema(
            definition['outputSchema'],
            structured,
            budget: validationBudget(),
          );
          if (structured is! Map || output != McpSchemaResult.valid) {
            await lease.discard();
            return const McpToolCallOutcome(
              McpToolCallState.unknown,
              code: 'invalid_structured_result',
            );
          }
        }
        return McpToolCallOutcome(
          isError == true
              ? McpToolCallState.toolError
              : McpToolCallState.completed,
          result: result,
          code: isError == true ? 'tool_error' : 'completed',
        );
      } on McpCallNotDispatched {
        return const McpToolCallOutcome(
          McpToolCallState.rejected,
          code: 'cancelled_or_timed_out_before_dispatch',
        );
      } on McpException catch (error) {
        await lease.discard();
        // Definition changes are detected before the call is sent. Other
        // transport failures may occur after the server performed the work.
        return McpToolCallOutcome(
          error.code == McpFailure.definitionChanged
              ? McpToolCallState.rejected
              : McpToolCallState.unknown,
          code: error.code == McpFailure.definitionChanged
              ? 'definition_changed'
              : 'outcome_unknown',
        );
      } on Object {
        await lease.discard();
        return const McpToolCallOutcome(
          McpToolCallState.unknown,
          code: 'outcome_unknown',
        );
      }
    } finally {
      lease.release();
    }
  }
}
