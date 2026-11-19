import 'cloud_connection.dart';

/// How long an accepted assignment may wait locally for the Space lock, a
/// Worker slot or a busy provider session before it launches. This is the
/// local queue allowance; it is unrelated to Cloud's command-delivery
/// deadlines, which end when the Service acknowledges the command.
///
/// Must equal `CliWorkerEngineSupervisor.defaultQueueWaitTimeout`.
const defaultAssignmentQueueAllowance = Duration(minutes: 2);

/// The ordered milestones of starting an accepted assignment locally:
///
/// Worker resolved → Profile ready → (waiting for Space) → (queued for slot)
/// → Slot reserved → Engine spawned → Engine initialized → Provider started.
///
/// A process visible in Activity Monitor only proves [engineSpawned];
/// [engineInitialized] proves the Engine accepted its identity and Profile,
/// and [providerStarted] proves the provider itself began executing.
enum AssignmentStartupStage {
  workerResolved('worker_resolved'),
  profileReady('profile_ready'),
  waitingForSpace('waiting_for_space'),
  spacePrepared('space_prepared'),
  queuedForSlot('queued_for_slot'),
  slotReserved('slot_reserved'),
  engineSpawned('engine_spawned'),
  engineInitialized('engine_initialized'),
  providerStarted('provider_started'),
  providerFirstOutput('provider_first_output'),
  providerProcessExited('provider_process_exited'),
  providerLastOutputReported('provider_last_output_reported'),
  engineResultReceived('engine_result_received');

  const AssignmentStartupStage(this.wireName);

  /// Stable, non-secret name used in diagnostics and Cloud stage updates.
  final String wireName;

  /// Stages that mean the assignment is waiting rather than progressing.
  bool get isWaiting => this == waitingForSpace || this == queuedForSlot;
}

/// Receives startup milestones. Observation only: it is never awaited and
/// must not throw into the launch path.
typedef AssignmentStartupRelay = void Function(
  WorkspaceAssignmentContext context,
  AssignmentStartupStage stage,
  Map<String, Object?> detail,
);
