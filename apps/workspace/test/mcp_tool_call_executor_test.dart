@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:syntila_workspace/cli_worker_engine_supervisor.dart';
import 'package:syntila_workspace/mcp_engine_probe.dart';
import 'package:syntila_workspace/mcp_registry.dart';
import 'package:syntila_workspace/mcp_service.dart';
import 'package:syntila_workspace/mcp_tool_call_executor.dart';
import 'package:syntila_workspace/mcp_tool_call_fence.dart';
import 'package:syntila_workspace/mcp_tool_call_request.dart';
import 'package:test/test.dart';

void main() {
  test('consent, admission and supervised Engine call use the real MCP server',
      () async {
    final root = Directory.systemTemp.createTempSync('mcp-call-executor-');
    addTearDown(() => root.deleteSync(recursive: true));
    final engine = File('../../engines/cli_worker/bin/syntila_cli_worker.dart')
        .absolute
        .path;
    final engineBinary = '${root.path}/engine';
    final compilation = await Process.run(
      Platform.resolvedExecutable,
      ['compile', 'exe', 'bin/syntila_cli_worker.dart', '-o', engineBinary],
      workingDirectory: '../../engines/cli_worker',
    );
    expect(compilation.exitCode, 0,
        reason: '${compilation.stdout}${compilation.stderr}');
    final registry = McpRegistry(File('${root.path}/mcp.json'));
    final service = McpService(
      registry,
      EngineMcpProbe(
        workingDirectory: root,
        locateEngine: () => (
          executable: Platform.resolvedExecutable,
          argumentsPrefix: [engine],
        ),
      ),
    );
    await service.add(
      serverId: 'echo',
      displayName: 'Echo',
      command: Platform.resolvedExecutable,
      arguments: [
        File('../../packages/syntila_mcp_protocol/test/fixtures/echo_server.dart')
            .absolute
            .path,
        'normal',
      ],
    );
    final shown = await service.consent('echo');
    await service.consent('echo', acceptHash: shown['documentHash']! as String);
    service.enable('echo');
    final pin = registry.get('echo')!.toolPins['echo']!;
    final supervisor = CliWorkerEngineSupervisor(
      engineExecutable: engineBinary,
      processRegistryDirectory: Directory('${root.path}/processes'),
    );
    final executor = McpToolCallExecutor(
      service,
      supervisor,
      McpToolCallFence(Directory('${root.path}/fences')),
    );
    Future<Map<String, Object?>> call() => executor.execute(
          assignmentId: 'one',
          request: McpToolCallRequest.fromJson({
            'schemaVersion': 1,
            'taskId': 'task-one',
            'dispatchKey': 'mcp-tool-v1:task-one',
            'serverId': 'echo',
            'tool': 'echo',
            'toolDefinitionHash': pin,
            'arguments': {'text': 'hello'},
            'timeoutMs': 30000,
          }),
          stateDirectory: Directory('${root.path}/state'),
          workingDirectory: root,
          maxConcurrentAssignments: 1,
          authorizeStart: () => true,
        );
    final result = await call();
    expect(result['state'], 'completed', reason: result.toString());
    expect((result['result'] as Map)['content'], isNotEmpty);
    expect((await call())['code'], 'dispatch_already_claimed');
    service.disable('echo');
    expect((await call())['state'], 'rejected');
    expect(supervisor.activeSlotCount, 0);
  });
}
