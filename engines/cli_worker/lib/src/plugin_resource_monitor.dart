import 'dart:async';
import 'dart:io';

/// Observed limits, not a kernel sandbox. Short-lived spikes can escape samples.
class PluginResourceLimits {
  const PluginResourceLimits({
    this.memoryBytes = 1024 * 1024 * 1024,
    this.descendants = 64,
    this.dataBytes = 512 * 1024 * 1024,
    this.dataEntries = 100000,
    this.interval = const Duration(seconds: 1),
  });
  final int memoryBytes;
  final int descendants;
  final int dataBytes;
  final int dataEntries;
  final Duration interval;

  /// No symlink traversal: the quota covers this directory's owned contents.
  Future<String?> checkDataDirectory(String path) async {
    var bytes = 0;
    var entries = 0;
    final directory = Directory(path);
    try {
      if (!await directory.exists()) return null;
      await for (final entry in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (++entries > dataEntries) return 'plugin data entry limit exceeded';
        if (entry is File) {
          try {
            bytes += await entry.length();
          } on FileSystemException {
            // Concurrent deletion is normal; unreadable remaining files are not.
            if (await entry.exists()) rethrow;
          }
          if (bytes > dataBytes) return 'plugin data size limit exceeded';
        }
      }
      return null;
    } on FileSystemException {
      return 'plugin data usage could not be inspected';
    }
  }
}

class PluginResourceMonitor {
  PluginResourceMonitor({
    required this.process,
    required this.dataDirectory,
    required this.onViolation,
    this.limits = const PluginResourceLimits(),
  });
  final Process process;
  final String dataDirectory;
  final void Function(String reason) onViolation;
  final PluginResourceLimits limits;
  Timer? _timer;
  bool _sampling = false;
  bool _stopped = false;

  void start() {
    _timer = Timer.periodic(limits.interval, (_) => unawaited(_sample()));
    unawaited(process.exitCode.then((_) => stop()));
    unawaited(_sample());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
  }

  Future<void> _sample() async {
    if (_stopped || _sampling) return;
    _sampling = true;
    try {
      String? problem;
      if (Platform.isMacOS || Platform.isLinux) {
        final result = await Process.run('/bin/ps', [
          '-axo',
          'pid=,ppid=,rss=',
        ]).timeout(const Duration(seconds: 3));
        if (_stopped) return;
        if (result.exitCode != 0) {
          problem = 'plugin process usage could not be inspected';
        } else {
          problem = inspectProcessUsage(
            result.stdout.toString(),
            process.pid,
            limits,
          );
        }
      }
      problem ??= await limits.checkDataDirectory(dataDirectory);
      if (!_stopped && problem != null) {
        stop();
        onViolation(problem);
      }
    } on Object {
      if (!_stopped) {
        stop();
        onViolation('plugin resource usage could not be inspected');
      }
    } finally {
      _sampling = false;
    }
  }
}

/// Sum RSS for the current descendant tree, not unrelated user processes.
String? inspectProcessUsage(
  String text,
  int root,
  PluginResourceLimits limits,
) {
  final rows = <int, (int, int)>{};
  for (final line in text.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length != 3) continue;
    final values = parts.map(int.tryParse).toList();
    if (values.any((v) => v == null || v < 0)) continue;
    rows[values[0]!] = (values[1]!, values[2]! * 1024);
  }
  // Exited between ps and the sample; exit supervision owns that outcome.
  if (!rows.containsKey(root)) return null;
  final included = <int>{root};
  var changed = true;
  while (changed) {
    changed = false;
    for (final row in rows.entries) {
      if (included.contains(row.value.$1) && included.add(row.key))
        changed = true;
    }
  }
  if (included.length - 1 > limits.descendants)
    return 'plugin descendant limit exceeded';
  final rss = included.fold<int>(0, (sum, id) => sum + rows[id]!.$2);
  if (rss > limits.memoryBytes) return 'plugin memory limit exceeded';
  return null;
}
