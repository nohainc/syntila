import 'dart:async';
import 'dart:io';

/// Observed limits, not a kernel sandbox. Short-lived spikes can escape samples.
class ExternalWorkerResourceLimits {
  const ExternalWorkerResourceLimits({
    this.memoryBytes = 1024 * 1024 * 1024,
    this.descendants = 64,
    this.cpuTime = const Duration(hours: 1),
    this.observedProcessLimit = 4096,
    this.dataBytes = 512 * 1024 * 1024,
    this.dataEntries = 100000,
    this.interval = const Duration(seconds: 1),
  });
  final int memoryBytes;
  final int descendants;
  final Duration cpuTime;
  final int observedProcessLimit;
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

class ExternalWorkerResourceMonitor {
  ExternalWorkerResourceMonitor({
    required this.process,
    required this.dataDirectory,
    required this.onViolation,
    this.limits = const ExternalWorkerResourceLimits(),
  });
  final Process process;
  final String dataDirectory;
  final void Function(String reason) onViolation;
  final ExternalWorkerResourceLimits limits;
  Timer? _timer;
  bool _sampling = false;
  bool _stopped = false;
  final _usage = ExternalWorkerProcessUsageTracker();

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
        final result = await Process.run(
          '/bin/ps',
          ['-axo', 'pid=,ppid=,rss=,time=,lstart='],
          environment: const {'LC_ALL': 'C', 'LANG': 'C'},
        ).timeout(const Duration(seconds: 3));
        if (_stopped) return;
        if (result.exitCode != 0) {
          problem = 'plugin process usage could not be inspected';
        } else {
          problem = _usage.inspect(
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

/// Decode BSD mm:ss.hh and Linux [days-]hh:mm:ss CPU time without rounding.
Duration parseProcessCpuTime(String value) {
  final match = RegExp(
    r'^(?:(\d+)-)?(\d+(?::\d+){1,2})(?:\.(\d{1,6}))?$',
  ).firstMatch(value);
  if (match == null) throw const FormatException('invalid process CPU time');
  final days = int.parse(match[1] ?? '0');
  final parts = match[2]!.split(':').map(int.parse).toList();
  if (parts.last >= 60 ||
      (parts.length == 3 && parts[1] >= 60) ||
      (match[1] != null && (parts.length != 3 || parts[0] >= 24))) {
    throw const FormatException('invalid process CPU time');
  }
  final seconds =
      days * 86400 +
      (parts.length == 3
          ? parts[0] * 3600 + parts[1] * 60 + parts[2]
          : parts[0] * 60 + parts[1]);
  return Duration(
    seconds: seconds,
    microseconds: int.parse((match[3] ?? '').padRight(6, '0')),
  );
}

class _ProcessUsage {
  _ProcessUsage(this.parent, this.rss, this.cpu, this.started);
  final int parent;
  final int rss;
  final String? cpu;
  final String? started;
}

Map<int, _ProcessUsage> _processRows(String text) {
  final rows = <int, _ProcessUsage>{};
  final pattern = RegExp(r'^\s*(\d+)\s+(\d+)\s+(\d+)(?:\s+(\S+)\s+(.+))?\s*$');
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) continue;
    final match = pattern.firstMatch(line);
    if (match == null) throw const FormatException('invalid process usage');
    final start = match[5]?.trim().replaceAll(RegExp(r'\s+'), ' ');
    rows[int.parse(match[1]!)] = _ProcessUsage(
      int.parse(match[2]!),
      int.parse(match[3]!) * 1024,
      match[4],
      start,
    );
  }
  return rows;
}

Set<int> _descendantTree(Map<int, _ProcessUsage> rows, int root) {
  if (!rows.containsKey(root)) return {};
  final children = <int, List<int>>{};
  for (final entry in rows.entries) {
    children.putIfAbsent(entry.value.parent, () => []).add(entry.key);
  }
  final included = <int>{root};
  final queue = <int>[root];
  for (var i = 0; i < queue.length; i++) {
    for (final child in children[queue[i]] ?? const <int>[]) {
      if (included.add(child)) queue.add(child);
    }
  }
  return included;
}

String? _treeProblem(
  Map<int, _ProcessUsage> rows,
  Set<int> included,
  ExternalWorkerResourceLimits limits,
) {
  if (included.length - 1 > limits.descendants) {
    return 'plugin descendant limit exceeded';
  }
  final rss = included.fold<int>(0, (sum, id) => sum + rows[id]!.rss);
  if (rss > limits.memoryBytes) return 'plugin memory limit exceeded';
  return null;
}

/// RSS/count checks for a single snapshot (also accepts legacy three-column rows).
String? inspectProcessUsage(
  String text,
  int root,
  ExternalWorkerResourceLimits limits,
) {
  final rows = _processRows(text);
  return _treeProblem(rows, _descendantTree(rows, root), limits);
}

/// Monotonic observed CPU budget across a launch's process tree. Retains each
/// process's high-water value after exit, so sequential children cannot reset it.
/// Identity includes start time to avoid attributing ordinary PID reuse twice.
/// Processes born and reaped between samples remain outside this observed bound.
class ExternalWorkerProcessUsageTracker {
  final _highWater = <(int, String), int>{};
  int _cpuMicroseconds = 0;
  Duration get observedCpuTime => Duration(microseconds: _cpuMicroseconds);

  String? inspect(String text, int root, ExternalWorkerResourceLimits limits) {
    final rows = _processRows(text);
    final included = _descendantTree(rows, root);
    final problem = _treeProblem(rows, included, limits);
    if (problem != null) return problem;
    for (final id in included) {
      final row = rows[id]!;
      if (row.cpu == null || row.started == null || row.started!.isEmpty) {
        throw const FormatException('process CPU identity missing');
      }
      final key = (id, row.started!);
      if (!_highWater.containsKey(key) &&
          _highWater.length >= limits.observedProcessLimit) {
        return 'plugin observed process history limit exceeded';
      }
      final value = parseProcessCpuTime(row.cpu!).inMicroseconds;
      final previous = _highWater[key] ?? 0;
      if (value > previous) {
        _cpuMicroseconds += value - previous;
        _highWater[key] = value;
      } else {
        _highWater.putIfAbsent(key, () => previous);
      }
    }
    if (_cpuMicroseconds >= limits.cpuTime.inMicroseconds) {
      return 'plugin aggregate CPU time limit exceeded';
    }
    return null;
  }
}
