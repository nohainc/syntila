import { WorkRequestBodySchema } from "@syntila/protocol";
import { paidOwnerSql } from "../account-plan.js";
import { readBody } from "./validation.js";
import { usersBlocked } from "../queries.js";
import { loadSpaceWorkflowConfigurations } from "./space-workflow-configurations.js";
import {
  FileTooLargeError,
  StorageQuotaExceededError,
  getAttachmentLimits,
} from "../account-plan.js";
import { requireWorkflowPermission } from "./space-permissions.js";
import { insertInitialConversationTasks } from "./conversation-workflow-step-runs.js";
import { MutationIdempotency, NO_RECEIPT, type ReceiptWrite } from "./mutation-idempotency.js";
import { resolveWorkflowStepExecutionConfig } from "./workflow-step-execution-config.js";
import {
  insertConversationSubmission,
  resolveThreadConversationId,
} from "./conversations.js";
import {
  validateWorkRequest,
  validateBuiltinWorkflowDefinition,
  BUILTIN_WORKFLOWS,
  BUILTIN_WORKFLOW_CATALOG,
  CONVERSATION_WORKFLOWS,
  configuredWorkflowDefinition,
  stepInstanceId,
  researchWorkflowV2,
  RESEARCH_RESEARCHER_LIMITS,
  conversationWorkflowForExecution,
  type WorkRequest,
  type WorkRequestSnapshot,
  type BuiltinWorkflowDefinition,
  type WorkflowId,
} from "@syntila/core";

import {
  MAX_WORK_REQUEST_FILES,
  isWorkRequestFileId,
  userStorageUsage,
  verifyWorkRequestFile,
  workRequestFileName,
} from "./work-request-files.js";
import { insertWorkRequestInputs } from "./work-request-inputs.js";
import { resolveReplyReference } from "./reply-references.js";
import { createEventPublisher } from "../event-publisher.js";
import { tryLogTraceEvent } from "../observability.js";
import {
  HttpError,
  authorizeThreadAccess,
  errorMessage,
  json,
  parseJson,
  requiredString,
  resolveWorkflowInstanceId,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import type { SyntilaWorkflowParams } from "../workflow.js";
import { dataOf, type Tx } from "../../platform/data.js";
import { requestsWorkerTarget, resolveWorkerTargetBindings } from "./worker-target-bindings.js";
import { requireSpaceFolder } from "./device-folders.js";

/** Lists owned Workers that can currently run every step of a Workflow. */
export async function handleListEligibleWorkers(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, spaceId } = await authorizeThreadAccess(request, env, threadId, "execute", accessContext);
  const workflowId = (new URL(request.url).searchParams.get("workflowId") ?? "chat") as WorkflowId;
  if (!Object.hasOwn(BUILTIN_WORKFLOWS, workflowId)) throw new HttpError(400, "Unsupported workflowId");
  const workflow = BUILTIN_WORKFLOWS[workflowId];
  if (!workflow) throw new HttpError(400, "Unsupported workflowId");
  await requireWorkflowPermission(env, context.userId, spaceId, workflowId);
  const q = dataOf(env).read;
  const workers = await q.rows<{ id: string }>`SELECT w.id FROM worker_instances w
    WHERE w.revoked_at IS NULL
      AND (
        w.owner_user_id = ${context.userId}
        OR w.owner_user_id = (SELECT s.owner_user_id FROM spaces s WHERE s.id = ${spaceId})
        OR (${q.raw(paidOwnerSql("w.owner_user_id"))} AND EXISTS (SELECT 1 FROM worker_person_shares wps
                    WHERE wps.worker_id = w.id AND wps.user_id = ${context.userId}))
        OR (${q.raw(paidOwnerSql("w.owner_user_id"))} AND EXISTS (
          SELECT 1 FROM worker_space_members wsm
           WHERE wsm.worker_id = w.id
             AND wsm.space_id = ${spaceId}
             AND wsm.user_id = ${context.userId}
             AND wsm.enabled = true
        ))
      )
    ORDER BY w.created_at, w.id`;
  const eligible: string[] = [];
  for (const worker of workers) {
    const result = await resolveWorkerTargetBindings(env, {
      userId: context.userId, spaceId, threadId, definition: workflow,
      request: { workerId: worker.id },
    });
    if (result.ok) eligible.push(worker.id);
  }
  return json({ workflowId, workerIds: eligible });
}

