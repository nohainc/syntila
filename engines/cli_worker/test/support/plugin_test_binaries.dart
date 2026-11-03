import 'dart:io';

/// Compiled binaries shared by the plugin process tests. Compiling is slow and
/// CPU-heavy, so it happens once per source change in a cache directory guarded
/// by a cross-process file lock (every test file runs in its own process).
/// `tool/prepare_plugin_test_binaries.dart` builds them up front so the test
/// run itself is not starved of CPU.
class PluginTestBinaries {
  const PluginTestBinaries._({
    required this.engine,
    required this.fixture,
    required this.reference,
  });

  final String engine;
  final String fixture;
  final String reference;

  static PluginTestBinaries? _cached;

  static Future<PluginTestBinaries> ensure() async =>
      _cached ??= await _build();

  static Future<PluginTestBinaries> _build() async {
    final root = Directory.current;
    final cache = Directory('${root.path}/.dart_tool/plugin-test-bin')
      ..createSync(recursive: true);
    final engine = '${cache.path}/engine';
    final fixture = '${cache.path}/plugin_fixture';
    final reference = '${cache.path}/reference_plugin';
    final lock = File('${cache.path}/.lock').openSync(mode: FileMode.write);
    try {
      lock.lockSync(FileLock.blockingExclusive);
      final newestSource = _newestSource(root);
      await _compileIfStale(
        engine,
        'bin/syntila_cli_worker.dart',
        root.path,
        newestSource,
      );
      await _compileIfStale(
        fixture,
        'test/fixtures/plugin_fixture.dart',
        root.path,
        newestSource,
      );
      await _compileIfStale(
        reference,
        'test/fixtures/reference_plugin.dart',
        '${root.path}/../../packages/syntila_plugin_conformance',
        newestSource,
      );
    } finally {
      lock.unlockSync();
      lock.closeSync();
    }
    return PluginTestBinaries._(
      engine: engine,
      fixture: fixture,
      reference: reference,
    );
  }

  static DateTime _newestSource(Directory root) {
    var newest = DateTime.fromMillisecondsSinceEpoch(0);
    for (final path in const [
      'lib',
      'bin',
      'test/fixtures',
      '../../packages/syntila_plugin_protocol/lib',
      '../../packages/syntila_plugin_conformance/lib',
      '../../packages/syntila_plugin_conformance/test/fixtures',
      '../../packages/syntila_worker_protocol/lib',
      '../../packages/syntila_cli_worker_runtime/lib',
    ]) {
      final directory = Directory('${root.path}/$path');
      if (!directory.existsSync()) continue;
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('.dart')) {
          final modified = entity.lastModifiedSync();
          if (modified.isAfter(newest)) newest = modified;
        }
      }
    }
    return newest;
  }

  static Future<void> _compileIfStale(
    String output,
    String source,
    String workingDirectory,
    DateTime newestSource,
  ) async {
    final file = File(output);
    if (file.existsSync() && file.lastModifiedSync().isAfter(newestSource)) {
      return;
    }
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      source,
      '-o',
      output,
    ], workingDirectory: workingDirectory);
    if (result.exitCode != 0) {
      throw StateError(
        'compile $source failed: ${result.stdout}${result.stderr}',
      );
    }
  }
}
