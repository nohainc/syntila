@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:syntila_plugin_conformance/syntila_plugin_conformance.dart';
import 'package:test/test.dart';

late Directory root;
late String worker;

Future<ConformanceReport> run(List<String> arguments) => McpConformanceRunner(
      launcher: DirectProcessLauncher(
        executable: worker,
        arguments: arguments,
      ),
      caseTimeout: const Duration(seconds: 15),
    ).run();

ConformanceCase caseOf(ConformanceReport report, String id) =>
    report.cases.singleWhere((c) => c.id == id);

void main() {
  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('mcp-conformance');
    worker = '${root.path}/echo-worker';
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '../../examples/mcp/echo_worker/echo_worker.dart',
      '-o',
      worker,
    ]);
    expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
  });

  tearDownAll(() => root.deleteSync(recursive: true));

  test('the reference MCP Worker passes every case', () async {
    final report = await run(const []);
    expect(
      [
        for (final c in report.cases)
          if (c.status != ConformanceStatus.passed) '${c.id}: ${c.detail}'
      ],
      isEmpty,
    );
    expect(report.passed, isTrue);
  });

  test('a malformed probe state fails only the probe case', () async {
    final report = await run(const ['badprobe']);
    expect(caseOf(report, 'mcp.probe_shape').status, ConformanceStatus.failed);
    expect(
        caseOf(report, 'mcp.advertisement').status, ConformanceStatus.passed);
  });

  test('a malformed probe check fails the probe case', () async {
    final report = await run(const ['badcheck']);
    expect(caseOf(report, 'mcp.probe_shape').status, ConformanceStatus.failed);
  });

  test('a server without syntila.execute fails the tools case', () async {
    final report = await run(const ['noexecute']);
    expect(
        caseOf(report, 'mcp.tools_present').status, ConformanceStatus.failed);
  });
  test('malformed sessions and unsafe Windows paths fail execute validation',
      () async {
    for (final mode in ['badsession', 'badartifact']) {
      final report = await run([mode]);
      final result = caseOf(report, 'mcp.execute_result');
      expect(result.status, ConformanceStatus.failed, reason: mode);
      expect(result.detail, isNot(contains('could not be exercised')));
    }
  });
  test('rejects invalid schemas and duplicate tool names', () async {
    for (final mode in ['badschema', 'duplicate_tool']) {
      final result = caseOf(await run([mode]), 'mcp.tool_definitions');
      expect(result.status, ConformanceStatus.failed, reason: mode);
    }
  });
  test('unsupported server version fails negotiation', () async {
    final report = await run(const ['badversion']);
    expect(caseOf(report, 'mcp.version_negotiation').status,
        ConformanceStatus.failed);
  });
  test('echoing an unknown version fails fallback negotiation', () async {
    final report = await run(const ['echo_version']);
    expect(caseOf(report, 'mcp.version_fallback').status,
        ConformanceStatus.failed);
    expect(caseOf(report, 'mcp.version_negotiation').status,
        ConformanceStatus.passed);
  });
  test('execute output is bounded by UTF-8 bytes', () async {
    final atLimit =
        caseOf(await run(['output_at_limit']), 'mcp.execute_result');
    expect(atLimit.status, ConformanceStatus.passed);
    final overLimit =
        caseOf(await run(['output_over_limit']), 'mcp.execute_result');
    expect(overLimit.status, ConformanceStatus.failed);
    expect(overLimit.detail, contains('UTF-8 byte limit'));
  });
}
