import 'dart:async';
import 'dart:convert';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_external_worker_protocol/syntila_external_worker_protocol.dart';

import 'mcp_host.dart';
import 'external_worker_process_host.dart';
import 'external_worker_redactor.dart';

/// Executes one assignment on an MCP Worker (`MCP_WORKER_PROFILE_V1.md`):
/// `syntila.execute` for work and `syntila.probe` for readiness, through the
/// Engine's [McpHost]. Results use the same [ExternalWorkerRunOutcome] types as the
/// NDJSON plugin host so callers handle both executors identically.
///
/// The server must be a Worker-class server (`McpServerSpec.requireWorkerProfile`)
/// and its tool pins must come from consent. A cancelled, timed-out or
/// misbehaving server is killed, never reused.
class McpWorkerRunner {
  McpWorkerRunner(this._host);

  final McpHost _host;

  static const executeTool = 'syntila.execute';
  static const probeTool = 'syntila.probe';
  static const modelsTool = 'syntila.models';
  static const protocolTag = 'syntila.worker/1';

  /// [cancel] completing requests cooperative cancellation; after
  /// [McpLimits.cancelGrace] the server is killed. [onProgress] receives
  /// percentage (when the server reports a total) and message.
  Future<ExternalWorkerRunOutcome> run(
    McpServerSpec spec,
    ExternalWorkerRunRequest request, {
    Future<void>? cancel,
    void Function(int? percentage, String message)? onProgress,
    String? workingDirectory,
  }) async {
    final McpLease lease;
    try {
      lease = await _host.acquire(spec);
    } on McpException catch (error) {
      return _failure(error);
    } on ExternalWorkerLaunchException catch (error) {
      return ExternalWorkerRunFailure(code: error.code, message: error.message);
    }

    final redactor = ExternalWorkerRedactor(secrets: spec.secrets);
    var cancelled = false;
    var finished = false;
    try {
      if (!lease.tools.any((t) => t['name'] == executeTool)) {
        await lease.discard();
        return const ExternalWorkerRunFailure(
          code: ExternalWorkerHostFailure.protocolViolation,
          message: 'The MCP Worker does not provide syntila.execute.',
        );
      }
      final executeDefinition = lease.tools.firstWhere(
        (t) => t['name'] == executeTool,
      );
      final schema = executeDefinition['inputSchema'];
      final properties = schema is Map ? schema['properties'] : null;
      final acceptsExecution =
          schema is! Map ||
          schema['additionalProperties'] != false ||
          (properties is Map && properties.containsKey('execution'));
      final McpCall call;
      try {
        call = await lease.callTool(
          executeTool,
          {
            'protocol': protocolTag,
            'prompt': request.prompt,
            if (request.conversation != null)
              'conversation': request.conversation,
            if (acceptsExecution && request.execution != null)
              'execution': request.execution,
            'access': request.access == 'read_write' ? 'work' : 'restricted',
            'deadline': DateTime.now()
                .toUtc()
                .add(request.deadline)
                .toIso8601String(),
            if (request.model != null) 'model': request.model,
            if (request.sessionKey != null)
              'session': {
                'key': request.sessionKey,
                'mode': request.sessionMode,
              },
            if (workingDirectory != null && !spec.isRemote)
              'workingDirectory': workingDirectory,
          },
          timeout: request.deadline,
          onProgress: onProgress == null
              ? null
              : (progress, total, message) => onProgress(
                  total != null && total > 0
                      ? (progress / total * 100).clamp(0, 100).round()
                      : null,
                  _bounded(
                    redactor.redact(message ?? ''),
                    ExternalWorkerLimits.maxProgressMessageLength,
                  ),
                ),
        );
      } on McpException catch (error) {
        await lease.discard();
        return _failure(error);
      }

      // Race the result against "cancel requested + grace elapsed". A null
      // from the second branch means the server ignored the cancel.
      final raced = <Future<Map<String, Object?>?>>[call.result];
      if (cancel != null) {
        raced.add(
          cancel.then((_) async {
            if (finished) return null;
            cancelled = true;
            call.cancel('cancelled by Syntila');
            await Future<void>.delayed(McpLimits.cancelGrace);
            return null;
          }),
        );
      }
      final Map<String, Object?>? result;
      try {
        result = await Future.any(raced);
      } on McpException catch (error) {
        await lease.discard();
        return cancelled ? _cancelled() : _failure(error);
      }
      finished = true;
      if (cancelled || result == null) {
        // Cancelled by the user, or the server ignored the cancel: either way
        // the process is killed and never reused.
        await lease.discard();
        return _cancelled();
      }
      return _outcome(result, redactor);
    } finally {
      finished = true;
      lease.release();
    }
  }

