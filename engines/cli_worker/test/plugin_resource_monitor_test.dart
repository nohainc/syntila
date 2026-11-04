import 'dart:async';
import 'dart:io';

import 'package:syntila_cli_worker_engine/src/plugin_host.dart';
import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_cli_worker_engine/src/plugin_resource_monitor.dart';
import 'package:test/test.dart';

void main() {
  test('process limits count only the descendant tree and sum RSS', () {
    const rows = '1 0 1000\n2 1 2000\n3 2 3000\n4 0 999999\n';
    expect(
      inspectProcessUsage(
        rows,
        1,
        const PluginResourceLimits(memoryBytes: 6000 * 1024),
      ),
      isNull,
    );
    expect(
      inspectProcessUsage(
        rows,
        1,
        const PluginResourceLimits(memoryBytes: 5999 * 1024),
      ),
      contains('memory'),
    );
    expect(
      inspectProcessUsage(rows, 1, const PluginResourceLimits(descendants: 1)),
      contains('descendant'),
    );
    expect(
      inspectProcessUsage(rows, 5, const PluginResourceLimits(memoryBytes: 1)),
      isNull,
    );
  });

  test(
    'data quota rejects size and entry count without following links',
    () async {
      final root = Directory.systemTemp.createTempSync('plugin-quota');
      final outside = Directory.systemTemp.createTempSync('outside-quota');
      addTearDown(() {
        root.deleteSync(recursive: true);
        outside.deleteSync(recursive: true);
      });
      File('${root.path}/data').writeAsStringSync('12345');
      File('${outside.path}/large').writeAsStringSync('x' * 1000);
      if (!Platform.isWindows)
        await Link('${root.path}/external').create(outside.path);
      expect(
        await const PluginResourceLimits(
          dataBytes: 5,
        ).checkDataDirectory(root.path),
        isNull,
      );
      expect(
        await const PluginResourceLimits(
          dataBytes: 4,
        ).checkDataDirectory(root.path),
        contains('size'),
      );
      expect(
        await const PluginResourceLimits(
          dataEntries: 0,
        ).checkDataDirectory(root.path),
        contains('entry'),
      );
    },
  );

  test('host refuses over-quota data before starting an executable', () async {
    final root = Directory.systemTemp.createTempSync('plugin-preflight');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/not-executable')..writeAsStringSync('x');
    final host = PluginHost(
      resourceLimits: const PluginResourceLimits(dataBytes: 0),
    );
    final launch = PluginLaunch(
      executable: file.path,
      arguments: const [],
      artifactSha256: await host.sha256OfFile(file.path),
      pluginId: 'quota',
      version: '1.0.0',
      dataDirectory: root.path,
      workingDirectory: root.path,
      environment: const {},
      hostVersion: '1.4.0',
    );
    final result = await host.run(
      launch,
      const PluginRunRequest(
        executeId: 'quota',
        prompt: '',
        access: 'read_write',
        deadline: Duration(seconds: 1),
      ),
    );
    expect((result as PluginRunFailure).code, 'plugin_resource_limit');
    await expectLater(
      host.connect(launch),
      throwsA(
        isA<PluginLaunchException>().having(
          (e) => e.code,
          'code',
          'plugin_resource_limit',
        ),
      ),
    );
  });

  test('parses BSD and Linux CPU times without losing precision', () {
    expect(parseProcessCpuTime('0:01.25'), const Duration(milliseconds: 1250));
    expect(
      parseProcessCpuTime('337:08.76'),
      const Duration(seconds: 20228, milliseconds: 760),
    );
    expect(parseProcessCpuTime('01:02:03'), const Duration(seconds: 3723));
    expect(parseProcessCpuTime('2-03:04:05'), const Duration(seconds: 183845));
    for (final value in [
      'garbage',
      '-0:00',
      '0:60',
      '01:60:00',
      '1-24:00:00',
      '1:2:3.1234567',
    ]) {
      expect(
        () => parseProcessCpuTime(value),
        throwsFormatException,
        reason: value,
      );
    }
  });

  test('aggregate CPU exceeds the budget while each member stays below it', () {
    final tracker = PluginProcessUsageTracker();
    const limits = PluginResourceLimits(cpuTime: Duration(seconds: 5));
    expect(
      tracker.inspect(
        '10 1 100 0:01.00 root-start\n'
        '11 10 100 0:02.00 child-a\n12 10 100 0:03.00 child-b\n'
        '99 1 100 999:00.00 unrelated\n',
        10,
        limits,
      ),
      contains('aggregate CPU'),
    );
    expect(tracker.observedCpuTime, const Duration(seconds: 6));
  });

  test('CPU is monotonic across snapshots and retained after child exit', () {
    final tracker = PluginProcessUsageTracker();
    const limits = PluginResourceLimits(cpuTime: Duration(seconds: 4));
    const first = '10 1 10 0:00.10 root\n11 10 10 0:02.00 child-a\n';
    expect(tracker.inspect(first, 10, limits), isNull);
    expect(tracker.inspect(first, 10, limits), isNull);
    expect(tracker.observedCpuTime, const Duration(milliseconds: 2100));
    expect(
      tracker.inspect(
        '10 1 10 0:00.10 root\n11 10 10 0:01.00 child-a\n',
        10,
        limits,
      ),
      isNull,
    );
    expect(tracker.observedCpuTime, const Duration(milliseconds: 2100));
    expect(
      tracker.inspect(
        '10 1 10 0:00.20 root\n12 10 10 0:02.00 child-b\n',
        10,
        limits,
      ),
      contains('aggregate CPU'),
    );
    expect(tracker.observedCpuTime, const Duration(milliseconds: 4200));
  });

  test('PID reuse with a new start identity is counted as a new process', () {
    final tracker = PluginProcessUsageTracker();
    const limits = PluginResourceLimits();
    tracker.inspect(
      '10 1 10 0:00.00 root\n11 10 10 0:02.00 old-start\n',
      10,
      limits,
    );
    tracker.inspect(
      '10 1 10 0:00.00 root\n11 10 10 0:01.00 new-start\n',
      10,
      limits,
    );
    expect(tracker.observedCpuTime, const Duration(seconds: 3));
  });

  test('bounded history and missing CPU metadata fail closed', () {
    final tracker = PluginProcessUsageTracker();
    expect(
      tracker.inspect(
        '10 1 10 0:00.00 root\n11 10 10 0:00.00 child\n',
        10,
        const PluginResourceLimits(observedProcessLimit: 1),
      ),
      contains('history'),
    );
    expect(
      () => PluginProcessUsageTracker().inspect(
        '10 1 10\n',
        10,
        const PluginResourceLimits(),
      ),
      throwsFormatException,
    );
    expect(
      () => PluginProcessUsageTracker().inspect(
        '10 1 10 invalid root\n',
        10,
        const PluginResourceLimits(),
      ),
      throwsFormatException,
    );
  });

  test(
    'aggregate CPU breach terminates a real multi-process plugin tree',
    () async {
      final root = Directory.systemTemp.createTempSync('plugin-cpu');
      const supervisor = StandardProcessSupervisor();
      final process = await supervisor.startIsolatedProcess('/usr/bin/python3', [
        '-c',
        "import subprocess, sys, time\n"
            "worker = 'import time; end=time.process_time()+1.2\\nwhile time.process_time()<end: pass\\ntime.sleep(30)'\n"
            "children=[subprocess.Popen([sys.executable, '-c', worker]) for _ in range(2)]\n"
            "time.sleep(30)\n",
      ]);
      final violation = Completer<String>();
      final monitor = PluginResourceMonitor(
        process: process,
        dataDirectory: root.path,
        limits: const PluginResourceLimits(
          cpuTime: Duration(milliseconds: 1500),
          interval: Duration(milliseconds: 50),
        ),
        onViolation: (reason) => unawaited(
          supervisor
              .terminateProcessTree(process, force: true)
              .then((_) => violation.complete(reason)),
        ),
      )..start();
      addTearDown(() async {
        monitor.stop();
        await supervisor.terminateProcessTree(process, force: true);
        await process.exitCode;
        root.deleteSync(recursive: true);
      });
      expect(
        await violation.future.timeout(const Duration(seconds: 45)),
        contains('aggregate CPU'),
      );
      expect(await process.exitCode, isNot(0));
    },
    skip: Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('observed memory breach terminates a real process', () async {
    final root = Directory.systemTemp.createTempSync('plugin-monitor');
    final process = await Process.start('/usr/bin/python3', [
      '-c',
      'import time; memory=bytearray(32*1024*1024); time.sleep(30)',
    ]);
    final violation = Completer<String>();
    final monitor = PluginResourceMonitor(
      process: process,
      dataDirectory: root.path,
      limits: const PluginResourceLimits(
        memoryBytes: 16 * 1024 * 1024,
        interval: Duration(milliseconds: 50),
      ),
      onViolation: (reason) {
        process.kill(ProcessSignal.sigkill);
        violation.complete(reason);
      },
    )..start();
    addTearDown(() async {
      monitor.stop();
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      root.deleteSync(recursive: true);
    });
    expect(
      await violation.future.timeout(const Duration(seconds: 10)),
      contains('memory'),
    );
    expect(await process.exitCode, isNot(0));
  }, skip: Platform.isWindows);
}