export async function createOrGetRun(
  env: Env,
  params: SyntilaWorkflowParams,
): Promise<{ id: string; status: unknown }> {
  const id = await resolveWorkflowInstanceId(
    env,
    params.runId,
    params.idempotencyKey,
  );
  try {
    const instance = await env.SYNTILA_RUN_WORKFLOW.create({ id, params });
    return { id: params.runId, status: (await instance.status()).status };
  } catch (error) {
    if (!errorMessage(error).toLowerCase().includes("exist")) throw error;
    const instance = await env.SYNTILA_RUN_WORKFLOW.get(id);
    return { id: params.runId, status: (await instance.status()).status };
  }
}

export async function handleValidateWorkRequest(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "execute",
    accessContext,
  );
  const row = await dataOf(env).read.row<{ configJson: string | null }>`SELECT wc.config_json AS "configJson" FROM threads ws
       LEFT JOIN thread_work_configs wc ON wc.thread_id = ws.id WHERE ws.id = ${threadId}`;
  const config = parseJson<Record<string, unknown>>(row?.configJson, {
    defaultWorkflowId: "direct",
    bindings: {},
  });
  const body = await readBody(request, WorkRequestBodySchema);
  const workerRequest = { workerId: body.workerId, workerBindings: body.workerBindings, model: body.model, reasoningEffort: body.reasoningEffort };
  const workflowId = requiredString(
    body.workflowId ?? config.defaultWorkflowId,
    "workflowId",
  ) as WorkflowId;
  const builtin = BUILTIN_WORKFLOWS[workflowId];
  if (!builtin) throw new HttpError(400, "Unsupported workflowId");
  // The same definition the request will run, so a Research request with its
  // own researcher count is checked against every researcher it will start.
  const researcherCount = requestedResearcherCount(body.researcherCount);
  const workflow =
    workflowId !== "research"
      ? builtin
      : researcherCount !== undefined
        ? researchWorkflowV2(researcherCount)
        : configuredWorkflowDefinition(
            builtin,
            (await loadSpaceWorkflowConfigurations(env, spaceId, "research"))
              .configurations[0],
          );
  await requireWorkflowPermission(env, context.userId, spaceId, workflowId);
  if (body.attachments !== undefined && !Array.isArray(body.attachments)) {
    throw new HttpError(400, "attachments must be an array");
  }
  const attachments = Array.isArray(body.attachments) ? body.attachments : [];
  if (attachments.length > MAX_WORK_REQUEST_FILES)
    throw new HttpError(400, "At most 10 attachments are allowed");
  if (!requestsWorkerTarget(workerRequest))
    throw new HttpError(400, "workerId is required");
  if (body.executionSelection !== undefined)
    throw new HttpError(400, "executionSelection is not supported; name a workerId");
  const result = await resolveWorkerTargetBindings(env, {
    userId: context.userId, spaceId, threadId, definition: workflow, request: workerRequest,
  });
  if (result.ok === false) {
    const refusal = await result.response.json() as { issues: unknown[] };
    return json({ eligible: false, workflowId, workflowName: workflow.name, issues: refusal.issues });
  }
  return json({ eligible: true, workflowId, workflowName: workflow.name, issues: [] });
}

/**
 * Research only: the researcher count the user chose for this request instead
 * of the Space's configured one. Undefined when none was sent.
 */