  /// Readiness (`syntila.probe`). A server without the tool is reported as
  /// `unavailable` with a stable issue code rather than throwing.
  Future<ExternalWorkerRunOutcome> probe(
    McpServerSpec spec,
    String mode,
  ) async {
    final McpLease lease;
    try {
      lease = await _host.acquire(spec);
    } on McpException catch (error) {
      return _failure(error);
    } on ExternalWorkerLaunchException catch (error) {
      return ExternalWorkerRunFailure(code: error.code, message: error.message);
    }
    try {
      if (!lease.tools.any((t) => t['name'] == probeTool)) {
        return const ExternalWorkerProbeSuccess(
          state: 'unavailable',
          issueCode: ExternalWorkerHostFailure.protocolViolation,
          checks: [],
        );
      }
      final result = await (await lease.callTool(probeTool, {
        'mode': mode,
      }, timeout: ExternalWorkerLimits.handshakeTimeout * 3)).result;
      final data = _structured(result);
      const states = {
        'ready',
        'setup_required',
        'sign_in_required',
        'unavailable',
        'failed',
      };
      final state = data['state'];
      if (state is! String || !states.contains(state)) {
        return const ExternalWorkerRunFailure(
          code: ExternalWorkerHostFailure.protocolViolation,
          message: 'syntila.probe returned an unknown state.',
        );
      }
      // Same shape and bounds as the NDJSON probe: {code, ok, message}.
      final redactor = ExternalWorkerRedactor(secrets: spec.secrets);
      final rawChecks = data['checks'] ?? const <Object?>[];
      if (rawChecks is! List ||
          rawChecks.length > ExternalWorkerLimits.maxChecks) {
        return _badChecks();
      }
      final checks = <Map<String, Object?>>[];
      for (final c in rawChecks) {
        if (c is! Map ||
            c['code'] is! String ||
            (c['code'] as String).isEmpty ||
            (c['code'] as String).length > 64 ||
            c['ok'] is! bool ||
            c['message'] is! String ||
            (c['message'] as String).isEmpty ||
            (c['message'] as String).length >
                ExternalWorkerLimits.maxCheckMessageLength) {
          return _badChecks();
        }
        checks.add({
          'code': c['code'],
          'ok': c['ok'],
          'message': redactor.redact(c['message'] as String),
        });
      }
      return ExternalWorkerProbeSuccess(
        state: state,
        issueCode: data['issueCode'] as String?,
        checks: checks,
        capabilities: data['capabilities'] is Map
            ? Map<String, Object?>.from(data['capabilities'] as Map)
            : const {},
      );
    } on McpException catch (error) {
      await lease.discard();
      return _failure(error);
    } finally {
      lease.release();
    }
  }

  /// Model discovery (`syntila.models`, optional). A server without the tool
  /// has no discoverable models, which is not an error.
  Future<ExternalWorkerRunOutcome> models(McpServerSpec spec) async {
    final McpLease lease;
    try {
      lease = await _host.acquire(spec);
    } on McpException catch (error) {
      return _failure(error);
    } on ExternalWorkerLaunchException catch (error) {
      return ExternalWorkerRunFailure(code: error.code, message: error.message);
    }
    try {
      if (!lease.tools.any((t) => t['name'] == modelsTool)) {
        return const ExternalWorkerModelsSuccess([]);
      }
      final result = await (await lease.callTool(
        modelsTool,
        const {},
        timeout: const Duration(seconds: 8),
      )).result;
      final raw = _structured(result)['models'];
      return ExternalWorkerModelsSuccess([
        if (raw is List)
          for (final m in raw.take(ExternalWorkerLimits.maxModels))
            if (m is Map) Map<String, Object?>.from(m),
      ]);
    } on McpException catch (error) {
      await lease.discard();
      return _failure(error);
    } finally {
      lease.release();
    }
  }

  ExternalWorkerRunFailure _badChecks() => const ExternalWorkerRunFailure(
    code: ExternalWorkerHostFailure.protocolViolation,
    message: 'syntila.probe returned a malformed check.',
  );

