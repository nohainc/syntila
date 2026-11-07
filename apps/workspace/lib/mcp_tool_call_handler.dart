import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'mcp_tool_call_executor.dart';
import 'mcp_tool_call_fence.dart';
import 'mcp_tool_call_request.dart';

/// Turns a Cloud `mcp.tool_call.request` payload into a `mcp.tool_call.result`
/// payload. Never throws: every failure is a bounded outcome, and anything
/// after the dispatch claim is reported as unknown, never as a safe retry.
class McpToolCallHandler {
  McpToolCallHandler({
    required McpToolCallExecutor executor,
    required Directory stateDirectory,
    required Directory workingDirectory,
    this.maxConcurrentAssignments = 8,
    McpToolCallFence? fence,
    FutureOr<bool> Function(McpToolCallRequest request)? authorizeStart,
  })  : _fence = fence,
        _executor = executor,
        _stateDirectory = stateDirectory,
        _workingDirectory = workingDirectory,
        _authorizeStart = authorizeStart;

  static const maxResultBytes = 256 * 1024;

  final McpToolCallExecutor _executor;

  /// Journal for outcomes of claimed keys; the same fence the executor claims
  /// from. Without it behavior is the original: no local outcome is kept.
  final McpToolCallFence? _fence;
  final Directory _stateDirectory;
  final Directory _workingDirectory;
  final int maxConcurrentAssignments;
  final FutureOr<bool> Function(McpToolCallRequest request)? _authorizeStart;
  final _inFlight = <String>{};

  /// Returns null for a duplicate of a request that is already running; its
  /// single answer is still on the way.
  Future<Map<String, Object?>?> handle(Map<Object?, Object?> payload) async {
    final McpToolCallRequest request;
    try {
      request = McpToolCallRequest.fromJson(Map<String, Object?>.from(payload));
    } on Object {
      final task = payload['taskId'];
      if (task is! String || task.isEmpty || task.length > 900) return null;
      return _result(task, 'rejected', 'invalid_request');
    }
    if (!_inFlight.add(request.taskId)) return null;
    try {
      final assignmentId =
          'mcp-${sha256.convert(utf8.encode(request.taskId)).toString().substring(0, 32)}';
      final outcome = await _executor.execute(
        assignmentId: assignmentId,
        request: request,
        stateDirectory: _stateDirectory,
        workingDirectory: _workingDirectory,
        maxConcurrentAssignments: maxConcurrentAssignments,
        authorizeStart: () => _authorizeStart?.call(request) ?? true,
      );
      final fence = _fence;
      if (fence != null && outcome['code'] == 'dispatch_already_claimed') {
        // Report what this Workspace durably knows about the earlier dispatch.
        // This never calls the tool: a missing or unreadable record stays
        // unknown.
        final recorded = await fence.recordedOutcome(request.dispatchKey);
        if (recorded != null) {
          return _result(
            request.taskId,
            recorded['state'] as String,
            recorded['code'] as String,
            recorded['result'],
          );
        }
      }
      final reply = _result(
        request.taskId,
        outcome['state'] as String,
        outcome['code'] as String,
        outcome['result'],
      );
      if (fence != null &&
          outcome['code'] != 'dispatch_already_claimed' &&
          await fence.wasClaimed(request.dispatchKey)) {
        try {
          await fence.recordOutcome(
            request.dispatchKey,
            state: reply['state']! as String,
            code: reply['code']! as String,
            result: reply['result'] as Map<String, Object?>?,
          );
        } on Object {
          // The journal is diagnostic; the reply to Cloud is unaffected.
        }
      }
      return reply;
    } on Object {
      // The executor reports its own outcomes; a throw means its parameters
      // were invalid, but the safe answer never authorizes a retry.
      return _result(request.taskId, 'unknown', 'outcome_unknown');
    } finally {
      _inFlight.remove(request.taskId);
    }
  }

  /// Read-only reconciliation: what this Workspace durably knows about one
  /// logical key. Never claims, dispatches or executes. Returns null for a
  /// malformed request (nothing to correlate an answer with).
  Future<Map<String, Object?>?> status(Map<Object?, Object?> payload) async {
    final taskId = payload['taskId'];
    final fence = _fence;
    if (fence == null ||
        payload['schemaVersion'] != 1 ||
        payload.keys.any((key) =>
            !const {'schemaVersion', 'taskId', 'dispatchKey'}.contains(key)) ||
        taskId is! String ||
        taskId.isEmpty ||
        taskId.length > 900 ||
        payload['dispatchKey'] != 'mcp-tool-v1:$taskId') {
      return null;
    }
    const dispatchKey = 'mcp-tool-v1:';
    final key = '$dispatchKey$taskId';
    Map<String, Object?> reply(String status, [Map<String, Object?>? extra]) =>
        {
          'schemaVersion': 1,
          'taskId': taskId,
          'dispatchKey': key,
          'status': status,
          ...?extra,
        };
    try {
      if (!await fence.wasClaimed(key)) return reply('unclaimed');
      final recorded = await fence.recordedOutcome(key);
      if (recorded == null) return reply('claimed_no_outcome');
      final answer = _result(
        taskId,
        recorded['state'] as String,
        recorded['code'] as String,
        recorded['result'],
      );
      return reply('recorded', {
        'state': answer['state'],
        'code': answer['code'],
        if (answer.containsKey('result')) 'result': answer['result'],
      });
    } on Object {
      // Unreadable storage is uncertainty, not "never ran".
      return reply('claimed_no_outcome');
    }
  }

  Map<String, Object?> _result(
    String taskId,
    String state,
    String code, [
    Object? result,
  ]) {
    var carried =
        result is Map && (state == 'completed' || state == 'toolError')
            ? Map<String, Object?>.from(result)
            : null;
    var finalCode = code;
    var finalState = state;
    if (carried != null &&
        utf8.encode(jsonEncode(carried)).length > maxResultBytes) {
      carried = null;
      finalCode = 'result_too_large';
      finalState = 'unknown';
    }
    return {
      'schemaVersion': 1,
      'taskId': taskId,
      'dispatchKey': 'mcp-tool-v1:$taskId',
      'state': finalState,
      'code': finalCode,
      if (carried != null) 'result': carried,
    };
  }
}
