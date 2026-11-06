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
    final fence = McpToolCallFence(Directory('${root.path}/fences'));
    final executor = McpToolCallExecutor(service, supervisor, fence);
    final handler = McpToolCallHandler(
      fence: fence,
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
    // A repeat of the same logical step is never re-dispatched; the Workspace
    // reports the outcome it durably recorded instead.
    final again = (await handler.handle(payload('t1')))!;
    expect(again['state'], 'completed');
    expect(again['result'], ok['result']);
    expect(
        (await fence.recordedOutcome('mcp-tool-v1:t1'))!['state'], 'completed');
    // A claim with no recorded outcome (a crash before the answer) stays
    // unknown and is not dispatched.
    expect(await fence.claim('mcp-tool-v1:t4'), isTrue);
    final crashed = (await handler.handle(payload('t4')))!;
    expect(crashed['state'], 'unknown');
    expect(crashed['code'], 'dispatch_already_claimed');
    expect(crashed.containsKey('result'), isFalse);
    // Rejection before dispatch does not claim or journal the key.
    expect(await fence.wasClaimed('mcp-tool-v1:t3'), isFalse);
    // Malformed payloads are rejected with a result that Cloud can correlate.
    final bad = (await handler.handle({...payload('t2'), 'extra': 1}))!;
    expect(bad['state'], 'rejected');
    expect(bad['taskId'], 't2');
    expect(await handler.handle({'nothing': true}), isNull);
    // Unconsented tools are rejected before dispatch.
    final unpinned = (await handler
        .handle({...payload('t3'), 'toolDefinitionHash': 'b' * 64}))!;
    expect(unpinned['state'], 'rejected');
    await service.add(
      serverId: 'large',
      displayName: 'Large',
      command: Platform.resolvedExecutable,
      arguments: [
        File('../../packages/syntila_mcp_protocol/test/fixtures/echo_server.dart')
            .absolute
            .path,
        'large',
      ],
    );
    final largeConsent = await service.consent('large');
    await service.consent('large',
        acceptHash: largeConsent['documentHash']! as String);
    service.enable('large');
    final largePin = registry.get('large')!.toolPins['echo']!;
    final largeRequest = {
      ...payload('large-task'),
      'serverId': 'large',
      'toolDefinitionHash': largePin
    };
    final oversized = (await handler.handle(largeRequest))!;
    expect(oversized['state'], 'unknown');
    expect(oversized['code'], 'result_too_large');
    expect(oversized.containsKey('result'), isFalse);
    final duplicate = (await handler.handle(largeRequest))!;
    expect(duplicate['state'], 'unknown');
    expect(duplicate['code'], 'result_too_large');
    expect(duplicate.containsKey('result'), isFalse);
    expect(supervisor.activeSlotCount, 0);
  });
}