function requestedResearcherCount(value: unknown): number | undefined {
  if (value === undefined || value === null) return undefined;
  if (
    typeof value !== "number" ||
    !Number.isInteger(value) ||
    value < RESEARCH_RESEARCHER_LIMITS.min ||
    value > RESEARCH_RESEARCHER_LIMITS.max
  )
    throw new HttpError(
      400,
      `researcherCount must be ${RESEARCH_RESEARCHER_LIMITS.min} to ${RESEARCH_RESEARCHER_LIMITS.max}`,
    );
  return value;
}

export async function handleCreateWorkRequest(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const handlerStartedAt = performance.now();
  const { context, spaceId, thread } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "execute",
    accessContext,
  );
  if (thread?.status === "archived")
    throw new HttpError(
      409,
      "Restore the Thread before sending messages or requests",
    );
  const body = await readBody(request, WorkRequestBodySchema);
  const receipt = await MutationIdempotency.from(
    request,
    env.SYNTILA_DB,
    context.userId,
    `thread:${threadId}:create-work-request`,
    body,
  );
  return createWorkRequestForUser(env, {
    userId: context.userId,
    spaceId,
    threadId,
    body,
    receipt,
    replay: (await receipt?.replay()) ?? null,
    submissionId: request.headers.get("Idempotency-Key"),
    startedAt: handlerStartedAt,
  });
}

/**
 * Validates and accepts a Work request authored by [userId], whose access the
 * caller has already checked. Used by the composer's HTTP request and by the
 * Thread request queue, which sends a queued request as its author.
 */
