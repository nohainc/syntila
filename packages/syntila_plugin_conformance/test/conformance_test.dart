@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_plugin_conformance/syntila_plugin_conformance.dart';
import 'package:test/test.dart';

late Directory root;
late String plugin;

Future<ConformanceReport> run({
  List<String> arguments = const [],
  bool resume = false,
  Map<String, Object?>? capabilities,
}) {
  final work = Directory.systemTemp.createTempSync('conf-cwd');
  return ConformanceRunner(
    launcher: DirectProcessLauncher(
      executable: plugin,
      arguments: arguments,
      workingDirectory: work.path,
    ),
    expectedPluginId: 'ref-plugin',
    expectedVersion: '1.0.0',
    declaresResume: resume,
    declaredCapabilities: capabilities,
    terminalTimeout: const Duration(seconds: 3),
    caseTimeout: const Duration(seconds: 20),
  ).run();
}

ConformanceCase caseOf(ConformanceReport report, String id) =>
    report.cases.singleWhere((c) => c.id == id);

void main() {
  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('conformance');
    plugin = '${root.path}/reference';
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/fixtures/reference_plugin.dart',
      '-o',
      plugin,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  test('a compliant plugin passes every applicable case', () async {
    final report = await run(capabilities: {'progress': true});
    final failed =
        report.cases.where((c) => c.status == ConformanceStatus.failed);
    expect(failed.map((c) => '${c.id}: ${c.detail}'), isEmpty);
    expect(report.passed, isTrue);
    expect(
        caseOf(report, 'resume.roundtrip').status, ConformanceStatus.skipped);
    expect(report.toJson()['disclaimer'], conformanceDisclaimer);
    expect(report.toJson()['suiteVersion'], conformanceSuiteVersion);
  });

  test('session resume is exercised when declared, across processes', () async {
    final report = await run(
      arguments: ['--resume'],
      resume: true,
      capabilities: {'progress': true, 'sessionResume': true},
    );
    expect(caseOf(report, 'resume.roundtrip').status, ConformanceStatus.passed);
    expect(
      caseOf(report, 'resume.unknown_key_session_not_found').status,
      ConformanceStatus.passed,
    );
    expect(report.passed, isTrue);
  });

  test('declared resume that is not implemented fails the resume cases',
      () async {
    final report = await run(resume: true);
    expect(caseOf(report, 'resume.roundtrip').status, ConformanceStatus.failed);
    expect(report.passed, isFalse);
  });

  final faults = <String, List<String>>{
    'wrong-identity': ['handshake.identity'],
    'two-terminals': ['execute.single_terminal_frame'],
    'late-progress': ['execute.progress_ordering'],
    'noise': ['handshake.identity', 'probe.passive'],
    'no-pong': ['heartbeat.pong'],
    'hang': ['execute.single_terminal_frame', 'cancel.within_grace'],
  };
  faults.forEach((fault, expectedFailures) {
    test('fault "$fault" fails exactly the rules it breaks', () async {
      final report = await run(arguments: ['--fault=$fault']);
      final failed = report.cases
          .where((c) => c.status == ConformanceStatus.failed)
          .map((c) => c.id)
          .toSet();
      expect(failed, containsAll(expectedFailures), reason: '$failed');
      expect(report.passed, isFalse);
    });
  });

  test('a plugin that ignores end of input fails stdin.eof_exits', () async {
    final report = await run(arguments: ['--fault=ignore-eof']);
    expect(caseOf(report, 'stdin.eof_exits').status, ConformanceStatus.failed);
  });

  test('capabilities the manifest never declared are reported', () async {
    final report = await run(capabilities: {'activity': true});
    expect(
      caseOf(report, 'manifest.capabilities_subset').status,
      ConformanceStatus.failed,
    );
  });

  test('the report never presents conformance as a safety rating', () async {
    final report = await run(capabilities: {'progress': true});
    final json = report.toJson();
    expect(json['disclaimer'], contains('not a security rating'));
    expect(sha256.convert(plugin.codeUnits).toString(), isNotEmpty);
  });
}
