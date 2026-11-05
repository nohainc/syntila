import 'dart:async';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';

import 'mcp_host.dart';
import 'plugin_host.dart';

/// Executes one assignment on an MCP Worker (`MCP_WORKER_PROFILE_V1.md`):
/// `syntila.execute` for work and `syntila.probe` for readiness, through the
/// Engine's [McpHost]. Results use the same [PluginRunOutcome] types as the
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
  static const protocolTag = 'syntila.worker/1';

  /// [cancel] completing requests cooperative cancellation; after
  /// [McpLimits.cancelGrace] the server is killed. [onProgress] receives
  /// percentage (when the server reports a total) and message.
  Future<PluginRunOutcome> run(
    McpServerSpec spec,
    PluginRunRequest request, {
    Future<void>? cancel,
    void Function(int? percentage, String message)? onProgress,
    String? workingDirectory,
  }) async {
    final McpLease lease;
    try {
      lease = await _host.acquire(spec);
    } on McpException catch (error) {
      return _failure(error);
    } on PluginLaunchException catch (error) {
      return PluginRunFailure(code: error.code, message: error.message);
    }

    var cancelled = false;
    var finished = false;
    try {
      if (!lease.tools.any((t) => t['name'] == executeTool)) {
        await lease.discard();
        return const PluginRunFailure(
          code: PluginHostFailure.protocolViolation,
          message: 'The MCP Worker does not provide syntila.execute.',
        );
      }
      final McpCall call;
      try {
        call = await lease.callTool(
          executeTool,
          {
            'protocol': protocolTag,
            'prompt': request.prompt,
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
            if (workingDirectory != null) 'workingDirectory': workingDirectory,
          },
          timeout: request.deadline,
          onProgress: onProgress == null
              ? null
              : (progress, total, message) => onProgress(
                  total != null && total > 0
                      ? (progress / total * 100).clamp(0, 100).round()
                      : null,
                  message ?? '',
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
      return _outcome(result);
    } finally {
      finished = true;
      lease.release();
    }
  }

  /// Readiness (`syntila.probe`). A server without the tool is reported as
  /// `unavailable` with a stable issue code rather than throwing.
  Future<PluginRunOutcome> probe(McpServerSpec spec, String mode) async {
    final McpLease lease;
    try {
      lease = await _host.acquire(spec);
    } on McpException catch (error) {
      return _failure(error);
    } on PluginLaunchException catch (error) {
      return PluginRunFailure(code: error.code, message: error.message);
    }
    try {
      if (!lease.tools.any((t) => t['name'] == probeTool)) {
        return const PluginProbeSuccess(
          state: 'unavailable',
          issueCode: PluginHostFailure.protocolViolation,
          checks: [],
        );
      }
      final result = await (await lease.callTool(probeTool, {
        'mode': mode,
      }, timeout: PluginProtocolLimits.handshakeTimeout * 3)).result;
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
        return const PluginRunFailure(
          code: PluginHostFailure.protocolViolation,
          message: 'syntila.probe returned an unknown state.',
        );
      }
      return PluginProbeSuccess(
        state: state,
        issueCode: data['issueCode'] as String?,
        checks: [
          for (final c in (data['checks'] as List? ?? const []).take(32))
            if (c is Map) Map<String, Object?>.from(c),
        ],
      );
    } on McpException catch (error) {
      await lease.discard();
      return _failure(error);
    } finally {
      lease.release();
    }
  }

  PluginRunOutcome _cancelled() => const PluginRunFailure(
    code: 'cancelled',
    message: 'The assignment was cancelled.',
  );

  PluginRunFailure _failure(McpException error) {
    final code = switch (error.code) {
      McpFailure.versionUnsupported => PluginHostFailure.protocolUnsupported,
      McpFailure.serverCrashed => PluginHostFailure.crashed,
      McpFailure.timeout => 'timeout',
      McpFailure.resultTooLarge => 'output_too_large',
      McpFailure.definitionChanged => PluginHostFailure.identityMismatch,
      McpFailure.authRequired => 'sign_in_required',
      _ => PluginHostFailure.protocolViolation,
    };
    return PluginRunFailure(
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

  PluginRunOutcome _outcome(Map<String, Object?> result) {
    final data = _structured(result);
    if (result['isError'] == true) {
      final issue = data['issue'];
      final issueMap = issue is Map ? issue : const {};
      final rawCode = issueMap['code'];
      final code = rawCode is String && pluginErrorCodes.contains(rawCode)
          ? rawCode
          : 'internal';
      final message = issueMap['message'] is String
          ? issueMap['message'] as String
          : 'The MCP Worker reported an error.';
      return PluginRunFailure(
        code: code,
        message: message.length > PluginProtocolLimits.maxErrorMessageLength
            ? message.substring(0, PluginProtocolLimits.maxErrorMessageLength)
            : message,
        retryable: code == 'rate_limited' || code == 'timeout',
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
      return const PluginRunFailure(
        code: PluginHostFailure.protocolViolation,
        message: 'The MCP Worker returned no text result.',
      );
    }
    if (text.length > PluginProtocolLimits.maxOutputBytes) {
      return const PluginRunFailure(
        code: 'output_too_large',
        message: 'The MCP Worker output exceeded the limit.',
      );
    }
    final artifacts = <String>[];
    final raw = data['artifacts'];
    if (raw != null) {
      if (raw is! List || raw.length > PluginProtocolLimits.maxArtifacts) {
        return const PluginRunFailure(
          code: PluginHostFailure.artifactPathInvalid,
          message: 'The MCP Worker returned invalid artifacts.',
        );
      }
      for (final a in raw) {
        if (a is! String ||
            a.isEmpty ||
            a.length > PluginProtocolLimits.maxPathLength ||
            a.startsWith('/') ||
            RegExp(r'^[A-Za-z]:[\\/]').hasMatch(a) ||
            a.split(RegExp(r'[\\/]')).contains('..') ||
            a.contains('\u0000')) {
          return const PluginRunFailure(
            code: PluginHostFailure.artifactPathInvalid,
            message: 'An artifact path is not a safe relative path.',
          );
        }
        artifacts.add(a);
      }
    }
    final session = data['session'];
    final key = session is Map ? session['key'] : null;
    return PluginRunSuccess(
      output: text,
      artifacts: artifacts,
      sessionState:
          key is String &&
              key.isNotEmpty &&
              key.length <= PluginProtocolLimits.maxSessionKeyLength
          ? key
          : null,
      droppedFrames: 0,
    );
  }
}