export async function createWorkRequestForUser(
  env: SecurityEnv,
  {
    userId,
    spaceId,
    threadId,
    body,
    receipt = null,
    replay = null,
    submissionId = null,
    startedAt = performance.now(),
  }: {
    userId: string;
    spaceId: string;
    threadId: string;
    body: Record<string, unknown>;
    receipt?: MutationIdempotency | null;
    replay?: Response | null;
    submissionId?: string | null;
    startedAt?: number;
  },
): Promise<Response> {
  const handlerStartedAt = startedAt;
  const context = { userId };
  const directSpace = await dataOf(env).read.row<{ status: string | null; userLowId: string; userHighId: string }>`SELECT pc.status, ds.user_low_id AS "userLowId", ds.user_high_id AS "userHighId"
     FROM direct_spaces ds
     LEFT JOIN person_connections pc ON pc.user_low_id = ds.user_low_id AND pc.user_high_id = ds.user_high_id
     WHERE ds.space_id = ${spaceId}`.catch(() => null);
  if (directSpace) {
    const isBlocked = await usersBlocked(dataOf(env).read, directSpace.userLowId, directSpace.userHighId);
    if (isBlocked) {
      throw new HttpError(403, "Messaging is blocked between participants");
    }
    if (directSpace.status !== "connected") {
      throw new HttpError(
        403,
        "This personal conversation is disconnected and read-only",
      );
    }
  }
  const requestedMode =
    body.mode === "stateful"
      ? "stateful"
      : body.mode === "stateless"
        ? "stateless"
        : null;
  const workConfigRow = await dataOf(env).read.row<{ configJson: string | null; settingsJson: string | null }>`SELECT wc.config_json AS "configJson", p.settings_json AS "settingsJson"
     FROM threads ws
     JOIN spaces p ON p.id = ws.space_id
     LEFT JOIN thread_work_configs wc ON wc.thread_id = ws.id
     WHERE ws.id = ${threadId}`;
  const workConfig = parseJson<Record<string, unknown>>(
    workConfigRow?.configJson,
    { defaultWorkflowId: "direct", bindings: {} },
  );
  const workflowId = requiredString(
    body.workflowId ?? workConfig.defaultWorkflowId,
    "workflowId",
  ) as WorkflowId;
  if (!BUILTIN_WORKFLOWS[workflowId])
    throw new HttpError(400, "Unsupported workflowId");
  // Research takes its researcher count from the Space configuration; the
  // accepted snapshot freezes it.
  // MCP tool calls (`input.toolCall`) are not available yet: they will run on
  // Connect under their own decision.
  if (
    body.input !== null &&
    typeof body.input === "object" &&
    !Array.isArray(body.input) &&
    (body.input as Record<string, unknown>).toolCall !== undefined
  )
    throw new HttpError(400, "Tool calls are not available yet");
  const researcherCount = requestedResearcherCount(body.researcherCount);
  const canonicalWorkflow =
    workflowId === "research"
      ? researcherCount !== undefined
        ? researchWorkflowV2(researcherCount)
        : configuredWorkflowDefinition(
            BUILTIN_WORKFLOWS.research,
            (await loadSpaceWorkflowConfigurations(env, spaceId, "research"))
              .configurations[0],
          )
      : BUILTIN_WORKFLOWS[workflowId];
  // A replay returns the request already accepted under the plan at that
  // time; it creates no execution, so it is not re-gated on the plan.
  await requireWorkflowPermission(env, context.userId, spaceId, workflowId, {
    entitlement: !replay,
  });
  if (replay) return resumeSubmission(env, replay);
  // Mutation coordination follows the authoritative Steps, independently of
  // durable provider conversation/session state.
  const mode = canonicalWorkflow.steps.some(
    (step) => step.executionMode === "stateful_thread",
  )
    ? "stateful"
    : "stateless";
  if (requestedMode && requestedMode !== mode) {
    throw new HttpError(
      400,
      `The ${workflowId} Workflow requires ${mode} mode`,
    );
  }
  const workflowVersion = Number(
    body.workflowVersion ?? canonicalWorkflow.version,
  );
  if (!Number.isInteger(workflowVersion) || workflowVersion < 1)
    throw new HttpError(400, "workflowVersion must be a positive integer");
  const snapshotValue = body.workflowSnapshot ?? canonicalWorkflow;
  if (!snapshotValue || typeof snapshotValue !== "object")
    throw new HttpError(400, "workflowSnapshot is invalid");
  const workflowSnapshot = snapshotValue as BuiltinWorkflowDefinition;
  try {
    validateBuiltinWorkflowDefinition(workflowSnapshot);
    if (
      workflowSnapshot.id !== workflowId ||
      workflowSnapshot.version !== workflowVersion
    )
      throw new Error(
        "Workflow snapshot does not match the selected built-in version",
      );
  } catch (error) {
    throw new HttpError(
      400,
      error instanceof Error ? error.message : "Invalid built-in Workflow",
    );
  }
  const submittedInput =
    body.input && typeof body.input === "object" && !Array.isArray(body.input)
      ? (body.input as Record<string, unknown>)
      : {};
  const originalRequest =
    [
      submittedInput.originalRequest,
      submittedInput.request,
      submittedInput.objective,
      body.originalRequest,
      body.request,
      body.objective,
    ].find(
      (value): value is string =>
        typeof value === "string" && value.trim().length > 0,
    ) ?? "";
  const requestInput: Record<string, unknown> = {
    ...submittedInput,
    originalRequest:
      typeof submittedInput.originalRequest === "string"
        ? submittedInput.originalRequest
        : originalRequest,
  };
  const submittedAttachments = submittedInput.attachments ?? body.attachments;
  if (
    submittedAttachments !== undefined &&
    !Array.isArray(submittedAttachments)
  ) {
    throw new HttpError(400, "attachments must be an array");
  }
  const rawAttachments = Array.isArray(submittedAttachments)
    ? submittedAttachments
    : [];
  if (rawAttachments.length > MAX_WORK_REQUEST_FILES)
    throw new HttpError(400, "At most 10 attachments are allowed");
  // The requester is the uploader: their plan sets the file and storage limits.
  const attachmentLimits = await getAttachmentLimits(
    env as unknown as Env,
    context.userId,
  );
  const normalizedAttachments = await Promise.all(
    rawAttachments.map(async (attachment, index) => {
      if (
        !attachment ||
        typeof attachment !== "object" ||
        Array.isArray(attachment)
      )
        throw new HttpError(400, `Attachment ${index + 1} is invalid`);
      const value = attachment as Record<string, unknown>;
      const kind =
        value.kind === "url" ? "url" : value.kind === "file" ? "file" : null;
      const name = workRequestFileName(value.name);
      const mediaType =
        typeof value.mediaType === "string" && value.mediaType.length <= 128
          ? value.mediaType
          : "application/octet-stream";
      if (!kind)
        throw new HttpError(
          400,
          `Attachment ${index + 1} has an unsupported type`,
        );
      if (kind === "url") {
        if (typeof value.url !== "string" || value.url.length > 2048)
          throw new HttpError(400, `Link ${index + 1} is invalid`);
        let url: URL;
        try {
          url = new URL(value.url);
        } catch {
          throw new HttpError(400, `Link ${index + 1} is invalid`);
        }
        if (
          (url.protocol !== "http:" && url.protocol !== "https:") ||
          url.username ||
          url.password
        )
          throw new HttpError(
            400,
            `Link ${index + 1} must be an http or https URL without embedded credentials`,
          );
        return {
          kind,
          name,
          mediaType: "text/uri-list",
          sizeBytes: 0,
          url: url.toString(),
        };
      }
      if (
        typeof value.sizeBytes !== "number" ||
        !Number.isSafeInteger(value.sizeBytes) ||
        value.sizeBytes < 0
      )
        throw new HttpError(400, `File ${index + 1} has an invalid size`);
      // A file already stored may be referenced whatever the current plan;
      // only a file still to be uploaded is held to the uploader's limit.
      if (
        value.fileId === undefined &&
        value.sizeBytes > attachmentLimits.fileBytes
      )
        throw new FileTooLargeError(attachmentLimits);
      // Input Delivery v1: the file is uploaded after acceptance. Cloud
      // assigns its identity; the manifest row tracks upload and delivery.
      if (value.fileId === undefined && value.delivery === "upload") {
        return {
          kind,
          name,
          mediaType,
          sizeBytes: value.sizeBytes,
          fileId: `wrf-${crypto.randomUUID()}`,
        };
      }
      if (!isWorkRequestFileId(value.fileId))
        throw new HttpError(400, `File ${index + 1} is invalid`);
      const stored = await verifyWorkRequestFile(
        env,
        value.fileId,
        threadId,
        context.userId,
        value.sizeBytes,
      );
      return {
        kind,
        name,
        mediaType,
        sizeBytes: value.sizeBytes,
        fileId: value.fileId,
        contentDigest: stored.digest,
        ...(stored.previewImage ? { previewImage: stored.previewImage } : {}),
        ...(stored.previewText ? { previewText: stored.previewText } : {}),
      };
    }),
  );
  requestInput.attachments = normalizedAttachments;
  // Reply v1: only a server-built snapshot of a target in this Thread.
  const replyTo = await resolveReplyReference(
    env.SYNTILA_DB,
    threadId,
    submittedInput.replyTo ?? body.replyTo,
  );
  if (replyTo) requestInput.replyTo = replyTo;
  else delete requestInput.replyTo;
  const pendingBytes = normalizedAttachments.reduce(
    (total, attachment) =>
      attachment.kind === "file" && !("contentDigest" in attachment)
        ? total + attachment.sizeBytes
        : total,
    0,
  );
  if (pendingBytes > 0) {
    // Early, non-binding check against the uploader's own allowance; the
    // upload itself reserves storage atomically.
    const usage = await userStorageUsage(env, context.userId);
    if (usage.usedBytes + usage.reservedBytes + pendingBytes > usage.quotaBytes)
      throw new StorageQuotaExceededError(attachmentLimits);
  }
  const attachmentReferences = normalizedAttachments;
  const configuredBindings =
    workConfig.bindings &&
    typeof workConfig.bindings === "object" &&
    !Array.isArray(workConfig.bindings)
      ? (workConfig.bindings as Record<string, unknown>)
      : {};
  const stepAdditionalInstructions: WorkRequestSnapshot["stepAdditionalInstructions"] =
    {};
  const promptProfileVersions: WorkRequestSnapshot["promptProfileVersions"] =
    {};
  const instructions: Record<string, { additionalInstructions?: string }> = {};
  for (const step of workflowSnapshot.steps) {
    const id = workflowId === "direct" ? "direct" : step.kind;
    const binding = configuredBindings[id] as
      Record<string, unknown> | undefined;
    if (typeof binding?.additionalInstructions === "string") {
      instructions[id] = {
        additionalInstructions: binding.additionalInstructions,
      };
      stepAdditionalInstructions[step.kind] = binding.additionalInstructions;
    }
    promptProfileVersions[step.kind] = step.promptProfileVersion;
  }
  // ADR-035: every request names the Worker that runs it.
  if (!requestsWorkerTarget(body))
    throw new HttpError(400, "workerId is required");
  if (body.executionSelection !== undefined)
    throw new HttpError(400, "executionSelection is not supported; name a workerId");
  if (mode !== "stateless")
    await requireSpaceFolder(env, spaceId, typeof body.workerId === "string" ? body.workerId : undefined);
  const workerBound = await resolveWorkerTargetBindings(env, {
    userId: context.userId,
    spaceId,
    threadId,
    definition: workflowSnapshot,
    request: body,
    additionalInstructions: instructions,
  });
  if (workerBound.ok === false) return workerBound.response;
  const accepted = workerBound;
  // ADR-040: one Worker Instance holds a stateful request's Thread lease, so
  // every Step must run on that one Worker (its Space folder is the checkout).
  const statefulWorkerIds = mode === "stateful" ? [...new Set(Object.values(accepted.bindings).map((binding) => binding.workerId))] : [];
  if (statefulWorkerIds.length > 1)
    throw new HttpError(422, "stateful_single_worker: every Step of stateful Work must run on the same Worker");
  const primaryWorkerInstanceId = statefulWorkerIds[0] ?? null;
  const resolvedBindings = accepted.bindings;
  const eligibility = { workerProfiles: accepted.workerProfiles };
  if (!env.SYNTILA_THREAD_COORDINATOR && mode === "stateful") {
    throw new HttpError(503, "Thread runtime coordination is unavailable");
  }
  const spaceSettings = parseJson<Record<string, unknown>>(
    workConfigRow?.settingsJson,
    {},
  );
  const spaceInstructions =
    typeof spaceSettings.instructions === "string"
      ? spaceSettings.instructions
      : "";
  const threadInstructions =
    typeof workConfig.threadInstructions === "string"
      ? workConfig.threadInstructions
      : "";
  const manualWorkflow = conversationWorkflowForExecution(
    workflowId,
    workflowVersion,
  );
  const manualBindingId =
    manualWorkflow?.execution.workflowId === "direct" ? "direct" : "chat";
  const manualBinding = resolvedBindings[manualBindingId];
  const executionConfig = manualWorkflow
    ? resolveWorkflowStepExecutionConfig(
        workflowSnapshot,
        manualBinding?.workerId ?? "",
        eligibility.workerProfiles?.[manualBindingId],
        manualBinding?.model ?? null,
        manualBinding?.reasoningEffort ?? null,
      )
    : undefined;
  const stepExecutionConfigs: Record<
    string,
    import("@syntila/core").TurnExecutionConfig
  > = {};
  for (const step of workflowSnapshot.steps) {
    // A tool call has no Worker, model or execution config.
    if (step.kind === "tool_call") continue;
    // Research v2 roles are bound and frozen per step instance.
    const bindingId =
      workflowId === "direct"
        ? "direct"
        : stepInstanceId(step) in resolvedBindings
          ? stepInstanceId(step)
          : step.kind;
    const binding =
      resolvedBindings[bindingId as keyof typeof resolvedBindings]!;
    stepExecutionConfigs[stepInstanceId(step)] =
      resolveWorkflowStepExecutionConfig(
        workflowSnapshot,
        binding.workerId ?? "",
        eligibility.workerProfiles[bindingId],
        binding.model ?? null,
        binding.reasoningEffort ?? null,
      );
  }
  const snapshot: WorkRequestSnapshot = {
    ...(executionConfig ? { turnExecutionConfig: executionConfig } : {}),
    schemaVersion: 1,
    stepExecutionConfigs,
    originalRequest,
    attachmentReferences,
    workflowId,
    workflowVersion,
    workflowSnapshot,
    resolvedBindings,
    spaceInstructions,
    threadInstructions,
    stepAdditionalInstructions,
    promptProfileVersions,
  };
  const now = new Date().toISOString();
  const conversationWorkflow =
    conversationWorkflowForExecution(workflowId, workflowVersion) ??
    ((workflowId === "research" || workflowId === "chat") &&
    workflowVersion === 2
      ? // Conversation identity predates graph workflows and its persisted
        // anchor accepts only chat/work. The request and Workflow Run retain
        // their actual Research identity and version.
        CONVERSATION_WORKFLOWS.chat!
      : // The Implement planner must see the Thread's earlier discussion, and
        // its plan must stay in AI history for the phases it queues.
        workflowId === "plan_implement" && workflowVersion === 2
        ? CONVERSATION_WORKFLOWS.work!
        : null);
  const selectedConversationId = conversationWorkflow
    ? await resolveThreadConversationId(env.SYNTILA_DB, threadId)
    : undefined;
  if (
    body.conversationId !== undefined &&
    body.conversationId !== selectedConversationId
  ) {
    throw new HttpError(400, "Conversation does not match this Thread");
  }
  const workRequest: WorkRequest = {
    id: `work-request-${crypto.randomUUID()}`,
    ...(selectedConversationId
      ? { conversationId: selectedConversationId }
      : {}),
    ...(executionConfig ? { executionConfig } : {}),
    threadId,
    requestedByUserId: context.userId,
    mode,
    workflowId,
    workflowVersion,
    workflowSnapshot,
    snapshot,
    status: "queued",
    input: requestInput,
    createdAt: now,
    updatedAt: now,
  };
  try {
    validateWorkRequest(workRequest);
  } catch (error) {
    throw new HttpError(
      400,
      error instanceof Error ? error.message : "Invalid Work Request",
    );
  }
  const fileInputs = normalizedAttachments.some(
    (attachment) => attachment.kind === "file",
  );
  const runId = `run-${crypto.randomUUID()}`;
  const responseBody = {
    workRequest,
    run: { id: runId, spaceId, threadId, status: "created" },
  };
  const writeRequest = async (tx: Tx) => {
    await tx.run`INSERT INTO work_requests
       (id, thread_id, requested_by_user_id, mode, workflow_id, workflow_version, workflow_snapshot_json, snapshot_json, status, primary_worker_instance_id, input_json, created_at, updated_at)
       VALUES (${workRequest.id}, ${threadId}, ${context.userId}, ${mode}, ${workflowId}, ${workflowVersion}, ${JSON.stringify(workflowSnapshot)}, ${JSON.stringify(snapshot)}, 'queued', ${primaryWorkerInstanceId}, ${JSON.stringify(workRequest.input)}, ${now}, ${now})`;
    if (fileInputs)
      await insertWorkRequestInputs(tx, {
        workRequestId: workRequest.id,
        threadId,
        userId: context.userId,
        attachments: normalizedAttachments,
        now,
      });
    // Sidebar ordering is based on these parent timestamps. A newly
    // accepted request is Thread activity even before a Worker responds.
    await tx.run`UPDATE threads SET updated_at = ${now} WHERE id = ${threadId}`;
    await tx.run`UPDATE spaces SET updated_at = ${now} WHERE id = ${spaceId}`;
    if (conversationWorkflow) {
      await insertConversationSubmission(
        tx,
        selectedConversationId!,
        threadId,
        conversationWorkflow,
        workRequest.id,
        now,
      );
      await insertInitialConversationTasks(tx, workflowSnapshot, workRequest.id, now);
    }
    await tx.run`INSERT INTO runs
       (id, space_id, thread_id, work_request_id, status, created_at, updated_at)
       VALUES (${runId}, ${spaceId}, ${threadId}, ${workRequest.id}, 'created', ${now}, ${now})`;
    await tx.run`INSERT INTO space_audit_log
       (id, space_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (${`pa-${crypto.randomUUID()}`}, ${spaceId}, 'user', ${context.userId}, 'thread.work_requested', 'work_request', ${workRequest.id}, ${JSON.stringify({ threadId, runId, workflowId, workflowVersion })}::text::jsonb, ${now})`;
  };
  // The "received by Syntila" signal commits in the same D1 batch as the
  // request, so a saved request is never left unannounced.
  const created = {
    type: "work_request.created",
    stream: { kind: "space" as const, id: spaceId },
    spaceId,
    runId,
    idempotencyKey: `work-request:${workRequest.id}:created`,
    payload: {
      entityId: workRequest.id,
      workRequestId: workRequest.id,
      threadId,
      status: "queued",
      ...(submissionId ? { submissionId } : {}),
    },
  };
  const write = (receiptWrite: ReceiptWrite) =>
    createEventPublisher(env).publish({
      ...created,
      mutate: async (tx) => {
        await receiptWrite(tx);
        await writeRequest(tx);
      },
    });
  const concurrentReplay = receipt
    ? await receipt.commit(responseBody, 202, write)
    : (await write(NO_RECEIPT), null);
  if (concurrentReplay) return resumeSubmission(env, concurrentReplay);
  // T2: the submission is durably accepted. durationMs is the handler's own
  // elapsed time (coarse in Workers; I/O advances the clock).
  tryLogTraceEvent({
    traceStage: "cloud_accepted",
    requestId: workRequest.id,
    runId,
    durationMs: performance.now() - handlerStartedAt,
    context: { status: "persisted" },
  });
  return resumeSubmission(env, json(responseBody, { status: 202 }), false);
}

