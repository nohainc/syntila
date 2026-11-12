import 'dart:async';
import 'dart:io';

/// Process-wide monotonic clock. Readings are comparable only within one
/// Service process; they are never compared with Cloud timestamps.
final Stopwatch _processClock = Stopwatch()..start();

/// Identifies the process epoch behind monotonic readings. Never compare
/// monotonic timestamps from different epochs after merging diagnostic files.
final String _traceEpochId =
    'trace-${DateTime.now().toUtc().microsecondsSinceEpoch}-$pid';

String processTraceEpochId() => _traceEpochId;

/// Milliseconds since this Service process loaded the tracing library.
int processMonotonicMs() => _processClock.elapsedMilliseconds;

/// Safety clock for startup permits, independent of telemetry wall offsets.
/// A server timestamp was generated somewhere inside the measured round trip;
/// adding the entire trip gives a conservative upper bound at receipt.
final class MonotonicCloudClock {
  MonotonicCloudClock({Duration Function()? monotonicNow})
      : _monotonicNow = monotonicNow ?? (() => _processClock.elapsed);

  // Two normal heartbeat intervals. Older samples cannot authorize launch.
  static const maxSampleAge = Duration(seconds: 30);
  final Duration Function() _monotonicNow;
  DateTime? _serverUpperBound;
  Duration? _receivedAt;

  void addSample(
      {required DateTime serverTimeUtc, required Duration roundTrip}) {
    if (roundTrip.isNegative || roundTrip >= maxSampleAge) {
      reset();
      return;
    }
    _receivedAt = _monotonicNow();
    _serverUpperBound = serverTimeUtc.toUtc().add(roundTrip);
  }

  DateTime? get latestServerTime {
    final received = _receivedAt;
    final upper = _serverUpperBound;
    if (received == null || upper == null) return null;
    final age = _monotonicNow() - received;
    if (age.isNegative || age >= maxSampleAge) {
      reset();
      return null;
    }
    // Cover sub-millisecond precision lost when Cloud serializes timestamps.
    return upper.add(age).add(const Duration(milliseconds: 1));
  }

  /// Age of the current sample, or null when there is none.
  Duration? get sampleAge {
    final received = _receivedAt;
    if (received == null) return null;
    final age = _monotonicNow() - received;
    return age.isNegative ? null : age;
  }

  void reset() {
    _serverUpperBound = null;
    _receivedAt = null;
  }
}

/// Estimates `Cloud clock - local clock` from request/response samples, in the
/// style of NTP: the Cloud timestamp is assumed to lie at the midpoint of the
/// measured round trip, so the error is bounded by half the round-trip time.
///
/// The sample with the smallest round trip in a short window is used because
/// it has the tightest error bound and is least affected by queueing delay.
final class ClockOffsetEstimator {
  ClockOffsetEstimator({this.window = 8}) {
    if (window < 1) {
      throw ArgumentError.value(window, 'window', 'must be positive');
    }
  }

  final int window;
  final List<_ClockSample> _samples = [];

  /// [sentAtUtc] is the local wall-clock time the request was sent,
  /// [roundTrip] is measured with a monotonic timer, and [serverTimeUtc] is
  /// the Cloud timestamp carried by the response.
  void addSample({
    required DateTime sentAtUtc,
    required Duration roundTrip,
    required DateTime serverTimeUtc,
  }) {
    if (roundTrip.isNegative) return;
    final midpoint = sentAtUtc.add(
      Duration(microseconds: roundTrip.inMicroseconds ~/ 2),
    );
    _samples.add(_ClockSample(
      offset: serverTimeUtc.difference(midpoint),
      roundTrip: roundTrip,
    ));
    if (_samples.length > window) _samples.removeAt(0);
  }

  bool get hasEstimate => _samples.isNotEmpty;

  _ClockSample? get _best {
    if (_samples.isEmpty) return null;
    var best = _samples.first;
    for (final sample in _samples.skip(1)) {
      if (sample.roundTrip < best.roundTrip) best = sample;
    }
    return best;
  }

  /// Estimated `Cloud - local` offset in milliseconds, or null before the
  /// first sample.
  int? get offsetMs {
    final best = _best;
    return best == null ? null : (best.offset.inMicroseconds / 1000).round();
  }

  /// Round trip of the sample behind [offsetMs].
  int? get roundTripMs {
    final best = _best;
    return best == null ? null : (best.roundTrip.inMicroseconds / 1000).round();
  }

  void reset() => _samples.clear();
}

final class _ClockSample {
  const _ClockSample({required this.offset, required this.roundTrip});

  final Duration offset;
  final Duration roundTrip;
}

/// Fixed-bucket latency histogram. Memory is constant regardless of sample
/// count and only numeric durations are retained, so it is privacy-safe by
/// construction. Percentiles are reported as the upper bound of the bucket
/// holding the requested rank, clamped to the observed maximum.
final class LatencyHistogram {
  LatencyHistogram();

  static const List<int> bucketUpperBoundsMs = [
    1,
    2,
    5,
    10,
    20,
    50,
    100,
    200,
    500,
    1000,
    2000,
    5000,
    10000,
    20000,
    60000,
    120000,
    300000,
    600000,
  ];

  // The final slot counts samples above the largest bound.
  final List<int> _counts = List<int>.filled(bucketUpperBoundsMs.length + 1, 0);
  int _count = 0;
  int _sumMs = 0;
  int _maxMs = 0;

  int get count => _count;
  int get maxMs => _maxMs;

