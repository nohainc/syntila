import { stepInstanceId, type BuiltinWorkflowDefinition, type WorkflowExecutionBinding } from "@syntila/core";
import { dataOf } from "../../platform/data.js";
import {
  acceptWorkerTarget,
  workerEligibilityResponse,
  type WorkerEligibilityCode,
  type WorkerTargetSnapshot,
} from "../worker-eligibility.js";
import { HttpError, json, type SecurityEnv } from "./handlers.js";
import { loadSpacePermissions } from "./space-permissions.js";
import { loadSpaceWorkflowConfigurations } from "./space-workflow-configurations.js";
import { parseUserWorkflowConfiguration, resolveUserWorkflowConfiguration } from "@syntila/core";

/**
 * Binds a Worker to each Step of a Work Request (ADR-035 decisions 3 and 8).
 *
 * The request names the Worker: `workerId` for every Step, optionally
 * overridden per Step in `workerBindings` (keyed like `resolvedBindings`: the
 * step kind, `direct`, or a Research v2 step instance). Every Step goes
 * through the same server-side eligibility check and, once accepted, carries
 * its own frozen snapshot, so a later rename, Profile change or Worker removal
 * does not touch an accepted request. Offline Workers are refused here; there
 * is no queue and no substitute Worker.
 */

export interface WorkerBindingRequest {
  readonly workerId?: unknown;
  readonly model?: unknown;
  readonly reasoningEffort?: unknown;
  readonly workerBindings?: unknown;
}

interface StepChoice {
  readonly workerId: string;
  readonly model: string | null;
  readonly reasoningEffort: string | null;
}

const MAX_TEXT = 200;
const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;

function text(value: unknown, field: string): string | null {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string" || value.length > MAX_TEXT) {
    throw new HttpError(400, `${field} is invalid`);
  }
  return value.trim() || null;
}

function workerIdOf(value: unknown, field: string): string | null {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string" || !ID_PATTERN.test(value)) {
    throw new HttpError(400, `${field} is invalid`);
  }
  return value;
}

/** Whether the request asks for Worker-targeted execution. */
export function requestsWorkerTarget(body: WorkerBindingRequest): boolean {
  return (
    (typeof body.workerId === "string" && body.workerId.length > 0) ||
    (body.workerBindings !== undefined && body.workerBindings !== null)
  );
}

/** The binding ID a Step is frozen under; the same rule the Workspace path uses. */
export function stepBindingId(definition: BuiltinWorkflowDefinition, step: BuiltinWorkflowDefinition["steps"][number]): string {
  if (definition.id === "direct") return "direct";
  return definition.id === "research" && definition.version === 2 ? stepInstanceId(step) : step.kind;
}

export type WorkerBindingResult =
  | {
      readonly ok: true;
      readonly bindings: Record<string, WorkflowExecutionBinding>;
      readonly workerProfiles: Record<string, { profileId: string; profileReleaseVersion: number }>;
    }
  | { readonly ok: false; readonly response: Response };

