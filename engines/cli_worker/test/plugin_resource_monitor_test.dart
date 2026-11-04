import 'dart:async';
import 'dart:io';

import 'package:syntila_cli_worker_engine/src/plugin_host.dart';
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
