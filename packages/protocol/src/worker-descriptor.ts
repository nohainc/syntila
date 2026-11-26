export const WORKER_DESCRIPTOR_ENGINE_FAMILIES = ["cli"] as const;
export type WorkerDescriptorEngineFamily =
  (typeof WORKER_DESCRIPTOR_ENGINE_FAMILIES)[number];

export const WORKER_DESCRIPTOR_RELEASE_STAGES = [
  "testing",
  "beta",
  "stable",
] as const;
export type WorkerDescriptorReleaseStage =
  (typeof WORKER_DESCRIPTOR_RELEASE_STAGES)[number];

export const WORKER_DESCRIPTOR_VISIBILITY_STATES = [
  "hidden",
  "visible",
] as const;
export type WorkerDescriptorVisibilityState =
  (typeof WORKER_DESCRIPTOR_VISIBILITY_STATES)[number];

export interface WorkerDescriptor {
  readonly workerTypeId: string;
  readonly displayName: string;
  readonly description: string;
  readonly engineFamily: WorkerDescriptorEngineFamily;
  readonly profileDefinitionId: string;
  readonly providerToolName: string;
  readonly releaseStage: WorkerDescriptorReleaseStage;
  readonly visibilityState: WorkerDescriptorVisibilityState;
  readonly sortOrder: number;
}

const fields = new Set([
  "workerTypeId",
  "displayName",
  "description",
  "engineFamily",
  "profileDefinitionId",
  "providerToolName",
  "releaseStage",
  "visibilityState",
  "sortOrder",
]);
const identifier = /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/;

/** Parse Cloud-owned Worker metadata without accepting Connect-local state. */
export function parseWorkerDescriptor(value: unknown): WorkerDescriptor {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new TypeError("Worker descriptor must be an object");
  }
  const item = value as Record<string, unknown>;
  if (
    Object.keys(item).some((key) => !fields.has(key)) ||
    typeof item.workerTypeId !== "string" ||
    item.workerTypeId.length > 96 ||
    !identifier.test(item.workerTypeId) ||
    typeof item.displayName !== "string" ||
    item.displayName.trim().length === 0 ||
    item.displayName.length > 128 ||
    typeof item.description !== "string" ||
    item.description.length > 500 ||
    item.engineFamily !== "cli" ||
    typeof item.profileDefinitionId !== "string" ||
    item.profileDefinitionId.length > 96 ||
    !identifier.test(item.profileDefinitionId) ||
    typeof item.providerToolName !== "string" ||
    item.providerToolName.trim().length === 0 ||
    item.providerToolName.length > 128 ||
    !(WORKER_DESCRIPTOR_RELEASE_STAGES as readonly unknown[]).includes(
      item.releaseStage,
    ) ||
    !(WORKER_DESCRIPTOR_VISIBILITY_STATES as readonly unknown[]).includes(
      item.visibilityState,
    ) ||
    !Number.isSafeInteger(item.sortOrder) ||
    Number(item.sortOrder) < 0 ||
    Number(item.sortOrder) > 10_000
  ) {
    throw new TypeError("Worker descriptor is invalid");
  }
  return {
    workerTypeId: item.workerTypeId,
    displayName: item.displayName,
    description: item.description,
    engineFamily: item.engineFamily,
    profileDefinitionId: item.profileDefinitionId,
    providerToolName: item.providerToolName,
    releaseStage: item.releaseStage as WorkerDescriptorReleaseStage,
    visibilityState: item.visibilityState as WorkerDescriptorVisibilityState,
    sortOrder: Number(item.sortOrder),
  };
}
