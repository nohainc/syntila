/// Cloud-derived execution phase of one Work step (V9 Phase 7).
///
/// Cloud computes the phase from the assignment's recorded evidence. The UI
/// only renders it: it never infers a phase from elapsed time, from the Work
/// Request status (which becomes `running` when the Workflow starts, long
/// before any Worker accepts the command) or from the last activity event.
abstract final class AxExecutionPhase {
  static const submitted = 'submitted';
  static const waitingForService = 'waiting_for_service';
  static const delivering = 'delivering';
  static const delivered = 'delivered';
  static const queued = 'queued';
  static const starting = 'starting';
  static const running = 'running';
  static const completed = 'completed';
  static const failed = 'failed';
  static const cancelled = 'cancelled';
  static const uncertain = 'uncertain';

  static const terminal = {completed, failed, cancelled};

  static const _rank = {
    submitted: 0,
    waitingForService: 1,
    delivering: 2,
    delivered: 3,
    queued: 4,
    starting: 5,
    running: 6,
    uncertain: 6,
    completed: 7,
    failed: 7,
    cancelled: 7,
  };

  static bool isKnown(String? phase) => _rank.containsKey(phase);

  static bool isTerminal(String? phase) => terminal.contains(phase);

  /// The headline label. Delivery sub-steps all read as Queued: the user has
  /// one question at that point, "has it started?", and the answer is no.
  static String label(String phase) => switch (phase) {
        submitted => 'Submitted',
        waitingForService || delivering || delivered || queued => 'Queued',
        starting => 'Starting',
        running => 'Running',
        completed => 'Completed',
        failed => 'Failed',
        cancelled => 'Cancelled',
        uncertain => 'Checking',
        _ => 'Queued',
      };

  /// Fixed sub-line separating command delivery from provider execution.
  static String? detail(String phase) => switch (phase) {
        submitted => 'Request received by Syntila',
        waitingForService => 'Waiting for Connect to be ready',
        delivering => 'Sending to your Worker',
        delivered => 'Worker accepted the request',
        queued => 'All Worker slots are busy; starting when one is free',
        starting => 'Starting your worker',
        uncertain => 'Checking whether execution is still active',
        _ => null,
      };

  /// True only once the provider start was observed.
  static bool isExecuting(String? phase) => phase == running;

  /// Whether a pushed phase may replace [current] in place.
  ///
  /// A phase only moves forward. A terminal phase is never replaced by a
  /// delayed event, and the non-monotonic phases (`uncertain`, or any
  /// terminal outcome that needs failure detail) are not applied from the
  /// event: the caller re-reads authoritative state instead.
  static bool advances(String? current, String incoming) {
    if (!isKnown(incoming) || incoming == uncertain || isTerminal(incoming)) {
      return false;
    }
    if (current == null) return true;
    if (!isKnown(current) || isTerminal(current) || current == uncertain) {
      return false;
    }
    return _rank[incoming]! > _rank[current]!;
  }
}
