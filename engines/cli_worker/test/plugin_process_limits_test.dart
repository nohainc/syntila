@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:async';
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
    final process = await Process.start(engine, [
      '--plugin-child',
      '--cpu-seconds',
      '1',
      '--open-files',
      '64',
      '--',
      '/usr/bin/python3',
      '-c',
      'while True: pass',
    ]);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    addTearDown(() async {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    });
    final code = await process.exitCode.timeout(const Duration(seconds: 15));
    expect(code, isNot(0));
  }, skip: Platform.isWindows);

  Future<ProcessResult> windowsFixture(String name, {int cpu = 3600}) async {
    final temp = Directory.systemTemp.createTempSync('windows-resource');
    addTearDown(() => temp.deleteSync(recursive: true));
    final binary = '${temp.path}/fixture.exe';
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/fixtures/$name.dart',
      '-o',
      binary,
    ]);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}${compiled.stderr}',
    );
    final process = await Process.start(engine, [
      '--plugin-child',
      '--cpu-seconds',
      '$cpu',
      '--open-files',
      '256',
      '--',
      binary,
    ]);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    addTearDown(() async {
      process.kill(); // Closing the wrapper's job kills its remaining children.
      await process.exitCode;
    });
    final code = await process.exitCode.timeout(const Duration(seconds: 20));
    return ProcessResult(process.pid, code, await output, await errors);
  }

  test('Windows plugin inherits the bounded nested Job Object', () async {
    final result = await windowsFixture('windows_limit_probe');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final limits = jsonDecode(result.stdout as String) as Map;
    expect(limits['memory'], 1024 * 1024 * 1024);
    expect(limits['processes'], 66);
    expect(limits['cpu'], 3600 * 10000000);
    expect((limits['flags'] as int) & 0x220c, 0x220c);
  }, skip: !Platform.isWindows);

  test('Windows handle exhaustion terminates the private plugin job', () async {
    final result = await windowsFixture('windows_handle_leak');
    expect(result.exitCode, 70);
    expect(result.stdout, contains('handles-created'));
    expect(result.stderr, contains('plugin handle count limit exceeded'));
  }, skip: !Platform.isWindows);

  test('Windows job refuses excess committed memory', () async {
    final result = await windowsFixture('windows_memory_limit');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final committed = int.parse(result.stdout.toString().trim());
    expect(committed, greaterThan(0));
    expect(committed, lessThan(1024 * 1024 * 1024));
  }, skip: !Platform.isWindows);

  test('Windows job CPU limit terminates a running target', () async {
    final result = await windowsFixture('windows_cpu_limit', cpu: 1);
    expect(result.stdout, contains('cpu-started'));
    expect(result.exitCode, isNot(0));
  }, skip: !Platform.isWindows);

  test('Windows job refuses excess simultaneous processes', () async {
    final result = await windowsFixture('windows_process_limit');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final started = int.parse(result.stdout.toString().trim());
    expect(started, greaterThan(0));
    expect(started, lessThanOrEqualTo(64));
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
