/** Product-safe options projected from a Worker Profile, never CLI instructions. */
export interface WorkerEffortOptions {
  readonly supported: boolean;
  readonly values: readonly string[];
  readonly defaultValue: string | null;
}
export interface LegacyWorkerModelOption {
  readonly id: string;
  readonly name: string;
  readonly badge?: string;
  readonly description?: string;
  readonly effort: WorkerEffortOptions;
}
/** Public v2 selection metadata. Native IDs and Profile digests stay local/runtime. */
export interface WorkerModelOption {
  readonly id: string;
  readonly name: string;
  readonly badge?: string;
  readonly description?: string;
  readonly efforts: readonly string[];
  readonly defaultEffort: string | null;
  readonly selectionMode: "separate" | "combined";
  readonly status: "listed" | "verified" | "unavailable";
}
interface WorkerExecutionOptionsBase {
  readonly modelSwitch: { readonly supported: boolean };
  readonly effort: WorkerEffortOptions;
}
interface WorkerModelOptionsBase {
  readonly supported: boolean;
  readonly discovery: "profile_catalog" | "provider_catalog";
  /** A matching runtime catalog was received, even if it lists no models. */
  readonly catalogAvailable?: boolean;
  readonly allowsCustomModel: boolean;
  readonly allowedModelIds: readonly string[];
  /** null preserves provider Auto; metadata never materializes a selection. */
  readonly defaultModelId: string | null;
}
export type WorkerExecutionOptions = WorkerExecutionOptionsBase &
  (
    | {
        readonly schemaVersion: 1;
        readonly models: WorkerModelOptionsBase & {
          readonly options: readonly LegacyWorkerModelOption[];
        };
      }
    | {
        readonly schemaVersion: 2;
        readonly catalogRevision: string;
        readonly catalogStale?: boolean;
        readonly models: WorkerModelOptionsBase & {
          readonly options: readonly WorkerModelOption[];
        };
      }
  );

export function workerEffortOptionsForModel(
  options: WorkerExecutionOptions,
  modelId: string | null,
): WorkerEffortOptions {
  const model = options.models.options.find(
    (model) => model.id === (modelId ?? options.models.defaultModelId),
  );
  if (!model) return options.effort;
  if ("effort" in model) return model.effort;
  return {
    supported: model.status !== "unavailable" && model.efforts.length > 0,
    values: model.status === "unavailable" ? [] : model.efforts,
    defaultValue: model.defaultEffort,
  };
}

export function validateWorkerExecutionSelection(
  options: WorkerExecutionOptions,
  modelId: string | null,
  effort: string | null,
  catalogRevision?: string | null,
): string | null {
  if (options.schemaVersion === 2 && options.catalogStale)
    return "Worker capabilities are stale; refresh the Worker catalog";
  if (
    catalogRevision != null &&
    (options.schemaVersion !== 2 || options.catalogRevision !== catalogRevision)
  )
    return "Worker catalog changed; refresh and confirm the selection";
  if (
    options.models.discovery === "provider_catalog" &&
    options.models.options.length === 0 &&
    options.models.catalogAvailable !== true
  )
    return "Worker capabilities are unavailable; refresh the Worker catalog";
  if (
    modelId !== null &&
    (!options.models.supported ||
      (!options.models.allowsCustomModel &&
        !options.models.allowedModelIds.includes(modelId)))
  ) {
    return "The selected model is not available for this Worker Profile";
  }
  if (
    modelId === null &&
    options.models.defaultModelId === null &&
    options.models.options.some(
      (entry) => "selectionMode" in entry && entry.selectionMode === "combined",
    )
  ) {
    return "Select an explicit model for this Worker";
  }
  const model = options.models.options.find((entry) => entry.id === modelId);
  if (model && "status" in model && model.status === "unavailable") {
    return "The selected model is not available for this Worker Profile";
  }
  const supported = workerEffortOptionsForModel(options, modelId);
  if (
    model &&
    "selectionMode" in model &&
    model.selectionMode === "combined" &&
    supported.values.length > 0 &&
    supported.defaultValue === null &&
    effort === null
  )
    return "Select an explicit effort for this model";
  if (
    effort !== null &&
    (!supported.supported || !supported.values.includes(effort))
  ) {
    return "The selected effort is not available for this model and Worker Profile";
  }
  return null;
}
