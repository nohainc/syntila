import 'dart:async';
import 'dart:collection';

import 'journal.dart';

/// What the Agent asks an Engine to do. Nothing here comes from Cloud as a raw
/// command string: the Profile and model are the pinned snapshot.
class EngineRequest {
  const EngineRequest({
    required this.assignmentId,
    required this.attemptId,
    required this.payload,
    this.timeout = const Duration(minutes: 30),
  });

  final String assignmentId;
  final String attemptId;
  final Map<String, Object?> payload;
  final Duration timeout;
}

class EngineOutcome {
  const EngineOutcome(this.kind, this.payload);

  final TerminalKind kind;

  /// completed: `{summary, output?, artifactIds?}`; failed: `{errorCode,
  /// retryable?}`; cancelled: `{reason?}`.
  final Map<String, Object?> payload;
}

/// One running Engine. [outcome] always completes (a crashed Engine is a
/// failed outcome); it never throws.
abstract class EngineRun {
  Future<EngineOutcome> get outcome;
  Future<void> cancel();
}

/// Optional provider-start evidence, separate from starting the Engine process.
abstract interface class EngineStartEvidence {
  Future<bool> get providerStarted;
}

/// Starts the generic CLI Worker Engine as a supervised child. The provider CLI
/// runs inside it, on demand. The adapter over the existing
/// `CliWorkerEngineSupervisor` implements this interface.
abstract class EngineLauncher {
  Future<EngineRun> launch(EngineRequest request);

  /// Kills Engine processes a previous Agent run left behind. Returns how many.
  Future<int> recoverOrphans();

  /// Whether this launcher can run work now (the Engine probe).
  Future<String?> probe();
}

/// Used when no Engine adapter is installed. It fails closed: the Worker
/// reports `engine_unavailable` and refuses every assignment.
class UnconfiguredEngineLauncher implements EngineLauncher {
  @override
  Future<EngineRun> launch(EngineRequest request) =>
      Future<EngineRun>.error(StateError('no Engine adapter is installed'));

  @override
  Future<int> recoverOrphans() async => 0;

  @override
  Future<String?> probe() async => 'engine_unavailable';
}

class EngineAlreadyStartedException implements Exception {
  EngineAlreadyStartedException(this.assignmentId);
  final String assignmentId;

  @override
  String toString() => 'an Engine was already started for $assignmentId';
}

/// Bounded slots and the "never twice" rule for one Agent. One supervisor per
/// Agent means the limit is per Worker, not per host.
class EngineSupervisor {
  EngineSupervisor(this.launcher, {this.maxConcurrent = 1})
    : assert(maxConcurrent >= 1);

  final EngineLauncher launcher;
  final int maxConcurrent;
  final Set<String> _launched = {};
  final Queue<Completer<void>> _waiters = Queue();
  final Map<String, EngineRun> _running = {};
  int _active = 0;

  int get activeSlots => _active;
  int get queued => _waiters.length;

  /// Number of Engine processes this supervisor started for [assignmentId].
  int startsFor(String assignmentId) =>
      _launched.contains(assignmentId) ? 1 : 0;

  Future<void> _acquire() {
    if (_active < maxConcurrent) {
      _active += 1;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(); // the slot passes to the next waiter
    } else {
      _active -= 1;
    }
  }

  /// Waits for a slot, asks [authorize] (the server's start permit), then
  /// launches. Returns null when [authorize] refuses. Throws
  /// [EngineAlreadyStartedException] for an assignment that was launched
  /// before, and releases the slot in every case.
  Future<EngineRun?> start(
    EngineRequest request, {
    FutureOr<bool> Function()? authorize,
    FutureOr<void> Function()? onLaunching,
  }) async {
    await _acquire();
    var handedOver = false;
    try {
      if (_launched.contains(request.assignmentId)) {
        throw EngineAlreadyStartedException(request.assignmentId);
      }
      if (authorize != null && !await authorize()) return null;
      // Recorded before the launch: if the launch call itself is interrupted,
      // the assignment still counts as started and is never started again.
      _launched.add(request.assignmentId);
      await onLaunching?.call();
      final run = await launcher.launch(request);
      _running[request.assignmentId] = run;
      handedOver = true;
      unawaited(
        run.outcome.whenComplete(() {
          _running.remove(request.assignmentId);
          _release();
        }),
      );
      return run;
    } finally {
      if (!handedOver) _release();
    }
  }

  Future<void> cancel(String assignmentId) async {
    await _running[assignmentId]?.cancel();
  }

  Future<void> cancelAll() async {
    for (final run in _running.values.toList()) {
      await run.cancel();
    }
  }
}
