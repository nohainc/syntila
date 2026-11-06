import { DomainInvariantError } from "./domain-error.js";
import {
  RESEARCH_RESEARCHER_LIMITS,
  researchWorkflowV2,
  stepInstanceId,
  type BuiltinWorkflowDefinition,
  type WorkflowId,
} from "./thread.js";

/** Worker is explicit when present; model and effort may be Auto/omitted. */
export interface WorkflowSelection {
  readonly worker?: string;
  readonly model?: string;
  readonly effort?: string;
  readonly catalogRevision?: string;
  /**
   * Local MCP server IDs this Step may expose to its Worker. Absent means the
   * Workspace's own Worker-type bindings decide; an empty list exposes none.
   * Names only: the Workspace still requires consent, enablement and a binding.
   */
  readonly mcpTools?: readonly string[];
}
/** Server IDs as the Workspace registry accepts them. */
export const MCP_TOOLS_LIMIT = 8;
const MCP_SERVER_ID = /^[a-z0-9][a-z0-9_-]{0,63}$/;
/**
 * Overrides are keyed by step-instance ID: the kind for definitions that
 * never repeat a kind, `research-1..n` and `synthesis` for Research v2.
 * Schema version 2 exists only for Research and adds `researcherCount`.
 */
export interface UserWorkflowConfiguration {
  readonly schemaVersion: 1 | 2;
  readonly workflowId: WorkflowId;
  readonly enabled: boolean;
  /** Research v2 only (schema version 2): independent researchers to run. */
  readonly researcherCount?: number;
  readonly defaults: WorkflowSelection;
  readonly stepOverrides: Readonly<Partial<Record<string, WorkflowSelection>>>;
}
export interface EffectiveWorkflowConfiguration {
  readonly definition: BuiltinWorkflowDefinition;
  readonly enabled: boolean;
  /** Effective selection per step-instance ID. */
  readonly steps: Readonly<Partial<Record<string, WorkflowSelection>>>;
}

/**
 * The Research definition a stored configuration asks for: Research v2 with
 * its configured researcher count (default two). Any other workflow keeps the
 * definition it is given.
 */
export function configuredWorkflowDefinition(
  definition: BuiltinWorkflowDefinition,
  stored: unknown,
): BuiltinWorkflowDefinition {
  if (definition.id !== "research" || definition.version !== 2)
    return definition;
  const count =
    stored &&
    typeof stored === "object" &&
    (stored as { schemaVersion?: unknown }).schemaVersion === 2
      ? (stored as { researcherCount?: unknown }).researcherCount
      : RESEARCH_RESEARCHER_LIMITS.default;
  return researchWorkflowV2(
    typeof count === "number" ? count : RESEARCH_RESEARCHER_LIMITS.default,
  );
}

/** A pure overlay boundary; execution authorization/readiness remains separate. */
export function resolveUserWorkflowConfiguration(
  definition: BuiltinWorkflowDefinition,
  configuration?: UserWorkflowConfiguration,
): EffectiveWorkflowConfiguration {
  if (configuration && configuration.workflowId !== definition.id)
    throw new DomainInvariantError("Workflow configuration identity mismatch");
  return {
    definition,
    enabled: configuration?.enabled ?? true,
    steps: Object.fromEntries(
      definition.steps.map((step) => {
        const id = stepInstanceId(step);
        const override = configuration?.stepOverrides[id];
        return [
          id,
          {
            ...configuration?.defaults,
            ...override,
            ...(override?.worker !== undefined &&
            override.worker !== configuration!.defaults.worker &&
            override.catalogRevision === undefined
              ? { catalogRevision: undefined }
              : {}),
          },
        ];
      }),
    ),
  };
}

