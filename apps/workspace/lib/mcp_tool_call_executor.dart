import 'dart:async';
import 'dart:io';

import 'cli_worker_engine_supervisor.dart';
import 'mcp_service.dart';
import 'mcp_tool_call_fence.dart';
import 'mcp_tool_call_request.dart';

/// Internal execution primitive, not an assignment endpoint. The caller must
/// authorize the assignment and supply a stable logical-step dispatch key.
class McpToolCallExecutor {
  McpToolCallExecutor(this._service, this._supervisor, this._fence);

  final McpService _service;
  final CliWorkerEngineSupervisor _supervisor;
  final McpToolCallFence _fence;

  Future<Map<String, Object?>> execute({
    required String assignmentId,
    required McpToolCallRequest request,
    required Directory stateDirectory,
    required Directory workingDirectory,
    required int maxConcurrentAssignments,
    required FutureOr<bool> Function() authorizeStart,
  }) =>
      _supervisor.executeMcpToolCall(
        assignmentId: assignmentId,
        stateDirectory: stateDirectory,
        workingDirectory: workingDirectory,
        maxConcurrentAssignments: maxConcurrentAssignments,
        timeout: Duration(milliseconds: request.timeoutMs),
        authorizeStart: authorizeStart,
        claimDispatch: () => _fence.claim(request.dispatchKey),
        // Resolve after acquiring the shared slot, not before a potentially
        // long queue wait. No secrets leave the Service except on Engine stdin.
        prepareRequest: () async {
          final admission = await _service.admitToolCall(
            serverId: request.serverId,
            tool: request.tool,
            expectedToolHash: request.toolDefinitionHash,
          );
          final remote = admission.remote;
          return {
            'tool': request.tool,
            'toolPins': {request.tool: admission.toolHash},
            'arguments': request.arguments,
            'timeoutMs': request.timeoutMs,
            if (remote != null)
              'remote': {
                'endpoint': remote.endpoint.toString(),
                if (remote.bearerToken != null)
                  'bearerToken': remote.bearerToken,
                if (remote.insecureLoopback) 'allowInsecureLoopback': true,
              }
            else ...{
              'server': admission.launch!.toJson(),
              'commandSha256': admission.commandSha256,
              'workingDirectory': workingDirectory.absolute.path,
            },
          };
        },
      );
}