  static String _bounded(String text, int max) =>
      text.length > max ? text.substring(0, max) : text;

  ExternalWorkerRunOutcome _cancelled() => const ExternalWorkerRunFailure(
    code: 'cancelled',
    message: 'The assignment was cancelled.',
  );

  ExternalWorkerRunFailure _failure(McpException error) {
    final code = switch (error.code) {
      McpFailure.versionUnsupported =>
        ExternalWorkerHostFailure.protocolUnsupported,
      McpFailure.serverCrashed => ExternalWorkerHostFailure.crashed,
      McpFailure.timeout => 'timeout',
      McpFailure.resultTooLarge => 'output_too_large',
      McpFailure.definitionChanged =>
        ExternalWorkerHostFailure.identityMismatch,
      McpFailure.authRequired => 'sign_in_required',
      _ => ExternalWorkerHostFailure.protocolViolation,
    };
    return ExternalWorkerRunFailure(
      code: code,
      message: error.message,
      retryable: error.code == McpFailure.timeout,
    );
  }

  Map<String, Object?> _structured(Map<String, Object?> result) {
    final structured = result['structuredContent'];
    if (structured is Map) return Map<String, Object?>.from(structured);
    return const {};
  }

  ExternalWorkerRunOutcome _outcome(
    Map<String, Object?> result,
    ExternalWorkerRedactor redactor,
  ) {
    final data = _structured(result);
    if (result['isError'] == true) {
      final issue = data['issue'];
      final issueMap = issue is Map ? issue : const {};
      final rawCode = issueMap['code'];
      final code =
          rawCode is String && externalWorkerErrorCodes.contains(rawCode)
          ? rawCode
          : 'internal';
      final message = issueMap['message'] is String
          ? redactor.redact(issueMap['message'] as String)
          : 'The MCP Worker reported an error.';
      return ExternalWorkerRunFailure(
        code: code,
        message: _bounded(message, ExternalWorkerLimits.maxErrorMessageLength),
        retryable:
            issueMap['retryable'] == true ||
            code == 'rate_limited' ||
            code == 'timeout',
        fromPlugin: true,
      );
    }
    var text = data['text'];
    if (text is! String) {
      // Fall back to the first text content block.
      final content = result['content'];
      if (content is List && content.isNotEmpty && content.first is Map) {
        text = (content.first as Map)['text'];
      }
    }
    if (text is! String) {
      return const ExternalWorkerRunFailure(
        code: ExternalWorkerHostFailure.protocolViolation,
        message: 'The MCP Worker returned no text result.',
      );
    }
    if (utf8.encode(text).length > ExternalWorkerLimits.maxOutputBytes) {
      return const ExternalWorkerRunFailure(
        code: 'output_too_large',
        message: 'The MCP Worker output exceeded the limit.',
      );
    }
    final artifacts = <String>[];
    final raw = data['artifacts'];
    if (raw != null) {
      if (raw is! List || raw.length > ExternalWorkerLimits.maxArtifacts) {
        return const ExternalWorkerRunFailure(
          code: ExternalWorkerHostFailure.artifactPathInvalid,
          message: 'The MCP Worker returned invalid artifacts.',
        );
      }
      for (final a in raw) {
        if (a is! String ||
            a.isEmpty ||
            a.length > ExternalWorkerLimits.maxPathLength ||
            a.startsWith('/') ||
            RegExp(r'^[A-Za-z]:[\\/]').hasMatch(a) ||
            a.split(RegExp(r'[\\/]')).contains('..') ||
            a.contains('\u0000')) {
          return const ExternalWorkerRunFailure(
            code: ExternalWorkerHostFailure.artifactPathInvalid,
            message: 'An artifact path is not a safe relative path.',
          );
        }
        artifacts.add(a);
      }
    }
    // The Engine confirms native-session transitions from `session.state`
    // (`created`, `resumed` or `unavailable`), as for NDJSON plugins.
    final session = data['session'];
    final state = session is Map ? session['state'] : null;
    return ExternalWorkerRunSuccess(
      output: text,
      artifacts: artifacts,
      sessionState:
          state is String &&
              const {'created', 'resumed', 'unavailable'}.contains(state)
          ? state
          : null,
      droppedFrames: 0,
    );
  }
}
