import 'package:syntila_protocol/syntila_protocol.dart' show WorkerInstance;

import 'ax_models.dart';

/// The composer's Workers under the Worker-first architecture: exactly the
/// owner's Worker Instances (what the Workers page lists), not the legacy
/// Workspace inventory. Model and effort options are the ones the paired
/// Worker reported (`executionOptions`), falling back to the inventory row a
/// Worker Instance was adopted from. The selection id is the Worker Instance id.
List<AxWorker> workersFromInstances(
  List<AxWorker> inventory,
  List<WorkerInstance> instances, {
  List<WorkerInstance> sharedInstances = const [],
}) {
  final byInstance = <String, AxWorker>{
    for (final worker in inventory)
      if (!worker.shared && worker.workerInstanceId != null)
        worker.workerInstanceId!: worker,
  };
  final seen = <String>{};
  final result = <AxWorker>[];
  for (final instance in instances) {
    if (!instance.isRevoked && seen.add(instance.id)) {
      result.add(_fromInstance(instance, byInstance[instance.id]));
    }
  }
  for (final instance in sharedInstances) {
    if (!instance.isRevoked && seen.add(instance.id)) {
      result.add(_fromInstance(instance, null, shared: true));
    }
  }
  return result;
}

AxWorkerExecutionOptions? _optionsOf(WorkerInstance instance) {
  final json = instance.executionOptions;
  if (json == null) return null;
  try {
    return AxWorkerExecutionOptions.fromJson(Map<String, dynamic>.from(json));
  } on Object {
    return null; // Unreadable options offer no models rather than failing.
  }
}

AxWorker _fromInstance(WorkerInstance instance, AxWorker? base,
    {bool shared = false}) {
  final options = _optionsOf(instance);
  final ready = instance.enabled && instance.online && instance.ready;
  final activation = instance.enabled ? 'enabled' : 'disabled';
  final readiness = ready ? 'ready' : 'test_failed';
  final status = !instance.enabled
      ? 'disabled'
      : ready
          ? 'ready'
          : 'needs_attention';
  if (base != null) {
    return base.copyWith(
      id: instance.id,
      workerInstanceId: instance.id,
      displayName: instance.name,
      status: status,
      readinessState: readiness,
      activationState: activation,
      executionOptions: options,
    );
  }
  return AxWorker(
    id: instance.id,
    workerInstanceId: instance.id,
    workerTypeId: instance.workerTypeId,
    displayName: instance.name,
    description: instance.description,
    status: status,
    readinessState: readiness,
    activationState: activation,
    localConcurrencyLimit: 1,
    shared: shared,
    providerToolName: instance.providerToolName,
    providerToolVersion: instance.providerToolVersion,
    executionOptions: options,
  );
}
