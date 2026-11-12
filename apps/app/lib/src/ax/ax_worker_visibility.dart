import 'package:syntila_protocol/syntila_protocol.dart';

/// Personal display exclusions. They never grant access or validate execution.
class AxWorkerVisibility {
  AxWorkerVisibility(
      {Iterable<String> hiddenWorkers = const [],
      Map<String, List<String>> hiddenModels = const {},
      Map<String, Map<String, List<String>>> hiddenEfforts = const {}})
      : hiddenWorkers = List.unmodifiable(hiddenWorkers),
        hiddenModels = Map.unmodifiable(hiddenModels
            .map((k, v) => MapEntry(k, List<String>.unmodifiable(v)))),
        hiddenEfforts = Map.unmodifiable(hiddenEfforts.map((k, v) => MapEntry(
            k,
            Map<String, List<String>>.unmodifiable(
                v.map((m, e) => MapEntry(m, List<String>.unmodifiable(e)))))));
  final List<String> hiddenWorkers;
  final Map<String, List<String>> hiddenModels;
  final Map<String, Map<String, List<String>>> hiddenEfforts;

  factory AxWorkerVisibility.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 ||
        json['hiddenWorkers'] is! List ||
        json['hiddenModels'] is! Map ||
        json['hiddenEfforts'] is! Map) {
      throw const FormatException('Invalid Worker visibility preferences');
    }
    List<String> strings(Object? v) => List<String>.from(v as List);
    Map<String, List<String>> models(Object? v) =>
        (v as Map).map((k, v) => MapEntry(k as String, strings(v)));
    return AxWorkerVisibility(
        hiddenWorkers: strings(json['hiddenWorkers']),
        hiddenModels: models(json['hiddenModels']),
        hiddenEfforts: (json['hiddenEfforts'] as Map)
            .map((k, v) => MapEntry(k as String, models(v))));
  }
  Map<String, dynamic> toJson() => {
        'schemaVersion': 1,
        'hiddenWorkers': hiddenWorkers,
        'hiddenModels': hiddenModels,
        'hiddenEfforts': hiddenEfforts
      };
  bool workerHidden(String id) => hiddenWorkers.contains(id);
  bool modelHidden(String worker, String model) =>
      hiddenModels[worker]?.contains(model) ?? false;
  bool effortHidden(String worker, String model, String effort) =>
      hiddenEfforts[worker]?[model]?.contains(effort) ?? false;
}

abstract interface class AxWorkerVisibilityDataSource {
  Future<AxWorkerVisibility> loadWorkerVisibility(String workspaceId);
  Future<AxWorkerVisibility> saveWorkerVisibility(
      String workspaceId, AxWorkerVisibility preferences);
  Future<AxWorkerVisibility> resetWorkerVisibility(String workspaceId);
}

/// Display-only view over an already authorized catalog. The original catalog
/// remains authoritative for validation and retains all capability metadata.
class AxWorkerVisibilityProjection {
  AxWorkerVisibilityProjection(this.catalog, this.preferences,
      {this.selected = const ExecutionSelection()});
  final ExecutionSelectionCatalog catalog;
  final AxWorkerVisibility preferences;
  final ExecutionSelection selected;
  static const hiddenLabel = 'Hidden in Workers for me';
  List<WorkerSelectionCapability> get workers =>
      List.unmodifiable(catalog.workers.where(
          (w) => !preferences.workerHidden(w.id) || selected.worker == w.id));
  bool workerIsHidden(String id) => preferences.workerHidden(id);
  bool modelIsHidden(String worker, String model) =>
      preferences.workerHidden(worker) ||
      preferences.modelHidden(worker, model);
  bool effortIsHidden(String worker, String model, String effort) =>
      modelIsHidden(worker, model) ||
      preferences.effortHidden(worker, model, effort);
  Map<String, String> models(String workerId) {
    final worker = catalog.worker(workerId);
    if (worker == null || !worker.modelSupported) return const {};
    final ids = <String>{
      ...worker.models.map((m) => m.id),
      ...?worker.allowedModelIds,
      if (selected.worker == workerId && selected.model != null)
        selected.model!,
    };
    return Map.unmodifiable({
      for (final id in ids)
        if (worker.supportsModel(id) &&
            (!modelIsHidden(workerId, id) ||
                (selected.worker == workerId && selected.model == id)))
          id: '${worker.model(id)?.name ?? id}${modelIsHidden(workerId, id) ? ' · $hiddenLabel' : ''}'
    });
  }

  List<String> efforts(String workerId, String? modelId) {
    final worker = catalog.worker(workerId);
    if (worker == null) return const [];
    final effectiveModel = modelId ?? worker.defaultModelId;
    return List.unmodifiable(worker.effortsForModel(modelId).where((effort) =>
        (!preferences.workerHidden(workerId) &&
            (effectiveModel == null ||
                !effortIsHidden(workerId, effectiveModel, effort))) ||
        (selected.worker == workerId &&
            selected.model == modelId &&
            selected.effort == effort)));
  }

  String workerLabel(WorkerSelectionCapability worker) =>
      '${worker.name}${workerIsHidden(worker.id) ? ' · $hiddenLabel' : ''}';
  String effortLabel(String worker, String model, String effort) =>
      '$effort${effortIsHidden(worker, model, effort) ? ' · $hiddenLabel' : ''}';
}
