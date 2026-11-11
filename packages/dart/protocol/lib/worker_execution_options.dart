/// Product-safe capability projections. These types never carry native IDs,
/// invocation arguments, signed payloads, or credentials.
enum CapabilityState { ready, loading, stale, unavailable, unsupported }

class ExecutionModelCapability {
  const ExecutionModelCapability(
      {required this.id,
      required this.name,
      this.efforts = const [],
      this.defaultEffort,
      this.selectionMode = 'separate',
      this.status = 'listed'});
  final String id, name, selectionMode, status;
  final List<String> efforts;
  final String? defaultEffort;
  bool get available => status != 'unavailable';
  factory ExecutionModelCapability.fromJson(Map<String, dynamic> json) {
    final legacy = json['effort'] as Map?;
    return ExecutionModelCapability(
        id: json['id'] as String,
        name: json['name'] as String,
        efforts: List<String>.unmodifiable(
            (json['efforts'] ?? legacy?['values'] ?? const <String>[]) as List),
        defaultEffort:
            (json['defaultEffort'] ?? legacy?['defaultValue']) as String?,
        selectionMode: json['selectionMode'] as String? ?? 'separate',
        status: json['status'] as String? ?? 'listed');
  }
}

class ExecutionSelection {
  const ExecutionSelection(
      {this.worker, this.model, this.effort, this.catalogRevision});
  final String? worker, model, effort, catalogRevision;

  /// Refreshes preserve saved intent; validation is a separate operation.
  ExecutionSelection normalized() {
    String? choice(String? value) =>
        value == null || value.trim().isEmpty ? null : value.trim();
    return ExecutionSelection(
        worker: choice(worker),
        model: choice(model),
        effort: choice(effort),
        catalogRevision: catalogRevision);
  }

  ExecutionSelection overlay(ExecutionSelection value) => ExecutionSelection(
      worker: value.worker ?? worker,
      model: value.model ?? model,
      effort: value.effort ?? effort,
      catalogRevision: value.worker != null && value.worker != worker
          ? value.catalogRevision
          : value.catalogRevision ?? catalogRevision);
}

class WorkerSelectionCapability {
  const WorkerSelectionCapability(
      {required this.id,
      required this.name,
      this.models = const [],
      this.state = CapabilityState.ready,
      this.modelSupported = true,
      this.defaultModelId,
      this.globalEfforts = const [],
      this.allowedModelIds,
      this.allowsCustomModel = false,
      this.autoModelSupported = true,
      this.availabilityMessage,
      this.catalogRevision});
  final String id, name;
  final List<ExecutionModelCapability> models;
  final CapabilityState state;
  final bool modelSupported, allowsCustomModel, autoModelSupported;
  final String? defaultModelId, availabilityMessage, catalogRevision;
  final List<String> globalEfforts;
  final List<String>? allowedModelIds;
  factory WorkerSelectionCapability.fromExecutionOptions(
      {required String id,
      required String name,
      required Map<String, dynamic> options,
      String? availabilityMessage}) {
    final models = options['models'] as Map;
    return WorkerSelectionCapability(
        id: id,
        name: name,
        availabilityMessage: availabilityMessage,
        catalogRevision: options['catalogRevision'] as String?,
        state: options['catalogStale'] == true
            ? CapabilityState.stale
            : CapabilityState.ready,
        modelSupported: models['supported'] == true,
        allowsCustomModel: models['allowsCustomModel'] == true,
        defaultModelId: models['defaultModelId'] as String?,
        allowedModelIds: List<String>.unmodifiable(
            (models['allowedModelIds'] ?? const <String>[]) as List),
        models: List.unmodifiable((models['options'] as List).map((v) =>
            ExecutionModelCapability.fromJson(
                Map<String, dynamic>.from(v as Map)))),
        globalEfforts: List<String>.unmodifiable(
            ((options['effort'] as Map)['values'] ?? const <String>[])
                as List));
  }
  ExecutionModelCapability? model(String? id) {
    for (final value in models) {
      if (value.id == id) return value;
    }
    return null;
  }

  bool supportsModel(String? id) =>
      id == null ||
      (modelSupported &&
          model(id)?.available != false &&
          (allowsCustomModel ||
              (allowedModelIds ??
                      models.where((m) => m.available).map((m) => m.id))
                  .contains(id)));
  List<String> effortsForModel(String? id) {
    if (!supportsModel(id)) return const [];
    final selected = model(id ?? defaultModelId);
    return selected == null
        ? globalEfforts
        : selected.available
            ? selected.efforts
            : const [];
  }

  bool get allowsAutoModel =>
      autoModelSupported &&
      models.every((value) => value.selectionMode != 'combined');

  bool allowsAutoEffort(String? id) {
    if (id == null && !allowsAutoModel) return false;
    final selected = model(id ?? defaultModelId);
    return selected?.selectionMode != 'combined';
  }

  /// Mutable preferences follow current capabilities; observed revisions are
  /// retained as metadata. Cloud pins the revision when accepting execution.
  String? validatePreference(ExecutionSelection value) =>
      validate(ExecutionSelection(
          worker: value.worker, model: value.model, effort: value.effort));

  /// Exact revision validation for an already pinned execution selection.
  String? validate(ExecutionSelection value) {
    if (state == CapabilityState.loading) return 'Loading Worker capabilities…';
    if (state == CapabilityState.stale)
      return 'Worker capabilities are stale; refresh the Workspace catalog.';
    if (state == CapabilityState.unavailable)
      return 'Model and effort options are unavailable for this Worker.';
    if (value.catalogRevision != null &&
        value.catalogRevision != catalogRevision)
      return 'Worker catalog changed; refresh and confirm the selection.';
    if (!supportsModel(value.model))
      return 'The selected model is not supported by this Worker.';
    if (value.model == null && !allowsAutoModel)
      return 'Select an explicit model for this Worker.';
    final selected = model(value.model);
    final efforts = effortsForModel(value.model);
    if (selected?.selectionMode == 'combined' &&
        efforts.isNotEmpty &&
        selected?.defaultEffort == null &&
        value.effort == null) return 'Select an effort for this model.';
    if (value.effort != null && !efforts.contains(value.effort))
      return 'The selected effort is not supported for this Worker and model.';
    return null;
  }
}

/// Pure selection rules shared by management and authoring clients.
class ExecutionSelectionCatalog {
  const ExecutionSelectionCatalog(this.workers);
  final List<WorkerSelectionCapability> workers;
  WorkerSelectionCapability? worker(String? id) {
    for (final value in workers) {
      if (value.id == id) return value;
    }
    return null;
  }

  ExecutionSelection changeModel(ExecutionSelection value, String? id,
      {ExecutionSelection inherited = const ExecutionSelection()}) {
    final candidate = ExecutionSelection(
        worker: value.worker, model: id, effort: value.effort);
    final effective = inherited.overlay(candidate);
    final supported =
        worker(effective.worker)?.effortsForModel(effective.model) ??
            const <String>[];
    return ExecutionSelection(
        worker: value.worker,
        model: id,
        catalogRevision: worker(effective.worker)?.catalogRevision,
        effort: value.effort != null && supported.contains(value.effort)
            ? value.effort
            : null);
  }
}
