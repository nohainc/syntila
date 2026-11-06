import 'dart:async';

import 'package:syntila_cli_worker_engine/src/mcp_host.dart';
import 'package:syntila_cli_worker_engine/src/mcp_tool_call_runner.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:test/test.dart';

import 'support/fake_mcp_http.dart';

void main() {
  late FakeMcpHttp fake;
  late McpHost host;
  late McpToolCallRunner runner;

  McpServerSpec spec([ToolPins? pins]) => McpServerSpec(
    serverId: 'remote',
    workspaceId: 'workspace',
    pins: pins,
    remote: McpRemote(endpoint: fake.endpoint, allowInsecureLoopback: true),
  );

  Future<ToolPins> consent() async {
    final lease = await host.acquire(spec());
    final pins = ToolPins.fromTools(lease.tools);
    lease.release();
    return pins;
  }

  int calls() =>
      fake.seen.where((s) => s.body?['method'] == 'tools/call').length;

  setUp(() async {
    fake = FakeMcpHttp();
    await fake.start();
    host = McpHost();
    runner = McpToolCallRunner(host);
  });

  tearDown(() async {
    await host.closeAll();
    await fake.stop();
  });

  test(
    'calls a consented tool exactly once and preserves its result',
    () async {
      final result = await runner.call(spec(await consent()), 'echo', {
        'text': 'hello',
      }, timeout: const Duration(seconds: 5));
      expect(result.state, McpToolCallState.completed);
      expect((result.result!['content'] as List).first['text'], 'json: hello');
      expect(calls(), 1);
    },
  );

  test('refuses an unconsented call before contacting the server', () async {
    final result = await runner.call(
      spec(),
      'echo',
      {},
      timeout: const Duration(seconds: 5),
    );
    expect(result.state, McpToolCallState.rejected);
    expect(fake.seen, isEmpty);
  });

  test('refuses a changed tool without calling it', () async {
    final pins = await consent();
    fake.toolDescription = 'changed';
    final result = await runner.call(
      spec(pins),
      'echo',
      {},
      timeout: const Duration(seconds: 5),
    );
    expect(result.state, McpToolCallState.rejected);
    expect(result.code, 'definition_changed');
    expect(calls(), 0);
  });

  test('refuses output schemas before any side effect', () async {
    fake.outputSchema = true;
    final result = await runner.call(
      spec(await consent()),
      'echo',
      {},
      timeout: const Duration(seconds: 5),
    );
    expect(result.code, 'output_schema_unsupported');
    expect(calls(), 0);
  });

  test('distinguishes an MCP tool error from success', () async {
    final pins = await consent();
    fake.toolError = true;
    final result = await runner.call(
      spec(pins),
      'echo',
      {},
      timeout: const Duration(seconds: 5),
    );
    expect(result.state, McpToolCallState.toolError);
    expect(calls(), 1);
  });

  test('a malformed response is not reported as success', () async {
    final pins = await consent();
    fake.malformedResult = true;
    final result = await runner.call(
      spec(pins),
      'echo',
      {},
      timeout: const Duration(seconds: 5),
    );
    expect(result.state, McpToolCallState.unknown);
    expect(result.code, 'invalid_response');
    expect(calls(), 1);
  });

  test('reports an ambiguous failure without replaying the call', () async {
    final pins = await consent();
    fake.failCalls = true;
    final result = await runner.call(
      spec(pins),
      'echo',
      {},
      timeout: const Duration(seconds: 5),
    );
    expect(result.state, McpToolCallState.unknown);
    expect(calls(), 1);
    expect(host.warmSessions, 0);
  });

  test('cancellation before dispatch does not contact the server', () async {
    final result = await runner.call(
      spec(ToolPins({'echo': 'a' * 64})),
      'echo',
      {},
      timeout: const Duration(seconds: 5),
      cancel: Future<void>.value(),
    );
    expect(result.state, McpToolCallState.rejected);
    expect(result.code, 'cancelled_before_dispatch');
    expect(fake.seen, isEmpty);
  });

  test('cancellation after dispatch has an unknown outcome', () async {
    final pins = await consent();
    final cancel = Completer<void>();
    final gate = fake.callGate = Completer<void>();
    final pending = runner.call(
      spec(pins),
      'echo',
      {},
      timeout: const Duration(seconds: 5),
      cancel: cancel.future,
    );
    for (var i = 0; i < 100 && calls() == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(calls(), 1);
    cancel.complete();
    final result = await pending;
    expect(result.state, McpToolCallState.unknown);
    expect(result.code, 'cancelled_after_dispatch');
    expect(calls(), 1);
    expect(host.warmSessions, 0);
    gate.complete();
  });

  test('timeout during connection never dispatches a late call', () async {
    final pins = await consent();
    await host.closeAll();
    final gate = fake.listGate = Completer<void>();
    final result = await runner.call(
      spec(pins),
      'echo',
      {},
      timeout: const Duration(milliseconds: 150),
    );
    expect(result.code, 'timeout_before_dispatch');
    expect(calls(), 0);
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(calls(), 0);
    expect(host.warmSessions, 0);
  });

  test('timeout during tool refresh refuses dispatch after refresh', () async {
    final pins = await consent();
    final gate = fake.listGate = Completer<void>();
    final pending = runner.call(
      spec(pins),
      'echo',
      {},
      timeout: const Duration(milliseconds: 100),
    );
    await Future<void>.delayed(const Duration(milliseconds: 180));
    gate.complete();
    final result = await pending;
    expect(result.state, McpToolCallState.rejected);
    expect(calls(), 0);
  });

  test('the dispatch timeout excludes time spent refreshing tools', () async {
    final pins = await consent();
    final listGate = fake.listGate = Completer<void>();
    final callGate = fake.callGate = Completer<void>();
    final pending = runner.call(
      spec(pins),
      'echo',
      {},
      timeout: const Duration(milliseconds: 600),
    );
    await Future<void>.delayed(const Duration(milliseconds: 350));
    listGate.complete();
    final result = await pending.timeout(const Duration(milliseconds: 450));
    expect(result.state, McpToolCallState.unknown);
    expect(calls(), 1);
    callGate.complete();
  });
}
