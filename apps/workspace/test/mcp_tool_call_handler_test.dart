@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:syntila_workspace/cli_worker_engine_supervisor.dart';
import 'package:syntila_workspace/mcp_engine_probe.dart';
import 'package:syntila_workspace/mcp_registry.dart';
import 'package:syntila_workspace/mcp_service.dart';
import 'package:syntila_workspace/mcp_tool_call_executor.dart';
import 'package:syntila_workspace/mcp_tool_call_handler.dart';
import 'package:syntila_workspace/mcp_tool_call_fence.dart';
import 'package:test/test.dart';

void main() {
  test('handler maps Cloud payloads to bounded result payloads', () async {
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
    final handler = McpToolCallHandler(
      executor: executor,
      stateDirectory: Directory('${root.path}/state'),
      workingDirectory: root,
      maxConcurrentAssignments: 1,
    );
    Map<String, Object?> payload(String task) => {
          'schemaVersion': 1,
          'taskId': task,
          'dispatchKey': 'mcp-tool-v1:$task',
          'serverId': 'echo',
          'tool': 'echo',
          'toolDefinitionHash': pin,
          'arguments': {'text': 'hello'},
          'timeoutMs': 30000,
        };
    final ok = (await handler.handle(payload('t1')))!;
    expect(ok['state'], 'completed', reason: ok.toString());
    expect(ok['dispatchKey'], 'mcp-tool-v1:t1');
    expect((ok['result'] as Map)['content'], isNotEmpty);
    // A repeat of the same logical step is never re-dispatched.
    final again = (await handler.handle(payload('t1')))!;
    expect(again['state'], 'unknown');
    expect(again['code'], 'dispatch_already_claimed');
    // Malformed payloads are rejected with a result that Cloud can correlate.
    final bad = (await handler.handle({...payload('t2'), 'extra': 1}))!;
    expect(bad['state'], 'rejected');
    expect(bad['taskId'], 't2');
    expect(await handler.handle({'nothing': true}), isNull);
    // Unconsented tools are rejected before dispatch.
    final unpinned = (await handler
        .handle({...payload('t3'), 'toolDefinitionHash': 'b' * 64}))!;
    expect(unpinned['state'], 'rejected');
    expect(supervisor.activeSlotCount, 0);
  });
}
