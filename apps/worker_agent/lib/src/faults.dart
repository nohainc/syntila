import 'dart:async';

/// Thrown by a test hook to stand in for the process dying at that exact
/// point. The runtime treats it as a kill: no more writes, no more messages.
class SimulatedCrash implements Exception {
  SimulatedCrash(this.point);
  final String point;

  @override
  String toString() => 'simulated crash at $point';
}

/// Called at named points of the assignment lifecycle with the assignment id.
/// Points: `before-<journal event>`, `after-<journal event>` for received,
/// accepted, starting, running, terminal and acknowledged, plus
/// `before-ack`, `after-engine-launch`, `after-terminal-send`.
typedef FaultPoint = FutureOr<void> Function(String point, String assignmentId);
