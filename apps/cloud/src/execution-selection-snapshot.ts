import {
  type WorkerExecutionOptions,
  validateWorkerExecutionSelection,
  workerEffortOptionsForModel,
} from "@syntila/core";

/** Frozen public evidence; provider-native resolution belongs to the Engine. */
export function resolveExecutionSelectionSnapshot(
  options: WorkerExecutionOptions,
  selection: {
    modelId: string | null;
    effort: string | null;
    catalogRevision?: string | null;
  },
  worker: {
    workerTypeId: string;
    workerDisplayName: string;
    profileReleaseVersion: number;
  },
) {
  const requestedError = validateWorkerExecutionSelection(
    options,
    selection.modelId,
    selection.effort,
    selection.catalogRevision,
  );
  if (requestedError) throw new Error(requestedError);
  const modelId = selection.modelId ?? options.models.defaultModelId;
  const effort =
    selection.effort ??
    workerEffortOptionsForModel(options, modelId).defaultValue;
  const error = validateWorkerExecutionSelection(options, modelId, effort);
  if (error) throw new Error(error);
  return Object.freeze({
    schemaVersion: 1 as const,
    ...worker,
    modelId,
    catalogSource: options.models.discovery,
    modelName:
      options.models.options.find((model) => model.id === modelId)?.name ??
      modelId,
    effort,
    catalogRevision:
      options.schemaVersion === 2 ? options.catalogRevision : null,
    modelSource:
      selection.modelId != null
        ? "explicit"
        : modelId != null
          ? "catalog_default"
          : "provider_default",
    effortSource:
      selection.effort != null
        ? "explicit"
        : effort != null
          ? "catalog_default"
          : "provider_default",
  });
}

/** Versioned boundary support; never silently drop a catalog pin for old Engines. */
export function supportsExecutionCatalogPin(engineVersion: unknown): boolean {
  if (typeof engineVersion !== "string") return false;
  const version = /^(\d+)\.(\d+)\.(\d+)$/.exec(engineVersion);
  return (
    !!version &&
    (Number(version[1]) > 1 ||
      (Number(version[1]) === 1 && Number(version[2]) >= 3))
  );
}

/** Plugin execution needs Engine 1.4.0 or newer (Local Worker Protocol 4.2). */
export function supportsPluginExecutor(engineVersion: unknown): boolean {
  if (typeof engineVersion !== "string") return false;
  const version = /^(\d+)\.(\d+)\.(\d+)$/.exec(engineVersion);
  return (
    !!version &&
    (Number(version[1]) > 1 ||
      (Number(version[1]) === 1 && Number(version[2]) >= 4))
  );
}
