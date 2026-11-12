import 'package:syntila_protocol/syntila_protocol.dart';
import 'ax_models.dart';
import 'ax_worker_visibility.dart';
import 'ax_workflow_configuration.dart';

/// Capability projection for configuration, independent of execution readiness.
class AxWorkflowSelectionOptions {
  AxWorkflowSelectionOptions(this.workers);
  final List<AxWorker> workers;

  AxWorker? worker(String? id) {
    for (final value in workers) {
      if (value.id == id) return value;
    }
    return null;
  }

  ExecutionSelectionCatalog get sharedCatalog => ExecutionSelectionCatalog([
        for (final value in workers) capabilityForWorker(value),
      ]);

  AxWorkerVisibilityProjection displayProjection(AxWorkerVisibility preferences,
          {ExecutionSelection selected = const ExecutionSelection()}) =>
      AxWorkerVisibilityProjection(sharedCatalog, preferences,
          selected: selected);

  Map<String, String> models(String? workerId) {
    final selected = sharedCatalog.worker(workerId);
    if (selected == null || !selected.modelSupported) return const {};
    return {
      for (final model in selected.models)
        if (selected.supportsModel(model.id)) model.id: model.name,
      for (final id in selected.allowedModelIds ?? const <String>[])
        if (selected.supportsModel(id)) id: selected.model(id)?.name ?? id
    };
  }

  List<String> efforts(AxWorkflowSelection value) =>
      sharedCatalog.worker(value.worker)?.effortsForModel(value.model) ??
      const [];

  /// Match Cloud's unchanged-unavailable intent rule without treating offline
  /// readiness as a capability failure. Cloud remains the write authority.
  String? validate(AxWorkflowSelection value,
      {required AxWorkflowSelection saved}) {
    final same = value.worker == saved.worker &&
        value.model == saved.model &&
        value.effort == saved.effort &&
        value.catalogRevision == saved.catalogRevision;
    if (value.worker == null) return 'Select a Worker.';
    final selected = worker(value.worker);
    if ((selected == null ||
            selected.executionOptions == null ||
            selected.executionOptions!.catalogStale) &&
        same) {
      return null;
    }
    if (selected == null) {
      return 'This Worker is unavailable. Restore the saved selection or choose another Worker.';
    }
    if (value.model == null &&
        value.effort == null &&
        value.catalogRevision == null &&
        selected.executionOptions?.catalogStale != true &&
        capabilityForWorker(selected).allowsAutoModel) {
      return null;
    }
    if (selected.executionOptions == null) {
      return 'Model and effort options are unavailable for this Worker.';
    }
    return capabilityForWorker(selected).validatePreference(ExecutionSelection(
        worker: value.worker,
        model: value.model,
        effort: value.effort,
        catalogRevision: value.catalogRevision));
  }
}

WorkerSelectionCapability capabilityForWorker(AxWorker worker) {
  final options = worker.executionOptions;
  final name =
      '${worker.displayName}${worker.isReady ? '' : worker.status == 'offline' ? ' · Offline' : ' · Unavailable'}';
  if (options == null) {
    return WorkerSelectionCapability(
        id: worker.id, name: name, state: CapabilityState.unavailable);
  }
  return WorkerSelectionCapability(
      id: worker.id,
      name: name,
      state:
          options.catalogStale ? CapabilityState.stale : CapabilityState.ready,
      modelSupported: options.modelSelectionSupported,
      allowsCustomModel: options.allowsCustomModel,
      // The Ollama adapter can choose a model implicitly only if exactly one
      // is installed; require an explicit selection that remains stable.
      autoModelSupported: worker.providerToolName != 'ollama-mcp',
      allowedModelIds: options.allowedModelIds,
      defaultModelId: options.defaultModelId,
      catalogRevision: options.catalogRevision,
      globalEfforts:
          options.effort.supported ? options.effort.values : const [],
      availabilityMessage: worker.isReady
          ? null
          : 'Execution requires an available Worker. Saved selections are retained.',
      models: [
        for (final model in options.models)
          ExecutionModelCapability(
              id: model.id,
              name: model.name,
              efforts: model.effort.supported ? model.effort.values : const [],
              defaultEffort: model.effort.defaultValue,
              status: model.status,
              selectionMode: model.selectionMode)
      ]);
}
