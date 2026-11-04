import 'dart:async';

import 'package:syntila_cli_worker_engine/src/plugin_windows_handles.dart';
import 'package:test/test.dart';

void main() {
  test('observed handle cap stops on a breach exactly once', () async {
    var count = 100;
    var reads = 0;
    final violations = <String>[];
    final stopped = Completer<void>();
    final monitor = PluginHandleMonitor(
      readCount: () {
        reads++;
        return count;
      },
      maxHandles: 256,
      interval: const Duration(milliseconds: 5),
      onViolation: (reason) {
        violations.add(reason);
        stopped.complete();
      },
    )..start();
    addTearDown(monitor.stop);
    while (reads == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(violations, isEmpty);
    count = 257;
    await stopped.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(violations, ['plugin handle count limit exceeded']);
  });

  test('inspection failure stops instead of allowing unbounded use', () async {
    final failure = Completer<String>();
    final monitor = PluginHandleMonitor(
      readCount: () => throw StateError('native call failed'),
      interval: const Duration(milliseconds: 5),
      onViolation: failure.complete,
    )..start();
    addTearDown(monitor.stop);
    expect(
      await failure.future.timeout(const Duration(seconds: 2)),
      'plugin handle usage could not be inspected',
    );
  });

  test('stopping prevents future native queries', () async {
    var queries = 0;
    final monitor = PluginHandleMonitor(
      readCount: () {
        queries++;
        return 0;
      },
      onViolation: (_) => fail('unexpected violation'),
      interval: const Duration(milliseconds: 5),
    )..start();
    monitor.stop();
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(queries, 0);
  });
}
