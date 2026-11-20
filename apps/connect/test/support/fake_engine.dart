import 'dart:async';

import 'package:syntila_connect/syntila_connect.dart';

class FakeRun implements EngineRun, EngineStartEvidence {
  FakeRun(this.assignmentId, this._owner);

  final String assignmentId;
  final FakeEngine _owner;
  final Completer<EngineOutcome> _outcome = Completer();

  @override
  Future<EngineOutcome> get outcome => _outcome.future;

  bool get isRunning => !_outcome.isCompleted;

  @override
  Future<bool> get providerStarted async => !_owner.failBeforeProviderStart;

  void finish(EngineOutcome outcome) {
    if (_outcome.isCompleted) return;
    _outcome.complete(outcome);
  }

  @override
  Future<void> cancel() async {
    finish(
      const EngineOutcome(TerminalKind.cancelled, {'reason': 'Cancelled'}),
    );
  }

  void orphan() => _owner._orphans.add(this);
}

/// A scriptable Engine that stands for the host's provider process. One
/// instance can be shared by several Agent runs on the same "host", so its
/// counters show whether any assignment was ever started twice.
class FakeEngine implements EngineLauncher {
  /// Every launch, in order.
  final List<String> launches = [];
  final Map<String, FakeRun> runs = {};
  final Map<String, EngineRequest> requests = {};
  final List<FakeRun> _orphans = [];

  /// Keep work running until [finish] is called.
  bool hold = false;
  bool failBeforeProviderStart = false;
  String? unavailable;
  int recovered = 0;

  int launchCount(String assignmentId) =>
      launches.where((id) => id == assignmentId).length;

  int get maxLaunchesPerAssignment {
    final counts = <String, int>{};
    for (final id in launches) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
    return counts.values.fold(0, (a, b) => a > b ? a : b);
  }

  @override
  Future<EngineRun> launch(EngineRequest request) async {
    launches.add(request.assignmentId);
    requests[request.assignmentId] = request;
    final run = FakeRun(request.assignmentId, this);
    runs[request.assignmentId] = run;
    if (failBeforeProviderStart) {
      scheduleMicrotask(
        () => run.finish(
          const EngineOutcome(TerminalKind.failed, {
            'errorCode': 'engine_failed',
            'retryable': false,
          }),
        ),
      );
    } else if (!hold) {
      scheduleMicrotask(
        () => run.finish(
          EngineOutcome(TerminalKind.completed, {
            'summary': 'done ${request.assignmentId}',
            'output': 'ok',
          }),
        ),
      );
    }
    return run;
  }

  void finish(String assignmentId, EngineOutcome outcome) =>
      runs[assignmentId]?.finish(outcome);

  /// The Agent died without a goodbye: its Engine children keep running until
  /// the next Agent start finds and kills them.
  void orphanRunning() {
    for (final run in runs.values.where((r) => r.isRunning)) {
      run.orphan();
    }
  }

  @override
  Future<int> recoverOrphans() async {
    final count = _orphans.length;
    for (final run in _orphans) {
      await run.cancel();
    }
    _orphans.clear();
    recovered += count;
    return count;
  }

  @override
  Future<String?> probe() async => unavailable;
}