/** Resume only this committed submission, using its existing runtime identities. */
async function resumeSubmission(
  env: SecurityEnv,
  response: Response,
  replay = true,
): Promise<Response> {
  const { workRequest, run } = (await response.clone().json()) as {
    workRequest: WorkRequest;
    run: { id: string; spaceId: string; threadId: string };
  };
  if (replay) {
    const row = await dataOf(env).read.row<{ status: string }>`SELECT status FROM work_requests WHERE id = ${workRequest.id}`;
    if (!row || ["completed", "failed", "cancelled"].includes(row.status))
      return response;
  }
  if (workRequest.mode === "stateful" && env.SYNTILA_THREAD_COORDINATOR) {
    const coordinator = env.SYNTILA_THREAD_COORDINATOR.getByName(
      workRequest.threadId,
    );
    const result = await coordinator.fetch(
      new Request("https://thread-coordinator/enqueue", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-thread-id": workRequest.threadId,
        },
        body: JSON.stringify({ workRequestId: workRequest.id }),
      }),
    );
    if (!result.ok)
      throw new HttpError(503, "Thread execution coordinator unavailable");
  }
  await createOrGetRun(env, {
    runId: run.id,
    goalId: workRequest.id,
    idempotencyKey: workRequest.id,
    workRequestId: workRequest.id,
    threadId: workRequest.threadId,
    spaceId: run.spaceId,
    builtinWorkflow: workRequest.workflowSnapshot,
    input: workRequest.input,
  });
  return response;
}

