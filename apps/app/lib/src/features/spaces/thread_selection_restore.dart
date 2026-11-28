import '../../ax/ax_models.dart';
import '../../ax/sync/persistence/ax_thread_view_state.dart';

/// A saved Thread selection resolved against today's catalogs.
class RestoredThreadSelection {
  const RestoredThreadSelection(
      {this.workflowReference, this.selection = const {}});

  /// The Workflow to select, or null to keep the default one.
  final String? workflowReference;

  /// Worker/model/effort (and per-step choices) for the composer.
  final Map<String, dynamic> selection;
}

/// Turns the selection saved for a Thread into what the composer can show now.
///
/// Returns null while the catalogs the saved choice depends on are still
/// loading, so the caller keeps it pending and asks again when they change.
/// Nothing the user chose is silently replaced: a Worker, model or effort that
/// is no longer offered stays selected so the composer can say it is
/// unavailable.
RestoredThreadSelection? restoreThreadSelection(
  AxThreadViewState saved, {
  required List<AxBuiltinWorkflow> workflows,
  required List<AxBuiltinWorkflow> currentWorkflows,
  required List<AxWorker> workers,
  required bool workersSettled,
  required bool awaitingInitialWorkers,
  required bool loadingWorkflows,
}) {
  if (workflows.isEmpty) return null;
  final needsWorkers =
      saved.workerId != null || saved.stepSelections.isNotEmpty;
  if (needsWorkers && !workersSettled) return null;
  // The first Worker list can be empty and carries no type hint; resolving
  // against it would lose the saved Worker.
  if (saved.workerId != null && awaitingInitialWorkers) return null;

  // The exact reference first, then the same Workflow at its current version,
  // so a version bump keeps the choice.
  final savedId = saved.workflowReference?.split(':').first;
  final workflow = workflows
          .where((item) => item.reference == saved.workflowReference)
          .firstOrNull ??
      (savedId == null
          ? null
          : currentWorkflows.where((item) => item.id == savedId).firstOrNull);
  // A Workflow that no longer exists falls back to the default one, but only
  // once the catalog has finished loading.
  if (workflow == null && loadingWorkflows) return null;

  var workerId = saved.workerId;
  var catalogRevision = saved.catalogRevision;
  if (workerId != null && workers.isNotEmpty) {
    final worker = _workerFor(saved, workers);
    if (worker != null) workerId = worker.id;
    // The catalog revision changes with every rebuilt Worker catalog; the
    // saved model and effort codes stay as they were.
    catalogRevision =
        worker?.executionOptions?.catalogRevision ?? catalogRevision;
  }
  return RestoredThreadSelection(
    workflowReference: workflow?.reference,
    selection: {
      if (workerId != null) 'workerId': workerId,
      if (saved.model != null) 'model': saved.model,
      if (saved.reasoningEffort != null)
        'reasoningEffort': saved.reasoningEffort,
      if (catalogRevision != null) 'catalogRevision': catalogRevision,
      if (saved.researcherCount != null)
        'researcherCount': saved.researcherCount,
      if (saved.stepSelections.isNotEmpty)
        'steps': {
          for (final entry in saved.stepSelections.entries)
            entry.key: Map<String, dynamic>.of(entry.value),
        },
    },
  );
}

/// The saved Worker, or the one Worker of the same type when its ID is gone
/// (Worker IDs change when a Worker is rebuilt; the type code does not). An
/// ambiguous type matches nothing, preferring the single ready Worker.
AxWorker? _workerFor(AxThreadViewState saved, List<AxWorker> workers) {
  final exact = workers.where((w) => w.id == saved.workerId).firstOrNull;
  if (exact != null || saved.workerTypeId == null) return exact;
  final sameType =
      workers.where((w) => w.workerTypeId == saved.workerTypeId).toList();
  final ready = sameType.where((w) => w.isReady).toList();
  if (ready.length == 1) return ready.single;
  return sameType.length == 1 ? sameType.single : null;
}
