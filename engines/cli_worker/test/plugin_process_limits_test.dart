@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'support/plugin_test_binaries.dart';

void main() {
  late String engine;
  Directory? windowsBuild;
  setUpAll(() async {
    if (!Platform.isWindows) {
      engine = (await PluginTestBinaries.ensure()).engine;
      return;
    }
    windowsBuild = Directory.systemTemp.createTempSync('limited-engine');
    engine = '${windowsBuild!.path}/engine.exe';
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/syntila_cli_worker.dart',
      '-o',
      engine,
    ]);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}${compiled.stderr}',
    );
  });
  tearDownAll(() => windowsBuild?.deleteSync(recursive: true));

  Future<ProcessResult> run(String script, {int cpu = 3600}) =>
      Process.run(engine, [
        '--plugin-child',
        '--cpu-seconds',
        '$cpu',
        '--open-files',
        '64',
        '--',
        '/usr/bin/python3',
        '-c',
        script,
      ]);

  test('hard limits are in place before the plugin executes', () async {
    final result = await run('''
import resource, json
print(json.dumps([resource.getrlimit(resource.RLIMIT_CPU),
 resource.getrlimit(resource.RLIMIT_NOFILE), resource.getrlimit(resource.RLIMIT_CORE)]))
''');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final values = jsonDecode(result.stdout as String) as List;
    expect(values[0], [3600, 3600]);
    expect(values[1], [64, 64]);
    expect(values[2], [0, 0]);
  }, skip: Platform.isWindows);

  test('open-file hard limit refuses new handles', () async {
    final result = await run('''
import os
files=[]
try:
 while True: files.append(os.open('/dev/null', os.O_RDONLY))
except OSError:
 print(len(files))
''');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(int.parse(result.stdout.toString().trim()), lessThan(64));
  }, skip: Platform.isWindows);

  test('CPU hard limit kills a busy plugin', () async {
    final result = await run(
      'while True: pass',
      cpu: 1,
    ).timeout(const Duration(seconds: 15));
    expect(result.exitCode, isNot(0));
  }, skip: Platform.isWindows);

  test('Windows plugin inherits the bounded nested Job Object', () async {
    final temp = Directory.systemTemp.createTempSync('windows-limit-probe');
    addTearDown(() => temp.deleteSync(recursive: true));
    final binary = '${temp.path}/probe.exe';
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/fixtures/windows_limit_probe.dart',
      '-o',
      binary,
    ]);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}${compiled.stderr}',
    );
    final result = await Process.run(engine, [
      '--plugin-child',
      '--cpu-seconds',
      '3600',
      '--open-files',
      '256',
      '--',
      binary,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final limits = jsonDecode(result.stdout as String) as Map;
    expect(limits['memory'], 1024 * 1024 * 1024);
    expect(limits['processes'], 66);
    expect(limits['cpu'], 3600 * 10000000);
    expect((limits['flags'] as int) & 0x220c, 0x220c);
  }, skip: !Platform.isWindows);

  test('Windows handle exhaustion terminates the private plugin job', () async {
    final temp = Directory.systemTemp.createTempSync('windows-handles');
    addTearDown(() => temp.deleteSync(recursive: true));
    final binary = '${temp.path}/leak.exe';
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/fixtures/windows_handle_leak.dart',
      '-o',
      binary,
    ]);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}${compiled.stderr}',
    );
    final result = await Process.run(engine, [
      '--plugin-child',
      '--cpu-seconds',
      '3600',
      '--open-files',
      '256',
      '--',
      binary,
    ]).timeout(const Duration(seconds: 20));
    expect(result.exitCode, 70);
    expect(result.stdout, contains('handles-created'));
    expect(result.stderr, contains('plugin handle count limit exceeded'));
  }, skip: !Platform.isWindows);

  test('invalid limits fail before executing the target', () async {
    final result = await Process.run(engine, [
      '--plugin-child',
      '--cpu-seconds',
      '0',
      '--open-files',
      '256',
      '--',
      '/usr/bin/python3',
      '-c',
      'print("UNSAFE")',
    ]);
    expect(result.exitCode, 64);
    expect(result.stdout, isNot(contains('UNSAFE')));
  });
}