/** Strict versioned write boundary. null/Auto normalize to omission for model/effort. */
export function parseUserWorkflowConfiguration(
  definition: BuiltinWorkflowDefinition,
  input: unknown,
): UserWorkflowConfiguration {
  const object = (value: unknown): Record<string, unknown> => {
    if (!value || typeof value !== "object" || Array.isArray(value))
      throw new DomainInvariantError("Expected configuration object");
    return value as Record<string, unknown>;
  };
  const keys = (value: Record<string, unknown>, allowed: readonly string[]) => {
    if (Object.keys(value).some((key) => !allowed.includes(key)))
      throw new DomainInvariantError("Unknown configuration field");
  };
  const selection = (input: unknown): WorkflowSelection => {
    const value = object(input);
    keys(value, ["worker", "model", "effort", "catalogRevision", "mcpTools"]);
    const result: Record<string, string | readonly string[]> = {};
    if (value.mcpTools !== undefined && value.mcpTools !== null) {
      const tools = value.mcpTools;
      if (
        !Array.isArray(tools) ||
        tools.length > MCP_TOOLS_LIMIT ||
        tools.some((id) => typeof id !== "string" || !MCP_SERVER_ID.test(id)) ||
        new Set(tools).size !== tools.length
      )
        throw new DomainInvariantError("Invalid mcpTools selection");
      result.mcpTools = [...(tools as string[])];
    }
    for (const key of [
      "worker",
      "model",
      "effort",
      "catalogRevision",
    ] as const) {
      const choice = value[key];
      if (choice === undefined || choice === null) continue;
      if (choice === "Auto" || choice === "Automatic") {
        if (key === "worker" || key === "catalogRevision")
          throw new DomainInvariantError("Worker must be selected explicitly");
        if (choice === "Automatic")
          throw new DomainInvariantError(
            "Use Auto for model and effort defaults",
          );
        continue;
      }
      if (typeof choice !== "string" || !choice.trim() || choice.length > 200)
        throw new DomainInvariantError(`Invalid ${key} selection`);
      if (key === "catalogRevision" && !/^[a-f0-9]{64}$/.test(choice))
        throw new DomainInvariantError("Invalid catalog revision");
      result[key] = choice.trim();
    }
    return result as WorkflowSelection;
  };
  const value = object(input);
  const researchV2 = value.schemaVersion === 2;
  keys(value, [
    "schemaVersion",
    "workflowId",
    "enabled",
    "defaults",
    "stepOverrides",
    ...(researchV2 ? ["researcherCount"] : []),
  ]);
  if (
    (value.schemaVersion !== 1 && !researchV2) ||
    (researchV2 && definition.id !== "research") ||
    value.workflowId !== definition.id ||
    typeof value.enabled !== "boolean"
  )
    throw new DomainInvariantError(
      "Invalid configuration version, identity or enabled flag",
    );
  const researcherCount = researchV2
    ? (value.researcherCount ?? RESEARCH_RESEARCHER_LIMITS.default)
    : undefined;
  if (
    researcherCount !== undefined &&
    (typeof researcherCount !== "number" ||
      !Number.isInteger(researcherCount) ||
      researcherCount < RESEARCH_RESEARCHER_LIMITS.min ||
      researcherCount > RESEARCH_RESEARCHER_LIMITS.max)
  )
    throw new DomainInvariantError(
      `Research needs ${RESEARCH_RESEARCHER_LIMITS.min} to ${RESEARCH_RESEARCHER_LIMITS.max} researchers`,
    );
  // Version 2 configures Research v2 roles; older Research configuration keeps
  // its single `research` step.
  const shape =
    researcherCount !== undefined
      ? researchWorkflowV2(researcherCount)
      : definition;
  const overrides = object(value.stepOverrides ?? {});
  // Version 1 keys overrides by kind (its historical meaning).
  keys(
    overrides,
    researchV2
      ? shape.steps.map(stepInstanceId)
      : [...new Set(shape.steps.map((step) => step.kind))],
  );
  return {
    schemaVersion: researchV2 ? 2 : 1,
    workflowId: definition.id,
    enabled: value.enabled,
    ...(researcherCount !== undefined ? { researcherCount } : {}),
    defaults: selection(value.defaults ?? {}),
    stepOverrides: Object.fromEntries(
      Object.entries(overrides)
        .map(([id, value]) => [id, selection(value)] as const)
        .filter(([, value]) => Object.keys(value).length > 0),
    ),
  };
}
