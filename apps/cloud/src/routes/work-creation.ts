import { loadSpaceWorkflowConfigurations } from "./space-workflow-configurations.js";
import {
  FileTooLargeError,
  StorageQuotaExceededError,
  getAttachmentLimits,
} from "../account-plan.js";
import {
  parseWorkflowExecutionSelection,
  resolveWorkflowExecutionBindings,
} from "./workflow-execution-configuration.js";
import { requireWorkflowPermission } from "./space-permissions.js";
import { initialConversationTaskStatements } from "./conversation-workflow-step-runs.js";
import { MutationIdempotency } from "./mutation-idempotency.js";
import { resolveWorkflowStepExecutionConfig } from "./workflow-step-execution-config.js";
import {
  conversationSubmissionStatements,
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
  conversationWorkflowForExecution,
  type WorkRequest,
  type WorkRequestSnapshot,
  type ThreadExecutionPolicy,
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
import { workRequestInputStatements } from "./work-request-inputs.js";
import { resolveReplyReference } from "./reply-references.js";
import { createEventPublisher } from "../event-publisher.js";
import { tryLogTraceEvent } from "../observability.js";
import {
  HttpError,
  authorizeThreadAccess,
  eligibilityMessage,
  errorMessage,
  json,
  parseJson,
  requiredString,
  resolveWorkflowInstanceId,
  validateWorkflowWorkerEligibility,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import type { SyntilaWorkflowParams } from "../workflow.js";
import { parseMcpToolStepInput } from "../mcp-tool-step.js";

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
  const row = await env.SYNTILA_DB.prepare(
    `SELECT wc.config_json AS configJson FROM threads ws
       LEFT JOIN thread_work_configs wc ON wc.thread_id = ws.id WHERE ws.id = ?1`,
  )
    .bind(threadId)
    .first<{ configJson: string | null }>();
  const config = parseJson<Record<string, unknown>>(row?.configJson, {
    defaultWorkflowId: "direct",
    bindings: {},
  });
  const body = (await request.json()) as Record<string, unknown>;
  const executionSelection = parseWorkflowExecutionSelection(
    body.executionSelection,
  );
  const workflowId = requiredString(
    body.workflowId ?? config.defaultWorkflowId,
    "workflowId",
  ) as WorkflowId;
  const workflow = BUILTIN_WORKFLOWS[workflowId];
  if (!workflow) throw new HttpError(400, "Unsupported workflowId");
  await requireWorkflowPermission(env, context.userId, spaceId, workflowId);
  if (body.attachments !== undefined && !Array.isArray(body.attachments)) {
    throw new HttpError(400, "attachments must be an array");
  }
  const attachments = Array.isArray(body.attachments) ? body.attachments : [];
  if (attachments.length > MAX_WORK_REQUEST_FILES)
    throw new HttpError(400, "At most 10 attachments are allowed");
  const { issues } = await validateWorkflowWorkerEligibility(
    env,
    spaceId,
    threadId,
    workflow,
    await resolveWorkflowExecutionBindings(
      env,
      context.userId,
      spaceId,
      threadId,
      workflow,
      {},
      attachments,
      executionSelection,
    ),
  );
  if (
    !env.SYNTILA_THREAD_COORDINATOR &&
    workflow.steps.some((step) => step.executionMode === "stateful_thread")
  ) {
    issues.push({
      stepKind: workflow.steps[0]?.kind ?? "implement",
      workerTypeId: null,
      code: "runtime_coordinator_unavailable",
      message: eligibilityMessage(
        "Work",
        null,
        "runtime_coordinator_unavailable",
      ),
    });
  }
  return json({
    eligible: issues.length === 0,
    workflowId,
    workflowName: workflow.name,
    issues,
  });
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
  const body = (await request.json()) as Record<string, unknown>;
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
  const directSpace = await env.SYNTILA_DB.prepare(
    `SELECT pc.status, ds.user_low_id AS userLowId, ds.user_high_id AS userHighId
     FROM direct_spaces ds
     LEFT JOIN person_connections pc ON pc.user_low_id = ds.user_low_id AND pc.user_high_id = ds.user_high_id
     WHERE ds.space_id = ?1`,
  )
    .bind(spaceId)
    .first<{ status: string | null; userLowId: string; userHighId: string }>()
    .catch(() => null);
  if (directSpace) {
    const isBlocked = await env.SYNTILA_DB.prepare(
      `SELECT 1 FROM user_blocks
       WHERE (blocker_user_id = ?1 AND blocked_user_id = ?2)
          OR (blocker_user_id = ?2 AND blocked_user_id = ?1)`,
    )
      .bind(directSpace.userLowId, directSpace.userHighId)
      .first();
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
  const executionSelection = parseWorkflowExecutionSelection(
    body.executionSelection,
  );
  const requestedMode =
    body.mode === "stateful"
      ? "stateful"
      : body.mode === "stateless"
        ? "stateless"
        : null;
  const workConfigRow = await env.SYNTILA_DB.prepare(
    `SELECT wc.config_json AS configJson, p.settings_json AS settingsJson
     FROM threads ws
     JOIN spaces p ON p.id = ws.space_id
     LEFT JOIN thread_work_configs wc ON wc.thread_id = ws.id
     WHERE ws.id = ?1`,
  )
    .bind(threadId)
    .first<{ configJson: string | null; settingsJson: string | null }>();
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
  // A request that carries `input.toolCall` is Chat with a tool (`chat:v2`).
  // It is never picked by version: the tool target is part of the request.
  const toolCallRequested =
    body.input !== null &&
    typeof body.input === "object" &&
    !Array.isArray(body.input) &&
    (body.input as Record<string, unknown>).toolCall !== undefined;
  if (toolCallRequested && workflowId !== "chat")
    throw new HttpError(400, "A tool call is available only in Chat");
  if (
    !toolCallRequested &&
    body.workflowVersion === 2 &&
    workflowId === "chat"
  )
    throw new HttpError(400, "Chat version 2 requires input.toolCall");
  const canonicalWorkflow = toolCallRequested
    ? BUILTIN_WORKFLOW_CATALOG["chat:v2"]!
    : workflowId === "research"
      ? configuredWorkflowDefinition(
          BUILTIN_WORKFLOWS.research,
          (await loadSpaceWorkflowConfigurations(env, spaceId, "research", context.userId))
            .configurations[0],
        )
      : BUILTIN_WORKFLOWS[workflowId];
  if (toolCallRequested) {
    await requireToolCallAuthority(
      env,
      context.userId,
      spaceId,
      (body.input as Record<string, unknown>).toolCall,
    );
  }
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
  if (toolCallRequested) {
    // Frozen in strict form; the Workspace checks it again when it runs.
    requestInput.toolCall = parseMcpToolStepInput(submittedInput.toolCall);
  }
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
  const resolvedBindings = await resolveWorkflowExecutionBindings(
    env,
    context.userId,
    spaceId,
    threadId,
    workflowSnapshot,
    instructions,
    normalizedAttachments,
    executionSelection,
  );
  const eligibility = await validateWorkflowWorkerEligibility(
    env,
    spaceId,
    threadId,
    workflowSnapshot,
    resolvedBindings,
  );
  if (eligibility.issues.length > 0) {
    return json(
      {
        error: "work_request_ineligible",
        workflowId,
        workflowName: workflowSnapshot.name,
        issues: eligibility.issues,
      },
      { status: 422 },
    );
  }
  if (!env.SYNTILA_THREAD_COORDINATOR && mode === "stateful") {
    throw new HttpError(503, "Thread runtime coordination is unavailable");
  }
  if (
    toolCallRequested &&
    parseMcpToolStepInput(submittedInput.toolCall)?.executionWorkspaceId !==
      eligibility.primaryWorkspaceId
  )
    throw new HttpError(
      400,
      "The tool must run on the Workspace that runs the chat answer",
    );
  if (eligibility.primaryWorkspaceId) {
    if (
      body.primaryWorkspaceId !== undefined &&
      body.primaryWorkspaceId !== eligibility.primaryWorkspaceId
    ) {
      throw new HttpError(
        400,
        "Work execution must use the selected Worker's Workspace",
      );
    }
    body.primaryWorkspaceId = eligibility.primaryWorkspaceId;
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
  const policyRow = await env.SYNTILA_DB.prepare(
    "SELECT mode, primary_workspace_id AS primaryWorkspaceId FROM thread_execution_policies WHERE thread_id = ?1",
  )
    .bind(threadId)
    .first<ThreadExecutionPolicy>();
  const policy: ThreadExecutionPolicy =
    canonicalWorkflow.steps.length === 1
      ? {
          mode,
          primaryWorkspaceId:
            typeof body.primaryWorkspaceId === "string"
              ? body.primaryWorkspaceId
              : null,
        }
      : (policyRow ?? {
          mode,
          primaryWorkspaceId:
            typeof body.primaryWorkspaceId === "string"
              ? body.primaryWorkspaceId
              : null,
        });
  const now = new Date().toISOString();
  const conversationWorkflow =
    conversationWorkflowForExecution(workflowId, workflowVersion) ??
    ((workflowId === "research" || workflowId === "chat") &&
    workflowVersion === 2
      ? // Conversation identity predates graph workflows and its persisted
        // anchor accepts only chat/work. The request and Workflow Run retain
        // their actual Research identity and version.
        CONVERSATION_WORKFLOWS.chat!
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
    primaryWorkspaceId:
      typeof body.primaryWorkspaceId === "string"
        ? body.primaryWorkspaceId
        : null,
    input: requestInput,
    createdAt: now,
    updatedAt: now,
  };
  try {
    validateWorkRequest(workRequest, policy);
  } catch (error) {
    throw new HttpError(
      400,
      error instanceof Error ? error.message : "Invalid Work Request",
    );
  }
  const fileInputs = normalizedAttachments.some(
    (attachment) => attachment.kind === "file",
  );
  if (fileInputs && !workRequest.primaryWorkspaceId)
    throw new HttpError(400, "Files need a Workspace to deliver them to");
  const runId = `run-${crypto.randomUUID()}`;
  const responseBody = {
    workRequest,
    run: { id: runId, spaceId, threadId, status: "created" },
  };
  const statements = (receipts: D1PreparedStatement[]) => [
    ...receipts,
    env.SYNTILA_DB.prepare(
      `INSERT INTO work_requests
       (id, thread_id, requested_by_user_id, mode, workflow_id, workflow_version, workflow_snapshot_json, snapshot_json, status, primary_workspace_id, input_json, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'queued', ?9, ?10, ?11, ?11)`,
    ).bind(
      workRequest.id,
      threadId,
      context.userId,
      mode,
      workflowId,
      workflowVersion,
      JSON.stringify(workflowSnapshot),
      JSON.stringify(snapshot),
      workRequest.primaryWorkspaceId,
      JSON.stringify(workRequest.input),
      now,
    ),
    ...(fileInputs
      ? workRequestInputStatements(env.SYNTILA_DB, {
          workRequestId: workRequest.id,
          threadId,
          workspaceId: workRequest.primaryWorkspaceId!,
          userId: context.userId,
          attachments: normalizedAttachments,
          now,
        })
      : []),
    // Sidebar ordering is based on these parent timestamps. A newly
    // accepted request is Thread activity even before a Worker responds.
    env.SYNTILA_DB.prepare(
      "UPDATE threads SET updated_at = ?1 WHERE id = ?2",
    ).bind(now, threadId),
    env.SYNTILA_DB.prepare(
      "UPDATE spaces SET updated_at = ?1 WHERE id = ?2",
    ).bind(now, spaceId),
    ...(conversationWorkflow
      ? conversationSubmissionStatements(
          env.SYNTILA_DB,
          selectedConversationId!,
          threadId,
          conversationWorkflow,
          workRequest.id,
          now,
        )
      : []),
    ...(conversationWorkflow
      ? initialConversationTaskStatements(
          env.SYNTILA_DB,
          workflowSnapshot,
          workRequest.id,
          now,
        )
      : []),
    env.SYNTILA_DB.prepare(
      `INSERT INTO runs
       (id, space_id, thread_id, work_request_id, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, 'created', ?5, ?5)`,
    ).bind(runId, spaceId, threadId, workRequest.id, now),
    env.SYNTILA_DB.prepare(
      `INSERT INTO space_audit_log
       (id, space_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'user', ?3, 'thread.work_requested', 'work_request', ?4, ?5, ?6)`,
    ).bind(
      `pa-${crypto.randomUUID()}`,
      spaceId,
      context.userId,
      workRequest.id,
      JSON.stringify({ threadId, runId, workflowId, workflowVersion }),
      now,
    ),
  ];
  // The "received by Syntila" signal commits in the same D1 batch as the
  // request, so a saved request is never left unannounced.
  const created = {
    type: "work_request.created",
    workspaceId: workRequest.primaryWorkspaceId ?? undefined,
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
  const write = (receipts: D1PreparedStatement[]) =>
    workRequest.primaryWorkspaceId
      ? createEventPublisher(env).publish({
          ...created,
          mutations: statements(receipts),
        })
      : env.SYNTILA_DB.batch(statements(receipts));
  const concurrentReplay = receipt
    ? await receipt.commit(responseBody, 202, write)
    : (await write([]), null);
  if (concurrentReplay) return resumeSubmission(env, concurrentReplay);
  // T2: the submission is durably accepted. durationMs is the handler's own
  // elapsed time (coarse in Workers; I/O advances the clock).
  tryLogTraceEvent({
    traceStage: "cloud_accepted",
    requestId: workRequest.id,
    workspaceId: workRequest.primaryWorkspaceId ?? undefined,
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
    const row = await env.SYNTILA_DB.prepare(
      "SELECT status FROM work_requests WHERE id = ?1",
    )
      .bind(workRequest.id)
      .first<{ status: string }>();
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
    organizationId: workRequest.primaryWorkspaceId!,
    workRequestId: workRequest.id,
    threadId: workRequest.threadId,
    spaceId: run.spaceId,
    builtinWorkflow: workRequest.workflowSnapshot,
    input: workRequest.input,
  });
  return response;
}

/**
 * Tool calls run only for the Space owner, on a Workspace they own. Space
 * membership, a lent Workspace or a Person Grant never extend to them: the
 * tool is run with the Workspace owner's local consent.
 */
async function requireToolCallAuthority(
  env: SecurityEnv,
  userId: string,
  spaceId: string,
  toolCall: unknown,
): Promise<void> {
  const target = parseMcpToolStepInput(toolCall);
  if (!target) throw new HttpError(400, "input.toolCall is invalid");
  const row = await env.SYNTILA_DB.prepare(
    `SELECT p.owner_user_id AS spaceOwner, COALESCE(p.kind, 'group') AS spaceKind,
            ew.owner_user_id AS workspaceOwner
     FROM spaces p
     LEFT JOIN execution_workspaces ew ON ew.id = ?2
     WHERE p.id = ?1`,
  )
    .bind(spaceId, target.executionWorkspaceId)
    .first<{
      spaceOwner: string;
      spaceKind: string;
      workspaceOwner: string | null;
    }>();
  if (!row || row.workspaceOwner !== userId)
    throw new HttpError(
      403,
      "A tool call can only be run on a Workspace you own",
    );
  if (row.spaceKind !== "direct" && row.spaceOwner !== userId)
    throw new HttpError(
      403,
      "Only the Space owner can run a tool, on a Workspace they own",
    );
}
