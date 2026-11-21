import 'package:syntila_protocol/syntila_protocol.dart' show WorkerInstance;

import 'ax_models.dart';
import 'worker_execution_options.dart';

/// The composer's Workers under the Worker-first architecture: exactly the
/// owner's Worker Instances (what the Workers page lists), not the legacy
/// Workspace inventory. Model and effort options are the ones the paired
/// Worker reported (`executionOptions`), falling back to the inventory row a
/// Worker Instance was adopted from. The selection id is the Worker Instance id.
List<AxWorker> workersFromInstances(
  List<AxWorker> inventory,
  List<WorkerInstance> instances,
) {
  final byInstance = <String, AxWorker>{
    for (final worker in inventory)
      if (!worker.shared && worker.workerInstanceId != null)
        worker.workerInstanceId!: worker,
  };
  return [
    for (final instance in instances)
      if (!instance.isRevoked) _fromInstance(instance, byInstance[instance.id]),
  ];
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

AxWorker _fromInstance(WorkerInstance instance, AxWorker? base) {
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
    workspaceId: '',
    workspaceName: '',
    workerTypeId: instance.workerTypeId,
    displayName: instance.name,
    description: instance.description,
    status: status,
    readinessState: readiness,
    activationState: activation,
    localConcurrencyLimit: 1,
    providerToolName: instance.providerToolName,
    providerToolVersion: instance.providerToolVersion,
    executionOptions: options,
  );
}