export async function resolveWorkerTargetBindings(
  env: SecurityEnv,
  input: {
    readonly userId: string;
    readonly spaceId: string;
    readonly threadId: string;
    readonly definition: BuiltinWorkflowDefinition;
    readonly request: WorkerBindingRequest;
    readonly additionalInstructions?: Readonly<Record<string, { additionalInstructions?: string }>>;
  },
): Promise<WorkerBindingResult> {
  const { definition, request } = input;
  const overrides: Record<string, unknown> =
    request.workerBindings && typeof request.workerBindings === "object" && !Array.isArray(request.workerBindings)
      ? (request.workerBindings as Record<string, unknown>)
      : {};
  if (
    request.workerBindings !== undefined &&
    request.workerBindings !== null &&
    (typeof request.workerBindings !== "object" || Array.isArray(request.workerBindings))
  ) {
    throw new HttpError(400, "workerBindings must be an object");
  }
  // The same Space rules as the Workspace path: support Threads take messages
  // only, personal Spaces run Chat only, and a disabled Workflow stays disabled.
  const spacePolicy = await loadSpacePermissions(env, input.userId, input.spaceId);
  if (spacePolicy.isSupport) throw new HttpError(403, "Support Threads accept messages only");
  if (spacePolicy.kind === "direct" && definition.id !== "chat") {
    throw new HttpError(403, "Personal Spaces support Chat only");
  }
  const space = await loadSpaceWorkflowConfigurations(env, input.spaceId, definition.id);
  const configuration = space.configurations[0] ? parseUserWorkflowConfiguration(definition, space.configurations[0]) : undefined;
  if (!resolveUserWorkflowConfiguration(definition, configuration).enabled) {
    throw new HttpError(422, "Workflow is disabled in this Space");
  }
  const fallback: StepChoice | null = (() => {
    const workerId = workerIdOf(request.workerId, "workerId");
    return workerId
      ? { workerId, model: text(request.model, "model"), reasoningEffort: text(request.reasoningEffort, "reasoningEffort") }
      : null;
  })();

  const bindings: Record<string, WorkflowExecutionBinding> = {};
  const workerProfiles: Record<string, { profileId: string; profileReleaseVersion: number }> = {};
  const issues: TargetIssue[] = [];
  const read = dataOf(env).read;

  for (const step of definition.steps) {
    // A tool call needs a Workspace and is not available on the Worker path.
    if (step.kind === "tool_call") {
      throw new HttpError(400, "A tool call needs a Workspace; it is not available for Worker-targeted requests");
    }
    const bindingId = stepBindingId(definition, step);
    const override = overrides[bindingId];
    let choice: StepChoice | null = fallback;
    if (override !== undefined) {
      if (!override || typeof override !== "object" || Array.isArray(override)) {
        throw new HttpError(400, `workerBindings.${bindingId} is invalid`);
      }
      const value = override as Record<string, unknown>;
      const workerId = workerIdOf(value.workerId, `workerBindings.${bindingId}.workerId`);
      if (!workerId) throw new HttpError(400, `workerBindings.${bindingId}.workerId is required`);
      choice = {
        workerId,
        model: text(value.model, `workerBindings.${bindingId}.model`),
        reasoningEffort: text(value.reasoningEffort, `workerBindings.${bindingId}.reasoningEffort`),
      };
    }
    if (!choice) {
      issues.push({ stepKind: step.kind, workerTypeId: null, code: "binding_missing", message: `${step.kind}: choose a Worker` });
      continue;
    }
    const decision = await acceptWorkerTarget(read, {
      workerId: choice.workerId,
      requesterUserId: input.userId,
      spaceId: input.spaceId,
      threadId: input.threadId,
      workflowId: definition.id,
      model: choice.model,
      reasoningEffort: choice.reasoningEffort,
      readOnly: step.readWritePolicy === "read_only",
      capabilities: step.requiredCapabilities,
      requireOnline: true,
    });
    if (decision.ok === false) {
      issues.push({
        stepKind: step.kind,
        workerTypeId: null,
        code: decision.code,
        message: `${step.kind}: ${workerEligibilityResponse(decision.code).message}`,
      });
      continue;
    }
    const snapshot = decision.snapshot;
    const additional = (input.additionalInstructions?.[bindingId] ?? input.additionalInstructions?.[step.kind])?.additionalInstructions;
    bindings[bindingId] = {
      workerId: snapshot.workerId,
      ...(snapshot.model ? { model: snapshot.model } : {}),
      ...(snapshot.reasoningEffort ? { reasoningEffort: snapshot.reasoningEffort } : {}),
      ...(additional ? { additionalInstructions: additional } : {}),
      workerTarget: snapshot as unknown as Record<string, unknown>,
    };
    workerProfiles[bindingId] = {
      profileId: snapshot.profile!.definitionId!,
      profileReleaseVersion: snapshot.profile!.revision,
    };
  }

  if (issues.length === 0) return { ok: true, bindings, workerProfiles };
  return { ok: false, response: ineligibleResponse(definition, issues) };
}

interface TargetIssue {
  readonly stepKind: string;
  readonly workerTypeId: string | null;
  readonly code: WorkerEligibilityCode | "binding_missing";
  readonly message: string;
}

/** 404 unknown Worker, 403 no execute right, 409 offline only, otherwise 422. */
function ineligibleResponse(definition: BuiltinWorkflowDefinition, issues: readonly TargetIssue[]): Response {
  const codes = new Set(issues.map((issue) => issue.code));
  const offlineOnly = codes.size === 1 && codes.has("worker_offline");
  const status = codes.has("worker_not_found") ? 404 : codes.has("execute_not_permitted") ? 403 : offlineOnly ? 409 : 422;
  return json(
    {
      error: offlineOnly ? "worker_offline" : "work_request_ineligible",
      workflowId: definition.id,
      workflowName: definition.name,
      issues,
    },
    { status },
  );
}

/** The Worker a Step was frozen with at acceptance, or null on the Workspace path. */
export function frozenWorkerTarget(
  bindings: Readonly<Record<string, object | undefined>>,
  definition: BuiltinWorkflowDefinition,
  step: BuiltinWorkflowDefinition["steps"][number],
): WorkerTargetSnapshot | null {
  const target = (bindings[stepBindingId(definition, step)] as { workerTarget?: unknown } | undefined)?.workerTarget;
  return target && typeof target === "object" && !Array.isArray(target) ? (target as WorkerTargetSnapshot) : null;
}

/**
 * Eligibility again for one Step that is about to run again (a retry): the
 * same checks as acceptance against the frozen Worker, with the Worker online.
 * Returns the refusal, or null when the Step may run.
 */
export async function recheckWorkerTarget(
  env: SecurityEnv,
  input: {
    readonly userId: string;
    readonly spaceId: string;
    readonly threadId: string;
    readonly definition: BuiltinWorkflowDefinition;
    readonly step: BuiltinWorkflowDefinition["steps"][number];
    readonly target: WorkerTargetSnapshot;
  },
): Promise<Response | null> {
  const decision = await acceptWorkerTarget(dataOf(env).read, {
    workerId: input.target.workerId,
    requesterUserId: input.userId,
    spaceId: input.spaceId,
    threadId: input.threadId,
    workflowId: input.definition.id,
    model: input.target.model,
    reasoningEffort: input.target.reasoningEffort,
    readOnly: input.step.readWritePolicy === "read_only",
    capabilities: input.step.requiredCapabilities,
    requireOnline: true,
  });
  if (decision.ok === true) return null;
  return ineligibleResponse(input.definition, [
    {
      stepKind: input.step.kind,
      workerTypeId: input.target.workerTypeId,
      code: decision.code,
      message: `${input.step.kind}: ${workerEligibilityResponse(decision.code).message}`,
    },
  ]);
}
