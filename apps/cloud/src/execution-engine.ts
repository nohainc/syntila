import {
  effectiveStepTimeoutMs,
  type StepResult,
  type BuiltinWorkflowStep,
  type ThreadBindingId,
} from "@syntila/core";
import type { TaskToDispatch } from "./assignment-dispatcher.js";
import { workStepSessionKey } from "./work-session-key.js";

/** Workflow supplies what should execute. This boundary configures how the
 * selected logical Worker executes it; scheduling/Profile admission stay below. */
export interface WorkerStepExecutionInput {
  readonly taskId: string;
  readonly step: BuiltinWorkflowStep;
  readonly bindingId: ThreadBindingId;
  readonly binding: Readonly<Record<string, unknown>>;
  readonly prompt: string;
  readonly workerInput: Readonly<Record<string, unknown>>;
  readonly scope: {
    readonly spaceId: string;
    readonly spaceName?: string;
    readonly spaceOwnerUserId?: string;
    readonly requesterUserId: string;
    readonly threadId: string;
    readonly workRequestId: string;
    readonly workSessionGeneration?: number;
  };
  readonly retry: {
    readonly stepKind?: unknown;
    readonly sessionStrategy?: unknown;
    readonly number?: unknown;
    readonly adoptSpaceFolder?: boolean;
    readonly compactContext?: boolean;
  };
}

export interface WorkerStepExecution {
  readonly schemaVersion: 1;
  readonly workerId: string | undefined;
  readonly task: TaskToDispatch;
}

export function prepareWorkerStepExecution(
  input: WorkerStepExecutionInput,
): WorkerStepExecution {
  if (!input.prompt.trim()) throw new Error("Work Step prompt is empty");
  const { step, binding, scope } = input;
  const option = (value: unknown) =>
    typeof value === "string" ? value : undefined;
  return {
    schemaVersion: 1,
    workerId: option(binding.workerId),
    task: {
      id: input.taskId,
      role: step.kind,
      objective: input.prompt,
      capabilities: [...step.requiredCapabilities],
      input: {
        ...input.workerInput,
        prompt: input.prompt,
        effectiveWorkerPrompt: input.prompt,
      },
      timeoutMs: effectiveStepTimeoutMs(step.timeoutMs),
      sessionPolicy: "durable_session",
      sessionKey: workStepSessionKey({
        workBindingId: input.bindingId,
        threadId: scope.threadId,
        workRequestId: scope.workRequestId,
        stepKind: step.kind,
        retryStepKind: input.retry.stepKind,
        retrySessionStrategy: input.retry.sessionStrategy,
        retryNumber: input.retry.number,
        workSessionGeneration: scope.workSessionGeneration,
      }),
      spaceId: scope.spaceId,
      ...(scope.spaceName ? { spaceName: scope.spaceName } : {}),
      ...(scope.spaceOwnerUserId
        ? { spaceOwnerUserId: scope.spaceOwnerUserId }
        : {}),
      ...(input.retry.adoptSpaceFolder === true
        ? { spaceFolderAdoptionConfirmed: true }
        : {}),
      ...(input.retry.compactContext === true
        ? { contextCompaction: true }
        : {}),
      requestedByUserId: scope.requesterUserId,
      threadId: scope.threadId,
      workRequestId: scope.workRequestId,
      workBindingId: input.bindingId,
      executionClass: step.executionMode,
      readOnly: step.readWritePolicy === "read_only",
      model: option(binding.model),
      reasoningEffort: option(binding.reasoningEffort),
    },
  };
}

/** Translate admitted execution evidence into the generic result a Workflow uses. */
export function completeWorkerStepExecution(input: {
  readonly output: Readonly<Record<string, unknown>>;
  readonly evidence: Readonly<Record<string, unknown>>;
  readonly attribution: Pick<
    StepResult,
    "workerId" | "workerTypeId" | "engineVersion" | "model"
  >;
  readonly startedAt: string;
  readonly completedAt: string;
  readonly configuredEffort: unknown;
}): StepResult {
  const { output, evidence } = input;
  const nested =
    typeof output.output === "object" && output.output !== null
      ? (output.output as Record<string, unknown>)
      : output;
  const text =
    typeof nested.text === "string"
      ? nested.text
      : typeof nested.finalAnswer === "string"
        ? nested.finalAnswer
        : typeof nested.summary === "string"
          ? nested.summary
          : null;
  if (!text?.trim())
    throw new Error("Work Step completed without final answer text");
  return {
    ...input.attribution,
    text: text.slice(0, 96_000),
    status: "completed",
    startedAt: input.startedAt,
    completedAt: input.completedAt,
    engineVersion:
      typeof evidence.profileDefinitionId === "string"
        ? input.attribution.engineVersion
        : null,
    profileDefinitionId:
      typeof evidence.profileDefinitionId === "string"
        ? evidence.profileDefinitionId
        : null,
    profileReleaseVersion:
      Number.isSafeInteger(evidence.profileReleaseVersion) &&
      Number(evidence.profileReleaseVersion) > 0
        ? Number(evidence.profileReleaseVersion)
        : null,
    providerToolVersion:
      typeof evidence.providerToolVersion === "string"
        ? evidence.providerToolVersion
        : null,
    reasoningEffort:
      typeof evidence.reasoningEffort === "string"
        ? evidence.reasoningEffort
        : typeof input.configuredEffort === "string"
          ? input.configuredEffort
          : null,
  };
}