  void record(int milliseconds) {
    final value = milliseconds < 0 ? 0 : milliseconds;
    var index = bucketUpperBoundsMs.length;
    for (var i = 0; i < bucketUpperBoundsMs.length; i++) {
      if (value <= bucketUpperBoundsMs[i]) {
        index = i;
        break;
      }
    }
    _counts[index]++;
    _count++;
    _sumMs += value;
    if (value > _maxMs) _maxMs = value;
  }

  /// [percent] is in the range 0..100. Returns null when no samples exist.
  int? percentileMs(double percent) {
    if (_count == 0) return null;
    final clamped = percent.clamp(0, 100).toDouble();
    var rank = (clamped / 100 * _count).ceil();
    if (rank < 1) rank = 1;
    var cumulative = 0;
    for (var i = 0; i < _counts.length; i++) {
      cumulative += _counts[i];
      if (cumulative >= rank) {
        if (i >= bucketUpperBoundsMs.length) return _maxMs;
        final bound = bucketUpperBoundsMs[i];
        return bound < _maxMs ? bound : _maxMs;
      }
    }
    return _maxMs;
  }

  Map<String, Object?> toJson() => {
        'count': _count,
        'p50Ms': percentileMs(50),
        'p95Ms': percentileMs(95),
        'p99Ms': percentileMs(99),
        'maxMs': _maxMs,
        'meanMs': _count == 0 ? null : (_sumMs / _count).round(),
      };
}

/// One recorded stage of an assignment's local lifecycle.
final class TraceMark {
  const TraceMark({
    required this.stage,
    required this.elapsedMs,
    required this.sinceLastMs,
    required this.monotonicMs,
    required this.at,
  });

  final String stage;

  /// Monotonic milliseconds since the assignment was first seen.
  final int elapsedMs;

  /// Monotonic milliseconds since the previous recorded stage.
  final int sinceLastMs;

  /// Process-level monotonic reading (see [processMonotonicMs]).
  final int monotonicMs;

  /// Local wall-clock time, for cross-host correlation after offset correction.
  final DateTime at;
}

/// Records per-assignment stage timings with a monotonic timer and feeds
/// bounded latency histograms. All methods are synchronous, allocate little
/// and never throw, so they are safe on the command-acknowledgement path.
final class AssignmentTraceRecorder {
  AssignmentTraceRecorder({this.maxActive = 256});

  /// Open traces are bounded; the oldest is evicted first.
  final int maxActive;
  final Map<String, _ActiveTrace> _active = {};
  final Map<String, LatencyHistogram> _intervals = {};

  static const String firstStage = 'service_received';

  bool isTracking(String assignmentId) => _active.containsKey(assignmentId);

  /// Starts a trace at the moment the command is first observed. Returns null
  /// if the assignment is already being traced (a replayed command).
  ///
  /// [note] is a short bounded label captured at receipt (for example the
  /// connection stage), retrievable with [noteOf].
  TraceMark? begin(String assignmentId, {String? note}) {
    try {
      if (_active.containsKey(assignmentId)) return null;
      while (_active.length >= maxActive) {
        _active.remove(_active.keys.first);
      }
      final trace = _ActiveTrace()..note = note;
      _active[assignmentId] = trace;
      trace.stages.add(firstStage);
      return TraceMark(
        stage: firstStage,
        elapsedMs: 0,
        sinceLastMs: 0,
        monotonicMs: processMonotonicMs(),
        at: DateTime.now().toUtc(),
      );
    } on Object {
      return null;
    }
  }

  /// Records [stage] once per assignment. Returns null when the assignment is
  /// not traced or the stage was already recorded.
  TraceMark? mark(String assignmentId, String stage) {
    try {
      final trace = _active[assignmentId];
      if (trace == null || !trace.stages.add(stage)) return null;
      final elapsed = trace.timer.elapsedMilliseconds;
      final since = elapsed - trace.lastElapsedMs;
      final previous = trace.lastStage;
      trace
        ..lastElapsedMs = elapsed
        ..lastStage = stage;
      _histogram('$previous->$stage').record(since);
      _histogram('since_received:$stage').record(elapsed);
      return TraceMark(
        stage: stage,
        elapsedMs: elapsed,
        sinceLastMs: since,
        monotonicMs: processMonotonicMs(),
        at: DateTime.now().toUtc(),
      );
    } on Object {
      return null;
    }
  }

  /// Monotonic milliseconds since the assignment was first seen.
  int? elapsedMs(String assignmentId) =>
      _active[assignmentId]?.timer.elapsedMilliseconds;

  String? noteOf(String assignmentId) => _active[assignmentId]?.note;

  /// Releases the open trace; histograms are retained.
  void finish(String assignmentId) {
    _active.remove(assignmentId);
  }

  LatencyHistogram _histogram(String name) =>
      _intervals.putIfAbsent(name, LatencyHistogram.new);

  int get activeTraceCount => _active.length;

  /// p50/p95/p99 per interval, keyed by `from->to` and `since_received:stage`.
  Map<String, Object?> summaryJson() => {
        for (final entry in _intervals.entries) entry.key: entry.value.toJson(),
      };
}

final class _ActiveTrace {
  final Stopwatch timer = Stopwatch()..start();
  final Set<String> stages = <String>{};
  String lastStage = AssignmentTraceRecorder.firstStage;
  int lastElapsedMs = 0;
  String? note;
}

/// Runs [action] without letting it delay or fail the caller. Used for
/// telemetry so that a slow disk or a thrown error cannot hold up command
/// acknowledgement or process launch.
void runDetachedTelemetry(Future<void> Function() action) {
  try {
    unawaited(action().then<void>((_) {}, onError: (Object _) {}));
  } on Object {
    // Telemetry boundary.
  }
}
