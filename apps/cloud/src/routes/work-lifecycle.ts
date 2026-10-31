import {
  inputProgress,
  loadInputsForRequests,
  loadWorkRequestInputs,
  withInputFacts,
} from "./work-request-inputs.js";
import { storedReplyReference } from "./reply-references.js";
import { threadNotice } from "./thread-history-actions.js";
import { workRequestFileMetadata } from "./work-request-files.js";
import { loadConversationWorkflowRuns } from "./conversation-workflow-runs.js";
import {
  loadConversationTurns,
  withConversationTurn,
} from "./conversation-turns.js";
import {
  cancelTaskAssignment,
  type AssignmentDispatcherEnv,
} from "../assignment-dispatcher.js";
import {
  STEP_KINDS,
  BUILTIN_WORKFLOW_CATALOG,
  type BuiltinWorkflowDefinition,
  type StepKind,
} from "@syntila/core";
import {
  canonicalExecutionErrorCode,
  executionErrorMessage,
} from "@syntila/protocol";

import {
  HttpError,
  authorizeThreadAccess,
  json,
  parseJson,
  resolveWorkflowInstanceId,
  securityContext,
  summarizeTestCounts,
  validateWorkflowWorkerEligibility,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

import { createOrGetRun } from "./work-creation.js";
import { MutationIdempotency } from "./mutation-idempotency.js";
import { advanceThreadQueueSafely } from "./thread-request-queue.js";
import { publishCollaborationEvent } from "../collaboration-events.js";
import { workerProfileSupportsCompaction } from "../worker-profile-registry.js";
import { ACTIVE_ASSIGNMENT_STATUS_SQL } from "../assignment-transitions.js";
import {
  deriveRequestExecutionPhase,
  presentExecution,
  type ExecutionPhase,
} from "../execution-phase.js";

function historicalWorkflowName(
  snapshot: { readonly name?: unknown },
  workflowId: unknown,
  workflowVersion: unknown,
): string {
  return typeof snapshot.name === "string" && snapshot.name.trim()
    ? snapshot.name
    : (BUILTIN_WORKFLOW_CATALOG[
        `${String(workflowId)}:v${Number(workflowVersion)}`
      ]?.name ?? String(workflowId));
}

async function loadWorkRequestActivityHistory(
  db: D1Database,
  workRequestId: string,
): Promise<Record<string, unknown>[]> {
  const rows = await db
    .prepare(
      `SELECT * FROM (
         SELECT h.history_id AS eventId,
                h.assignment_id AS assignmentId,
                h.attempt_id AS attemptId,
                h.execution_id AS executionId,
                h.worker_id AS workerId,
                h.provider_sequence AS activitySequence,
                h.event_type AS activityType,
                h.status AS activityStatus,
                h.activity_id AS activityId,
                h.title,
                h.details_json AS detailsJson,
                h.duration_ms AS durationMs,
                h.tool_id AS toolId,
                h.tool_name AS toolName,
                h.occurred_at AS timestamp
           FROM worker_activity_history h
           JOIN worker_assignments a ON a.id = h.assignment_id
          WHERE COALESCE(
                  a.work_request_id,
                  (SELECT wt.work_request_id FROM workflow_tasks wt
                    WHERE wt.id = a.task_id)
                ) = ?1
          ORDER BY h.occurred_at DESC, h.provider_sequence DESC, h.history_id DESC
          LIMIT 256
       )
       ORDER BY timestamp ASC, activitySequence ASC, eventId ASC`,
    )
    .bind(workRequestId)
    .all<Record<string, unknown>>();

  return (rows.results ?? []).map((row) => {
    const rawDetails = parseJson<Record<string, unknown>>(
      typeof row.detailsJson === "string" ? row.detailsJson : null,
      {},
    );
    const details = Object.fromEntries(
      Object.entries(rawDetails).filter(
        ([, value]) =>
          value === null ||
          typeof value === "string" ||
          typeof value === "number" ||
          typeof value === "boolean",
      ),
    );
    return {
      eventId: String(row.eventId),
      assignmentId: String(row.assignmentId),
      attemptId: String(row.attemptId),
      executionId: String(row.executionId),
      workerId: String(row.workerId),
      activitySequence: Number(row.activitySequence),
      activityType: String(row.activityType),
      activityStatus: String(row.activityStatus),
      ...(typeof row.activityId === "string"
        ? { activityId: row.activityId }
        : {}),
      title: String(row.title),
      ...(row.durationMs !== null && row.durationMs !== undefined
        ? { durationMs: Number(row.durationMs) }
        : {}),
      ...(typeof row.toolId === "string" ? { toolId: row.toolId } : {}),
      ...(typeof row.toolName === "string" ? { toolName: row.toolName } : {}),
      details,
      timestamp: String(row.timestamp),
    };
  });
}

export async function handleRetryWorkRequest(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const parent = await env.SYNTILA_DB.prepare(
    "SELECT thread_id AS threadId FROM work_requests WHERE id = ?1",
  )
    .bind(workRequestId)
    .first<{ threadId: string }>();
  if (!parent) throw new HttpError(404, "Work Request not found");
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    parent.threadId,
    "execute",
    accessContext,
  );
  const membership = await env.SYNTILA_DB.prepare(
    "SELECT role FROM space_memberships WHERE space_id = ?1 AND user_id = ?2",
  )
    .bind(spaceId, context.userId)
    .first<{ role: string }>();
  if (!membership || membership.role === "viewer")
    throw new HttpError(
      403,
      "Space membership with execute access is required",
    );
  const row = await env.SYNTILA_DB.prepare(
    `SELECT wr.thread_id AS threadId, wr.mode, wr.status,
            wr.workflow_id AS workflowId, wr.workflow_version AS workflowVersion,
            wr.workflow_snapshot_json AS workflowSnapshotJson,
            wr.snapshot_json AS snapshotJson, (SELECT text FROM conversation_history_entries h WHERE h.work_request_id = wr.id AND h.kind = 'user_message' LIMIT 1) AS canonicalUserText, wr.input_json AS inputJson,
            wr.primary_workspace_id AS primaryWorkspaceId,
            ws.space_id AS spaceId
       FROM work_requests wr JOIN threads ws ON ws.id = wr.thread_id
      WHERE wr.id = ?1`,
  )
    .bind(workRequestId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Work Request not found");
  if (row.status !== "failed")
    throw new HttpError(409, "Only a failed Work Request can be retried");

  const body = parseJson<Record<string, unknown>>(await request.text(), {});
  const stepKind = body.stepKind;
  if (
    typeof stepKind !== "string" ||
    !STEP_KINDS.includes(stepKind as StepKind)
  )
    throw new HttpError(400, "A valid failed Step is required");
  const workflow = parseJson<BuiltinWorkflowDefinition>(
    String(row.workflowSnapshotJson),
    {} as BuiltinWorkflowDefinition,
  );
  const step = workflow.steps?.find((candidate) => candidate.kind === stepKind);
  if (!step) throw new HttpError(400, "Step is not part of this Workflow");
  const failedTask = await env.SYNTILA_DB.prepare(
    `SELECT wt.status, wt.error, wa.error_json AS assignmentErrorJson,
            wa.status AS assignmentStatus, wa.dispatched_at AS dispatchedAt,
            wa.acknowledged_at AS acknowledgedAt,
            wa.start_permit_issued_at AS startPermitIssuedAt,
            wa.start_permit_required AS startPermitRequired,
            wa.running_at AS runningAt, wa.startup_stage AS startupStage,
            wa.worker_type_id AS workerTypeId
       FROM workflow_tasks wt
       LEFT JOIN worker_assignments wa ON wa.id = (
         SELECT wa2.id FROM worker_assignments wa2
          WHERE wa2.task_id = wt.id
          ORDER BY wa2.created_at DESC, wa2.id DESC LIMIT 1
       )
      WHERE wt.work_request_id = ?1 AND wt.step_kind = ?2`,
  )
    .bind(workRequestId, stepKind)
    .first<
      Record<string, unknown> & {
        status: string;
        error: string | null;
        assignmentErrorJson: string | null;
      }
    >();
  if (failedTask?.status !== "failed")
    throw new HttpError(409, "Only a failed Step can be retried");

  // Retry safety is decided by Cloud from assignment evidence, not by the
  // client: an unconfirmed stop can never be retried, and a step whose
  // provider may already have acted needs an explicit confirmation.
  const retryAdvice = stepExecutionFields(
    failedTask,
    typeof failedTask.error === "string"
      ? canonicalExecutionErrorCode(failedTask.error)
      : null,
  ).retry;
  if (retryAdvice && !retryAdvice.allowed)
    throw new HttpError(
      409,
      "This Step cannot be retried until the Worker is confirmed stopped",
    );
  if (retryAdvice?.requiresConfirmation && body.confirmSideEffects !== true)
    return json(
      {
        error: "retry_confirmation_required",
        message:
          "The previous execution may already have made changes. Confirm to retry anyway.",
      },
      { status: 409 },
    );

  const contextLimitExceeded =
    typeof failedTask.error === "string" &&
    canonicalExecutionErrorCode(failedTask.error) === "context_limit_exceeded";
  // Over the context limit the user either clears AI History (a new session
  // that keeps the latest answer) or compacts the Worker's own session.
  // `clearAiHistory` is the older form of "clear".
  const contextResolution =
    body.contextResolution === "compact"
      ? "compact"
      : body.contextResolution === "clear" || body.clearAiHistory === true
        ? "clear"
        : null;
  if (contextLimitExceeded && contextResolution === null)
    return json(
      {
        error: "clear_ai_history_required",
        message:
          "Clear AI History or compact the Worker session to retry a request over the context limit.",
      },
      { status: 409 },
    );
  if (contextLimitExceeded && contextResolution === "compact") {
    const unavailable = await contextCompactionUnavailable(env, {
      workRequestId,
      stepKind,
      workerTypeId: failedTask.workerTypeId,
    });
    if (unavailable)
      return json(
        { error: "context_compaction_unavailable", message: unavailable },
        { status: 409 },
      );
  }
  const compactContext =
    contextLimitExceeded && contextResolution === "compact";
  const clearAiHistory = contextLimitExceeded && !compactContext;
  if (clearAiHistory) {
    const active = await env.SYNTILA_DB.prepare(
      "SELECT COUNT(*) AS count FROM work_requests WHERE thread_id = ?1 AND status IN ('queued', 'running', 'waiting')",
    )
      .bind(String(row.threadId))
      .first<{ count: number }>();
    if (active && active.count > 0)
      throw new HttpError(
        409,
        `Cannot clear history with ${active.count} active Work Request(s). Cancel first.`,
      );
  }
  // Clearing always starts a new Worker session; compacting must resume the
  // session it compacts.
  const retrySessionStrategy = clearAiHistory
    ? "fresh"
    : compactContext
      ? "resume"
      : body.sessionStrategy;
  if (
    stepKind === "implement" &&
    retrySessionStrategy !== "resume" &&
    retrySessionStrategy !== "fresh"
  )
    throw new HttpError(
      400,
      "Choose whether the Implement retry resumes the previous session or starts fresh",
    );
  if (
    stepKind !== "implement" &&
    !contextLimitExceeded &&
    retrySessionStrategy !== undefined
  )
    throw new HttpError(400, "Session strategy only applies to Implement");

  const snapshot = parseJson<Record<string, unknown>>(
    String(row.snapshotJson),
    {},
  );
  const bindings =
    typeof snapshot.resolvedBindings === "object" &&
    snapshot.resolvedBindings !== null
      ? (snapshot.resolvedBindings as Record<
          string,
          { workerId?: string; model?: string }
        >)
      : {};
  const attachmentInput = parseJson<Record<string, unknown>>(
    String(row.inputJson),
    {},
  );
  const eligibility = await validateWorkflowWorkerEligibility(
    env,
    String(row.spaceId),
    String(row.threadId),
    { ...workflow, steps: [step] },
    bindings,
  );
  if (eligibility.issues.length > 0) {
    return json(
      { error: "work_request_ineligible", issues: eligibility.issues },
      { status: 422 },
    );
  }

  const latestRuns = await env.SYNTILA_DB.prepare(
    "SELECT COUNT(*) AS count FROM runs WHERE work_request_id = ?1",
  )
    .bind(workRequestId)
    .first<{ count: number }>();
  const retryNumber = Math.max(1, Number(latestRuns?.count ?? 1));
  const runId = `run-${workRequestId}-retry-${retryNumber}`;
  const now = new Date().toISOString();
  const assignmentError = parseJson<Record<string, unknown>>(
    failedTask.assignmentErrorJson,
    {},
  );
  const assignmentErrorDetail =
    typeof assignmentError.error === "object" && assignmentError.error !== null
      ? (assignmentError.error as Record<string, unknown>)
      : {};
  const errorCode = canonicalExecutionErrorCode(
    assignmentErrorDetail.code ?? failedTask.error ?? "execution_failed",
  );
  const retryPolicy = {
    manualRetry: {
      stepKind,
      errorCode,
      retryNumber,
      ...(stepKind === "implement" || contextLimitExceeded
        ? { sessionStrategy: retrySessionStrategy }
        : {}),
      ...(contextLimitExceeded ? { contextResolution } : {}),
    },
  };
  const reservation = await env.SYNTILA_DB.prepare(
    "UPDATE work_requests SET status = 'queued', updated_at = ?1 WHERE id = ?2 AND status = 'failed' RETURNING id",
  )
    .bind(now, workRequestId)
    .first<{ id: string }>();
  // Updating a Work Request also fires history and Workflow projection
  // triggers. D1's meta.changes includes those writes, so only the returned
  // identity proves that this retry won the failed-row reservation.
  if (reservation?.id !== workRequestId)
    throw new HttpError(409, "This Work Request is already being retried");
  try {
    await env.SYNTILA_DB.batch([
      // Over the context limit, AI History is cut off just before the latest
      // Worker answer that precedes this request, so the new session keeps
      // that answer and this request as its only context.
      ...(clearAiHistory
        ? [
            env.SYNTILA_DB.prepare(
              `UPDATE conversations SET context_floor_sequence = COALESCE(
                 (SELECT MAX(h.sequence) - 1 FROM conversation_history_entries h
                   WHERE h.conversation_id = conversations.id
                     AND h.kind = 'worker_response'
                     AND h.sequence < (SELECT MIN(u.sequence) FROM conversation_history_entries u
                       WHERE u.conversation_id = conversations.id AND u.work_request_id = ?2)),
                 (SELECT MIN(u.sequence) - 1 FROM conversation_history_entries u
                   WHERE u.conversation_id = conversations.id AND u.work_request_id = ?2),
                 context_floor_sequence)
               WHERE thread_id = ?1`,
            ).bind(String(row.threadId), workRequestId),
            env.SYNTILA_DB.prepare(
              "UPDATE threads SET ai_history_cleared_at = ?1, updated_at = ?1 WHERE id = ?2",
            ).bind(now, String(row.threadId)),
          ]
        : []),
      // A fresh retry starts a new Work session for the whole Thread: the
      // next requests continue it instead of falling back to the old session
      // that just failed. The retry run reads the bumped generation.
      ...((stepKind === "implement" || contextLimitExceeded) &&
      retrySessionStrategy === "fresh"
        ? [
            env.SYNTILA_DB.prepare(
              "UPDATE threads SET work_session_generation = work_session_generation + 1, updated_at = ?1 WHERE id = ?2",
            ).bind(now, String(row.threadId)),
          ]
        : []),
      env.SYNTILA_DB.prepare(
        `UPDATE work_requests SET ai_context_generation =
        (SELECT ai_context_generation FROM threads WHERE id = ?1) WHERE id = ?2`,
      ).bind(String(row.threadId), workRequestId),
      ...(clearAiHistory
        ? [
            threadNotice(
              env,
              String(row.threadId),
              context.userId,
              context.user.displayName || "Member",
              "ai.context_reset",
              "reset AI context to retry a request.",
              now,
            ),
          ]
        : []),
      env.SYNTILA_DB.prepare(
        `UPDATE workflow_tasks SET status = 'queued', output_json = NULL,
              error = NULL, started_at = NULL, finished_at = NULL, updated_at = ?1
        WHERE work_request_id = ?2 AND step_kind = ?3 AND status = 'failed'`,
      ).bind(now, workRequestId, stepKind),
      env.SYNTILA_DB.prepare(
        `INSERT INTO runs
       (id, space_id, thread_id, work_request_id,
        policy_snapshot_json, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, 'created', ?6, ?6)`,
      ).bind(
        runId,
        spaceId,
        String(row.threadId),
        workRequestId,
        JSON.stringify(retryPolicy),
        now,
      ),
    ]);
  } catch (error) {
    await env.SYNTILA_DB.prepare(
      "UPDATE work_requests SET status = 'failed', updated_at = ?1 WHERE id = ?2 AND status = 'queued'",
    )
      .bind(new Date().toISOString(), workRequestId)
      .run();
    throw error;
  }

  if (row.mode === "stateful") {
    if (!env.SYNTILA_THREAD_COORDINATOR)
      throw new HttpError(503, "Thread runtime coordination is unavailable");
    const coordinator = env.SYNTILA_THREAD_COORDINATOR.getByName(
      String(row.threadId),
    );
    const response = await coordinator.fetch(
      new Request("https://thread-coordinator/enqueue", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-thread-id": String(row.threadId),
        },
        body: JSON.stringify({ workRequestId }),
      }),
    );
    if (!response.ok)
      throw new HttpError(503, "Thread runtime coordination is unavailable");
  }

  await createOrGetRun(env, {
    runId,
    goalId: workRequestId,
    idempotencyKey: `${workRequestId}-retry-${retryNumber}`,
    organizationId: String(row.primaryWorkspaceId),
    workRequestId,
    threadId: String(row.threadId),
    spaceId,
    builtinWorkflow: workflow,
    input: attachmentInput,
    retryStepKind: stepKind as StepKind,
    ...(stepKind === "implement" || contextLimitExceeded
      ? { retrySessionStrategy: retrySessionStrategy as "resume" | "fresh" }
      : {}),
    retryNumber,
    // Only a failure that said "folder exists" can be answered by adopting it,
    // and only when the user explicitly confirmed.
    ...(errorCode === "space_folder_exists" && body.confirmSideEffects === true
      ? { retryAdoptSpaceFolder: true }
      : {}),
    ...(compactContext ? { retryCompactContext: true } : {}),
  });
  if (clearAiHistory) {
    await publishCollaborationEvent(
      env,
      "thread.work_cleared",
      spaceId,
      String(row.threadId),
      { threadId: String(row.threadId) },
    );
  }
  return json(
    { workRequestId, runId, stepKind, retryNumber, status: "queued" },
    { status: 202 },
  );
}

/**
 * Why a Step that failed over the context limit cannot be compacted, or null
 * when it can: the Worker's Profile must declare compaction, and an overflow
 * that a compacting retry did not resolve can only be cleared.
 */
async function contextCompactionUnavailable(
  env: SecurityEnv,
  args: {
    readonly workRequestId: string;
    readonly stepKind: string;
    readonly workerTypeId: unknown;
  },
): Promise<string | null> {
  if (
    typeof args.workerTypeId !== "string" ||
    !(await workerProfileSupportsCompaction(env.SYNTILA_DB, args.workerTypeId))
  )
    return "This Worker cannot compact its session. Clear AI History instead.";
  const latestRun = await env.SYNTILA_DB.prepare(
    `SELECT policy_snapshot_json AS policySnapshotJson
       FROM runs WHERE work_request_id = ?1
      ORDER BY created_at DESC, id DESC LIMIT 1`,
  )
    .bind(args.workRequestId)
    .first<{ policySnapshotJson: string | null }>();
  const manualRetry = parseJson<{
    manualRetry?: { stepKind?: unknown; contextResolution?: unknown };
  }>(latestRun?.policySnapshotJson, {}).manualRetry;
  if (
    manualRetry?.stepKind === args.stepKind &&
    manualRetry.contextResolution === "compact"
  )
    return "Compacting did not free enough context. Clear AI History instead.";
  return null;
}

export async function handleGetWorkRequest(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const row = await env.SYNTILA_DB.prepare(
    `SELECT wr.id, wr.thread_id AS threadId,
            wr.requested_by_user_id AS requestedByUserId,
            (SELECT conversation_id FROM conversation_work_requests WHERE work_request_id = wr.id) AS conversationId,
            u.display_name AS requestedByName,
            wr.workflow_id AS workflowId, wr.workflow_version AS workflowVersion,
            wr.workflow_snapshot_json AS workflowSnapshotJson,
            (SELECT text FROM conversation_history_entries h WHERE h.work_request_id = wr.id AND h.kind = 'user_message' LIMIT 1) AS canonicalUserText, wr.input_json AS inputJson, wr.snapshot_json AS snapshotJson,
            wr.status, wr.created_at AS createdAt, wr.updated_at AS updatedAt
       FROM work_requests wr JOIN users u ON u.id = wr.requested_by_user_id
      WHERE wr.id = ?1`,
  )
    .bind(workRequestId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Work Request not found");
  await authorizeThreadAccess(
    request,
    env,
    String(row.threadId),
    "view",
    accessContext,
  );
  const task = await env.SYNTILA_DB.prepare(
    `SELECT output_json AS outputJson, error
     FROM workflow_tasks WHERE work_request_id = ?1
     ORDER BY created_at DESC, id DESC LIMIT 1`,
  )
    .bind(workRequestId)
    .first<{ outputJson: string | null; error: string | null }>();
  let result: unknown = null;
  if (task?.outputJson) {
    try {
      result = JSON.parse(task.outputJson);
    } catch {
      result = null;
    }
  }
  const input = parseJson<Record<string, unknown>>(String(row.inputJson), {});
  const snapshot = parseJson<Record<string, unknown>>(
    String(row.snapshotJson),
    {},
  );
  const workflow = parseJson<Record<string, unknown>>(
    String(row.workflowSnapshotJson),
    {},
  );
  const latestRun = await env.SYNTILA_DB.prepare(
    `SELECT policy_snapshot_json AS policySnapshotJson
       FROM runs WHERE work_request_id = ?1
      ORDER BY created_at DESC, id DESC LIMIT 1`,
  )
    .bind(workRequestId)
    .first<{ policySnapshotJson: string | null }>();
  const latestRunPolicy = parseJson<Record<string, unknown>>(
    latestRun?.policySnapshotJson,
    {},
  );
  const manualRetry =
    typeof latestRunPolicy.manualRetry === "object" &&
    latestRunPolicy.manualRetry !== null
      ? (latestRunPolicy.manualRetry as Record<string, unknown>)
      : {};
  const bindings =
    typeof snapshot.resolvedBindings === "object" &&
    snapshot.resolvedBindings !== null
      ? (snapshot.resolvedBindings as Record<string, unknown>)
      : {};
  const taskRows = await env.SYNTILA_DB.prepare(
    `SELECT wt.id AS taskId, wt.step_kind AS kind, wt.status,
            wt.output_json AS outputJson, wt.error, wt.attempt,
            wt.started_at AS startedAt, wt.finished_at AS finishedAt,
            wa.id AS assignmentId, wa.workspace_worker_id AS workerId,
            wa.worker_type_id AS logicalWorkerTypeId, wa.model AS assignedModel,
            wa.engine_version AS engineVersion,
            wa.session_policy AS sessionPolicy,
            wa.created_at AS assignmentCreatedAt,
            wa.updated_at AS assignmentUpdatedAt,
            json_extract(wa.permission_snapshot_json, '$.executionSelection.modelName') AS modelName,
            json_extract(wa.permission_snapshot_json, '$.executionSelection.catalogRevision') AS catalogRevision,
            wa.permission_snapshot_json AS permissionSnapshotJson,
            wa.error_json AS assignmentErrorJson,
            wa.status AS assignmentStatus, wa.dispatched_at AS dispatchedAt,
            wa.acknowledged_at AS acknowledgedAt,
            wa.start_permit_issued_at AS startPermitIssuedAt,
            wa.start_permit_required AS startPermitRequired,
            wa.running_at AS runningAt, wa.startup_stage AS startupStage,
            wi.worker_type_id AS inventoryWorkerTypeId,
            wi.provider_tool_name AS configuredProviderToolName,
            wi.provider_tool_version AS configuredProviderToolVersion,
            COALESCE(json_extract(wa.permission_snapshot_json, '$.executionSelection.workerDisplayName'), json_extract(wa.permission_snapshot_json, '$.workerDisplayName'), worker_catalog.display_name) AS workerDisplayName
       FROM workflow_tasks wt
       JOIN work_requests wr ON wr.id = wt.work_request_id
       LEFT JOIN worker_assignments wa ON wa.id = (
         SELECT wa2.id FROM worker_assignments wa2
          WHERE wa2.task_id = wt.id
          ORDER BY wa2.created_at DESC, wa2.id DESC LIMIT 1
       )
       LEFT JOIN workspace_worker_inventory wi ON wi.worker_id = COALESCE(
         wa.workspace_worker_id,
         json_extract(wr.snapshot_json, '$.resolvedBindings.' ||
           CASE WHEN wr.workflow_id = 'direct' THEN 'direct' ELSE wt.step_kind END || '.workerId')
       )
       LEFT JOIN worker_catalog
         ON worker_catalog.worker_type_id = COALESCE(
           wa.worker_type_id, wi.worker_type_id
         )
      WHERE wt.work_request_id = ?1
      ORDER BY wt.created_at, wt.id`,
  )
    .bind(workRequestId)
    .all<Record<string, unknown>>();
  const taskByKind = new Map(
    (taskRows.results ?? []).map((value) => [String(value.kind), value]),
  );
  const turns =
    (await loadConversationTurns(env.SYNTILA_DB, [workRequestId])).get(
      workRequestId,
    ) ?? [];
  const workflowSteps = Array.isArray(workflow.steps) ? workflow.steps : [];
  const steps = workflowSteps
    .flatMap((value) => {
      if (!value || typeof value !== "object") return [];
      const definition = value as Record<string, unknown>;
      const kind = String(definition.kind ?? "implement");
      const task = taskByKind.get(kind);
      const bindingId = row.workflowId === "direct" ? "direct" : kind;
      const bindingValue = bindings[bindingId];
      const binding =
        typeof bindingValue === "object" && bindingValue !== null
          ? (bindingValue as Record<string, unknown>)
          : {};
      const executionConfig = (
        snapshot.stepExecutionConfigs as
          Record<string, Record<string, unknown>> | undefined
      )?.[kind];
      const output = parseJson<Record<string, unknown>>(
        typeof task?.outputJson === "string" ? task.outputJson : null,
        {},
      );
      const permissionSnapshot = parseJson<Record<string, unknown>>(
        typeof task?.permissionSnapshotJson === "string"
          ? task.permissionSnapshotJson
          : null,
        {},
      );
      const hasAssignment = typeof task?.assignmentId === "string";
      const assignmentError = parseJson<Record<string, unknown>>(
        typeof task?.assignmentErrorJson === "string"
          ? task.assignmentErrorJson
          : null,
        {},
      );
      const assignmentErrorValue = assignmentError.error;
      const assignmentErrorObject =
        typeof assignmentErrorValue === "object" &&
        assignmentErrorValue !== null
          ? (assignmentErrorValue as Record<string, unknown>)
          : {};
      const rawErrorCode =
        typeof assignmentErrorObject.code === "string"
          ? assignmentErrorObject.code
          : typeof task?.error === "string"
            ? task.error
            : null;
      const errorCode = rawErrorCode
        ? canonicalExecutionErrorCode(rawErrorCode)
        : null;
      const startedAt =
        (typeof task?.startedAt === "string" ? task.startedAt : null) ??
        (typeof output.startedAt === "string" ? output.startedAt : null) ??
        (typeof task?.assignmentCreatedAt === "string"
          ? task.assignmentCreatedAt
          : null);
      const finishedAt =
        (typeof task?.finishedAt === "string" ? task.finishedAt : null) ??
        (typeof output.completedAt === "string" ? output.completedAt : null) ??
        (typeof task?.assignmentUpdatedAt === "string" &&
        ["completed", "failed", "cancelled"].includes(String(task.status))
          ? task.assignmentUpdatedAt
          : null);
      const startMs = startedAt ? Date.parse(startedAt) : NaN;
      const endMs = finishedAt ? Date.parse(finishedAt) : Date.now();
      const elapsedMs = Number.isFinite(startMs)
        ? Math.max(0, endMs - startMs)
        : null;
      const resolvedWorkerId =
        typeof binding.workerId === "string" ? binding.workerId : null;
      return [
        {
          kind,
          status: String(
            task?.status ?? (row.status === "queued" ? "queued" : "waiting"),
          ),
          workerId: task?.workerId ?? resolvedWorkerId,
          workerTypeId: hasAssignment
            ? (task?.logicalWorkerTypeId ?? null)
            : (task?.inventoryWorkerTypeId ?? null),
          workerDisplayName:
            typeof task?.workerDisplayName === "string"
              ? task.workerDisplayName
              : null,
          engineVersion: hasAssignment
            ? typeof permissionSnapshot.profileDefinitionId === "string"
              ? (task?.engineVersion ?? null)
              : null
            : typeof output.engineVersion === "string"
              ? output.engineVersion
              : null,
          profileDefinitionId: hasAssignment
            ? typeof permissionSnapshot.profileDefinitionId === "string"
              ? permissionSnapshot.profileDefinitionId
              : null
            : (executionConfig?.profileId ?? null),
          profileReleaseVersion: hasAssignment
            ? Number.isSafeInteger(permissionSnapshot.profileReleaseVersion)
              ? permissionSnapshot.profileReleaseVersion
              : null
            : (executionConfig?.profileReleaseVersion ?? null),
          reasoningEffort: hasAssignment
            ? ((
                permissionSnapshot.executionSelection as
                  Record<string, unknown> | undefined
              )?.effort ??
              permissionSnapshot.reasoningEffort ??
              null)
            : (binding.reasoningEffort ?? null),
          modelName: hasAssignment ? (task?.modelName ?? null) : null,
          catalogRevision: hasAssignment
            ? (task?.catalogRevision ?? null)
            : null,
          model: hasAssignment
            ? (task?.assignedModel ?? null)
            : typeof binding.model === "string"
              ? binding.model
              : null,
          providerToolName:
            (typeof permissionSnapshot.providerToolName === "string"
              ? permissionSnapshot.providerToolName
              : null) ??
            (hasAssignment ? null : task?.configuredProviderToolName) ??
            null,
          providerToolVersion:
            (typeof permissionSnapshot.providerToolVersion === "string"
              ? permissionSnapshot.providerToolVersion
              : null) ??
            (hasAssignment ? null : task?.configuredProviderToolVersion) ??
            (typeof output.providerToolVersion === "string"
              ? output.providerToolVersion
              : null),
          startedAt,
          completedAt: finishedAt,
          elapsedMs,
          resultText:
            typeof output.text === "string"
              ? output.text.slice(0, 24_000)
              : null,
          assignmentId:
            typeof task?.assignmentId === "string" ? task.assignmentId : null,
          sessionPolicy:
            typeof task?.sessionPolicy === "string" ? task.sessionPolicy : null,
          errorCode,
          errorMessage: errorCode ? executionErrorMessage(errorCode) : null,
          ...stepExecutionFields(task, errorCode),
          ...(manualRetry.stepKind === kind &&
          (manualRetry.sessionStrategy === "resume" ||
            manualRetry.sessionStrategy === "fresh")
            ? { retrySessionStrategy: manualRetry.sessionStrategy }
            : {}),
        },
      ];
    })
    .map((step) => withConversationTurn(step, turns));
  // Over the context limit, tell the client whether Compact is an option.
  for (const step of steps) {
    if (step.errorCode !== "context_limit_exceeded") continue;
    Object.assign(step, {
      contextCompactionAvailable:
        (await contextCompactionUnavailable(env, {
          workRequestId,
          stepKind: step.kind,
          workerTypeId: step.workerTypeId,
        })) === null,
    });
  }
  const errorCode =
    [...steps]
      .reverse()
      .map((step) => step.errorCode)
      .find((code) => code !== null) ?? null;
  const workflowRun =
    (await loadConversationWorkflowRuns(env.SYNTILA_DB, [workRequestId])).get(
      workRequestId,
    ) ?? null;
  const activities = await loadWorkRequestActivityHistory(
    env.SYNTILA_DB,
    workRequestId,
  );
  const inputRows = await loadWorkRequestInputs(env.SYNTILA_DB, workRequestId);
  const inputs = inputProgress(inputRows);
  return json({
    workRequest: {
      ...(inputs.length > 0 ? { inputs } : {}),
      workflowRun,
      turns,
      executionConfig: snapshot.turnExecutionConfig ?? null,
      conversationId: row.conversationId ?? null,
      id: String(row.id),
      requestedByUserId: String(row.requestedByUserId),
      requestedByName: String(row.requestedByName ?? "Team member"),
      status: String(row.status),
      workflowId: String(row.workflowId),
      workflowVersion: Number(row.workflowVersion),
      workflowName: historicalWorkflowName(
        workflow,
        row.workflowId,
        row.workflowVersion,
      ),
      replyTo: storedReplyReference(input.replyTo),
      attachments: workRequestFileMetadata(withInputFacts(input, inputRows)),
      originalRequest: String(
        row.canonicalUserText ?? input.originalRequest ?? input.request ?? "",
      ),
      createdAt: String(row.createdAt),
      updatedAt: String(row.updatedAt),
      activities,
      ...requestExecutionFields(String(row.status), steps),
    },
    workflowSnapshot: workflow,
    steps,
    result,
    errorCode,
    errorMessage: errorCode ? executionErrorMessage(errorCode) : null,
  });
}

/** Cloud-derived execution state for one step; see execution-phase.ts. */
function stepExecutionFields(
  task: Record<string, unknown> | undefined,
  errorCode: string | null,
) {
  const text = (value: unknown) => (typeof value === "string" ? value : null);
  return presentExecution({
    assignmentStatus: text(task?.assignmentStatus),
    taskStatus: text(task?.status),
    dispatchedAt: text(task?.dispatchedAt),
    acknowledgedAt: text(task?.acknowledgedAt),
    startPermitIssuedAt: text(task?.startPermitIssuedAt),
    startPermitRequired: Number(task?.startPermitRequired ?? 0) === 1,
    runningAt: text(task?.runningAt),
    startupStage: text(task?.startupStage),
    errorJson: text(task?.assignmentErrorJson),
    errorCode,
  });
}

function requestExecutionFields(
  requestStatus: string,
  steps: ReadonlyArray<{ executionPhase: ExecutionPhase }>,
) {
  return {
    executionPhase: deriveRequestExecutionPhase(
      requestStatus,
      steps.map((step) => step.executionPhase),
    ),
  };
}

/** Requests created at or before this instant are hidden from AI History. */
async function aiHistoryClearedAt(
  env: SecurityEnv,
  threadId: string,
): Promise<string | null> {
  const row = await env.SYNTILA_DB.prepare(
    "SELECT ai_history_cleared_at AS clearedAt FROM threads WHERE id = ?1",
  )
    .bind(threadId)
    .first<{ clearedAt: string | null }>();
  return row?.clearedAt ?? null;
}

export async function handleListWorkRequests(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  // Older AX clients could retain a retired `workstream-*` scope and keep
  // polling it after the server-side thread model changed. Authenticate the
  // request, then return an empty history so stale caches converge without
  // exposing whether that legacy identifier ever existed.
  if (threadId.startsWith("workstream-")) {
    await securityContext(request, env, accessContext);
    return json({ workRequests: [], nextCursor: null });
  }
  await authorizeThreadAccess(request, env, threadId, "view", accessContext);
  const url = new URL(request.url);
  const rawLimit = Number(url.searchParams.get("limit") ?? 100);
  const limit = Number.isInteger(rawLimit)
    ? Math.min(100, Math.max(1, rawLimit))
    : 100;
  const beforeCreatedAt = url.searchParams.get("beforeCreatedAt");
  const beforeId = url.searchParams.get("beforeId");
  const activeOnly = url.searchParams.get("activeOnly") === "true";
  const recentCutoff = new Date(Date.now() - 15 * 60_000).toISOString();
  const page = await env.SYNTILA_DB.prepare(
    `SELECT wr.id, wr.requested_by_user_id AS requestedByUserId,
            (SELECT conversation_id FROM conversation_work_requests WHERE work_request_id = wr.id) AS conversationId,
            u.display_name AS requestedByName, wr.workflow_id AS workflowId,
            wr.workflow_version AS workflowVersion,
            wr.workflow_snapshot_json AS workflowSnapshotJson,
            wr.snapshot_json AS snapshotJson, (SELECT text FROM conversation_history_entries h WHERE h.work_request_id = wr.id AND h.kind = 'user_message' LIMIT 1) AS canonicalUserText, wr.input_json AS inputJson,
            wr.status, wr.created_at AS createdAt, wr.updated_at AS updatedAt
       FROM work_requests wr
       JOIN users u ON u.id = wr.requested_by_user_id
      WHERE wr.thread_id = ?1
        AND (?2 IS NULL OR wr.created_at < ?2 OR (wr.created_at = ?2 AND wr.id < ?3))
        AND (?4 = 0 OR wr.status IN ('queued', 'running', 'waiting') OR wr.updated_at >= ?5)
      ORDER BY wr.created_at DESC, wr.id DESC LIMIT ?6`,
  )
    .bind(
      threadId,
      beforeCreatedAt,
      beforeId,
      activeOnly ? 1 : 0,
      recentCutoff,
      limit,
    )
    .all<Record<string, unknown>>();
  const requests = page.results ?? [];
  if (requests.length === 0)
    return json({
      aiHistoryClearedAt: await aiHistoryClearedAt(env, threadId),
      workRequests: [],
      nextCursor: null,
    });
  const ids = requests.map((row) => String(row.id));
  const turnsByRequest = await loadConversationTurns(env.SYNTILA_DB, ids);
  const workflowRunsByRequest = await loadConversationWorkflowRuns(
    env.SYNTILA_DB,
    ids,
  );
  const placeholders = ids.map((_, index) => `?${index + 1}`).join(", ");
  const desiredWorkerIds = new Set<string>();
  for (const row of requests) {
    const requestSnapshot = parseJson<Record<string, unknown>>(
      typeof row.snapshotJson === "string" ? row.snapshotJson : null,
      {},
    );
    const requestBindings = requestSnapshot.resolvedBindings;
    if (typeof requestBindings !== "object" || requestBindings === null)
      continue;
    for (const value of Object.values(requestBindings)) {
      if (
        typeof value === "object" &&
        value !== null &&
        typeof (value as Record<string, unknown>).workerId === "string"
      ) {
        desiredWorkerIds.add(
          (value as Record<string, unknown>).workerId as string,
        );
      }
    }
  }
  const desiredWorkers = new Map<string, Record<string, unknown>>();
  if (desiredWorkerIds.size > 0) {
    const workerPlaceholders = [...desiredWorkerIds]
      .map((_, index) => `?${index + 1}`)
      .join(", ");
    const workerRows = await env.SYNTILA_DB.prepare(
      `SELECT worker_id AS workerId, worker_type_id AS workerTypeId,
              engine_version AS engineVersion,
              profile_definition_id AS profileDefinitionId,
              profile_release_version AS profileReleaseVersion,
              provider_tool_name AS providerToolName,
              provider_tool_version AS providerToolVersion
         FROM workspace_worker_inventory WHERE worker_id IN (${workerPlaceholders})`,
    )
      .bind(...desiredWorkerIds)
      .all<Record<string, unknown>>();
    for (const worker of workerRows.results ?? []) {
      desiredWorkers.set(String(worker.workerId), worker);
    }
  }
  const taskRows = await env.SYNTILA_DB.prepare(
    `SELECT wt.work_request_id AS workRequestId, wt.step_kind AS kind,
            wt.status, wt.output_json AS outputJson, wt.error,
            COALESCE(wt.started_at, wt.created_at) AS startedAt,
            COALESCE(wt.finished_at, wt.updated_at) AS updatedAt,
            wa.error_json AS assignmentErrorJson,
            wa.status AS assignmentStatus, wa.dispatched_at AS dispatchedAt,
            wa.acknowledged_at AS acknowledgedAt,
            wa.start_permit_issued_at AS startPermitIssuedAt,
            wa.start_permit_required AS startPermitRequired,
            wa.running_at AS runningAt, wa.startup_stage AS startupStage,
            wa.id AS assignmentId, wa.workspace_worker_id AS workerId,
            wa.worker_type_id AS logicalWorkerTypeId,
            wa.model AS assignedModel,
            wa.engine_version AS engineVersion,
            json_extract(wa.permission_snapshot_json, '$.executionSelection.modelName') AS modelName,
            json_extract(wa.permission_snapshot_json, '$.executionSelection.catalogRevision') AS catalogRevision,
            wa.permission_snapshot_json AS permissionSnapshotJson,
            wi.worker_type_id AS inventoryWorkerTypeId,
            wi.provider_tool_name AS configuredProviderToolName,
            wi.provider_tool_version AS configuredProviderToolVersion
       FROM workflow_tasks wt
       JOIN work_requests wr ON wr.id = wt.work_request_id
       LEFT JOIN worker_assignments wa ON wa.id = (
         SELECT wa2.id FROM worker_assignments wa2
          WHERE wa2.task_id = wt.id
          ORDER BY wa2.created_at DESC, wa2.id DESC LIMIT 1
       )
       LEFT JOIN workspace_worker_inventory wi ON wi.worker_id = COALESCE(
         wa.workspace_worker_id,
         json_extract(wr.snapshot_json, '$.resolvedBindings.' ||
           CASE WHEN wr.workflow_id = 'direct' THEN 'direct' ELSE wt.step_kind END || '.workerId')
       )
      WHERE wt.work_request_id IN (${placeholders})
      ORDER BY wt.created_at, wt.id`,
  )
    .bind(...ids)
    .all<Record<string, unknown>>();
  const tasksByRequest = new Map<string, Record<string, unknown>[]>();
  for (const task of taskRows.results ?? []) {
    const key = String(task.workRequestId);
    const values = tasksByRequest.get(key) ?? [];
    values.push(task);
    tasksByRequest.set(key, values);
  }
  const inputsByRequest = await loadInputsForRequests(env.SYNTILA_DB, ids);
  const workRequests = requests.map((row) => {
    const id = String(row.id);
    const input = parseJson<Record<string, unknown>>(String(row.inputJson), {});
    const workflow = parseJson<Record<string, unknown>>(
      String(row.workflowSnapshotJson),
      {},
    );
    const snapshot = parseJson<Record<string, unknown>>(
      typeof row.snapshotJson === "string" ? row.snapshotJson : null,
      {},
    );
    const bindings =
      typeof snapshot.resolvedBindings === "object" &&
      snapshot.resolvedBindings !== null
        ? (snapshot.resolvedBindings as Record<string, unknown>)
        : {};
    const persistedTasks = tasksByRequest.get(id) ?? [];
    const taskByKind = new Map(
      persistedTasks.map((task) => [String(task.kind), task]),
    );
    const workflowSteps = Array.isArray(workflow.steps) ? workflow.steps : [];
    const steps = workflowSteps
      .flatMap((value) => {
        if (!value || typeof value !== "object") return [];
        const definition = value as Record<string, unknown>;
        const kind = String(definition.kind ?? "implement");
        const task = taskByKind.get(kind);
        const bindingId = row.workflowId === "direct" ? "direct" : kind;
        const bindingValue = bindings[bindingId];
        const binding =
          typeof bindingValue === "object" && bindingValue !== null
            ? (bindingValue as Record<string, unknown>)
            : {};
        const executionConfig = (
          snapshot.stepExecutionConfigs as
            Record<string, Record<string, unknown>> | undefined
        )?.[kind];
        const desiredWorker =
          typeof binding.workerId === "string"
            ? desiredWorkers.get(binding.workerId)
            : undefined;
        const output =
          typeof task?.outputJson === "string"
            ? parseJson<Record<string, unknown>>(task.outputJson, {})
            : {};
        const permissionSnapshot = parseJson<Record<string, unknown>>(
          typeof task?.permissionSnapshotJson === "string"
            ? task.permissionSnapshotJson
            : null,
          {},
        );
        const hasAssignment = typeof task?.workerId === "string";
        const testSummary =
          kind === "test" && typeof output.text === "string"
            ? summarizeTestCounts(output.text)
            : null;
        const assignmentError = parseJson<Record<string, unknown>>(
          typeof task?.assignmentErrorJson === "string"
            ? task.assignmentErrorJson
            : null,
          {},
        );
        const assignmentErrorValue = assignmentError.error;
        const assignmentErrorDetail =
          typeof assignmentErrorValue === "object" &&
          assignmentErrorValue !== null
            ? (assignmentErrorValue as Record<string, unknown>)
            : {};
        const stableErrorCode =
          typeof assignmentErrorDetail.code === "string"
            ? canonicalExecutionErrorCode(assignmentErrorDetail.code)
            : typeof task?.error === "string"
              ? canonicalExecutionErrorCode(task.error)
              : null;
        const created = task?.startedAt
          ? Date.parse(String(task.startedAt))
          : NaN;
        const updated = task?.updatedAt
          ? Date.parse(String(task.updatedAt))
          : Date.now();
        const finished = ["completed", "failed", "cancelled"].includes(
          String(task?.status),
        );
        return [
          {
            kind,
            assignmentId:
              typeof task?.assignmentId === "string" ? task.assignmentId : null,
            status: String(
              task?.status ?? (row.status === "queued" ? "queued" : "waiting"),
            ),
            workerId: task?.workerId ?? binding.workerId ?? null,
            workerTypeId: hasAssignment
              ? (task?.logicalWorkerTypeId ?? null)
              : (task?.inventoryWorkerTypeId ??
                desiredWorker?.workerTypeId ??
                null),
            workerDisplayName: hasAssignment
              ? ((
                  permissionSnapshot.executionSelection as
                    Record<string, unknown> | undefined
                )?.workerDisplayName ??
                permissionSnapshot.workerDisplayName ??
                null)
              : (desiredWorker?.displayName ?? null),
            engineVersion: hasAssignment
              ? typeof permissionSnapshot.profileDefinitionId === "string"
                ? (task?.engineVersion ?? null)
                : null
              : (desiredWorker?.engineVersion ?? null),
            profileDefinitionId: hasAssignment
              ? typeof permissionSnapshot.profileDefinitionId === "string"
                ? permissionSnapshot.profileDefinitionId
                : null
              : (executionConfig?.profileId ?? null),
            profileReleaseVersion: hasAssignment
              ? Number.isSafeInteger(permissionSnapshot.profileReleaseVersion)
                ? permissionSnapshot.profileReleaseVersion
                : null
              : (executionConfig?.profileReleaseVersion ?? null),
            reasoningEffort: hasAssignment
              ? ((
                  permissionSnapshot.executionSelection as
                    Record<string, unknown> | undefined
                )?.effort ??
                permissionSnapshot.reasoningEffort ??
                null)
              : (binding.reasoningEffort ?? null),
            modelName: hasAssignment ? (task?.modelName ?? null) : null,
            catalogRevision: hasAssignment
              ? (task?.catalogRevision ?? null)
              : null,
            model: hasAssignment
              ? (task?.assignedModel ?? null)
              : typeof binding.model === "string"
                ? binding.model
                : null,
            providerToolName:
              (typeof permissionSnapshot.providerToolName === "string"
                ? permissionSnapshot.providerToolName
                : null) ??
              (hasAssignment ? null : task?.configuredProviderToolName) ??
              desiredWorker?.providerToolName ??
              null,
            providerToolVersion:
              (typeof permissionSnapshot.providerToolVersion === "string"
                ? permissionSnapshot.providerToolVersion
                : null) ??
              (hasAssignment ? null : task?.configuredProviderToolVersion) ??
              desiredWorker?.providerToolVersion ??
              null,
            startedAt: task?.startedAt ?? null,
            updatedAt: task?.updatedAt ?? null,
            elapsedMs: Number.isFinite(created)
              ? Math.max(0, (finished ? updated : Date.now()) - created)
              : null,
            finalText: typeof output.text === "string" ? output.text : null,
            ...(testSummary ? { testSummary } : {}),
            errorCode: stableErrorCode,
            errorMessage: stableErrorCode
              ? executionErrorMessage(stableErrorCode)
              : null,
            error: typeof task?.error === "string" ? task.error : null,
            ...stepExecutionFields(task, stableErrorCode),
          },
        ];
      })
      .map((step) => withConversationTurn(step, turnsByRequest.get(id) ?? []));
    const terminalStep = steps.at(-1);
    const finalText =
      row.status === "completed" && terminalStep?.status === "completed"
        ? terminalStep.finalText
        : null;
    const errorCode =
      [...steps]
        .reverse()
        .map((step) => step.errorCode)
        .find((code) => typeof code === "string" && code.length > 0) ?? null;
    return {
      id,
      conversationId: row.conversationId ?? null,
      requestedByName: String(row.requestedByName ?? "Team member"),
      turns: turnsByRequest.get(id) ?? [],
      workflowRun: workflowRunsByRequest.get(id) ?? null,
      executionConfig: snapshot.turnExecutionConfig ?? null,
      replyTo: storedReplyReference(input.replyTo),
      attachments: workRequestFileMetadata(
        withInputFacts(input, inputsByRequest.get(id)),
      ),
      prompt: String(
        row.canonicalUserText ?? input.originalRequest ?? input.request ?? "",
      ),
      workflowId: String(row.workflowId),
      workflowVersion: Number(row.workflowVersion),
      workflowName: historicalWorkflowName(
        workflow,
        row.workflowId,
        row.workflowVersion,
      ),
      status: String(row.status),
      createdAt: String(row.createdAt),
      updatedAt: String(row.updatedAt),
      ...requestExecutionFields(String(row.status), steps),
      steps: steps.map(({ finalText: _text, error: _error, ...step }) => step),
      ...(finalText ? { finalText } : {}),
      // A user-cancelled request is not a failure; its stopped Step may still
      // carry an error code, which stays available in Run details.
      ...(errorCode && row.status !== "cancelled"
        ? {
            errorCode,
            error:
              "A Step could not be completed. Open Run details for the safe error code.",
          }
        : {}),
    };
  });
  const last = requests.at(-1)!;
  return json({
    aiHistoryClearedAt: await aiHistoryClearedAt(env, threadId),
    workRequests,
    nextCursor:
      requests.length === limit
        ? { createdAt: String(last.createdAt), id: String(last.id) }
        : null,
  });
}

export async function handleCancelWorkRequest(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const response = await cancelWorkRequest(
    request,
    env,
    workRequestId,
    accessContext,
  );
  // A cancelled request may free the Thread for its next queued request.
  const thread = await env.SYNTILA_DB.prepare(
    "SELECT thread_id AS threadId FROM work_requests WHERE id = ?1",
  )
    .bind(workRequestId)
    .first<{ threadId: string }>();
  if (thread) await advanceThreadQueueSafely(env, thread.threadId);
  return response;
}

async function cancelWorkRequest(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const row = await env.SYNTILA_DB.prepare(
    "SELECT thread_id AS threadId, mode, status, cancel_requested_at AS cancelRequestedAt, requested_by_user_id AS requestedByUserId FROM work_requests WHERE id = ?1",
  )
    .bind(workRequestId)
    .first<{
      threadId: string;
      mode: string;
      status: string;
      cancelRequestedAt: string | null;
      requestedByUserId: string;
    }>();
  if (!row) throw new HttpError(404, "Work Request not found");
  const { context } = await authorizeThreadAccess(
    request,
    env,
    row.threadId,
    "execute",
    accessContext,
  );
  // Members share a Thread's requests but cancel only their own.
  if (row.requestedByUserId !== context.userId)
    throw new HttpError(
      403,
      "Only the person who sent this request can cancel it",
    );
  if (row.status === "cancelled")
    return json({ workRequestId, status: "cancelled" });
  if (row.status === "failed") {
    const now = new Date().toISOString();
    await env.SYNTILA_DB.batch([
      env.SYNTILA_DB.prepare(
        "UPDATE work_requests SET status = 'cancelled', updated_at = ?1 WHERE id = ?2 AND status = 'failed'",
      ).bind(now, workRequestId),
      env.SYNTILA_DB.prepare(
        `UPDATE runs SET status = 'cancelled', finished_at = ?1, updated_at = ?1
          WHERE id = (SELECT id FROM runs WHERE work_request_id = ?2 AND status = 'failed'
                     ORDER BY created_at DESC, id DESC LIMIT 1)`,
      ).bind(now, workRequestId),
      env.SYNTILA_DB.prepare(
        `UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1
          WHERE work_request_id = ?2 AND status IN ('queued', 'waiting')`,
      ).bind(now, workRequestId),
    ]);
    return json({ workRequestId, status: "cancelled" });
  }
  if (row.status === "queued" && row.mode === "stateful") {
    if (!env.SYNTILA_THREAD_COORDINATOR)
      throw new HttpError(503, "Thread execution coordinator unavailable");
    const coordinator = env.SYNTILA_THREAD_COORDINATOR.getByName(row.threadId);
    return coordinator.fetch(
      new Request("https://thread-coordinator/cancel", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-thread-id": row.threadId,
        },
        body: JSON.stringify({ workRequestId }),
      }),
    );
  }
  if (row.status === "queued") {
    const now = new Date().toISOString();
    await env.SYNTILA_DB.batch([
      env.SYNTILA_DB.prepare(
        "UPDATE work_requests SET status = 'cancelled', updated_at = ?1 WHERE id = ?2 AND status = 'queued'",
      ).bind(now, workRequestId),
      env.SYNTILA_DB.prepare(
        "UPDATE runs SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status = 'created'",
      ).bind(now, workRequestId),
      env.SYNTILA_DB.prepare(
        "UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status IN ('queued', 'waiting')",
      ).bind(now, workRequestId),
    ]);
    return json({ workRequestId, status: "cancelled" });
  }
  if (row.status !== "running")
    throw new HttpError(409, "This Work Request cannot be cancelled");

  const requestedAt = row.cancelRequestedAt ?? new Date().toISOString();
  await env.SYNTILA_DB.prepare(
    "UPDATE work_requests SET cancel_requested_at = COALESCE(cancel_requested_at, ?1), updated_at = ?1 WHERE id = ?2 AND status = 'running'",
  )
    .bind(requestedAt, workRequestId)
    .run();

  const active = await env.SYNTILA_DB.prepare(
    `SELECT wa.id AS assignmentId, wa.execution_workspace_id AS workspaceId,
            wa.status AS assignmentStatus
       FROM workflow_tasks wt
       JOIN worker_assignments wa ON wa.task_id = wt.id
      WHERE wt.work_request_id = ?1
        AND wa.status IN (${ACTIVE_ASSIGNMENT_STATUS_SQL})
      ORDER BY wa.created_at DESC LIMIT 1`,
  )
    .bind(workRequestId)
    .first<{
      assignmentId: string;
      workspaceId: string;
      assignmentStatus: string;
    }>();
  if (active) {
    const cancellation = await cancelTaskAssignment(
      env as unknown as AssignmentDispatcherEnv,
      active.workspaceId,
      active.assignmentId,
      "Work Request cancelled from Work chat",
    );
    if (!cancellation.cancelled)
      throw new HttpError(
        503,
        "Workspace did not confirm that the Worker process tree stopped. The Run remains active; retry cancellation.",
      );
  }

  const now = new Date().toISOString();
  await env.SYNTILA_DB.batch([
    env.SYNTILA_DB.prepare(
      "UPDATE work_requests SET status = 'cancelled', updated_at = ?1 WHERE id = ?2 AND status = 'running'",
    ).bind(now, workRequestId),
    env.SYNTILA_DB.prepare(
      "UPDATE runs SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status IN ('created', 'running')",
    ).bind(now, workRequestId),
    env.SYNTILA_DB.prepare(
      "UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status IN ('queued', 'waiting')",
    ).bind(now, workRequestId),
  ]);
  await releaseThreadLeaseAfterCancel(env, row.threadId, workRequestId);
  if (!active) {
    await env.SYNTILA_DB.prepare(
      "UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status = 'running'",
    )
      .bind(now, workRequestId)
      .run();
    const run = await env.SYNTILA_DB.prepare(
      "SELECT id FROM runs WHERE work_request_id = ?1 ORDER BY created_at DESC LIMIT 1",
    )
      .bind(workRequestId)
      .first<{ id: string }>();
    if (run && env.SYNTILA_RUN_WORKFLOW) {
      const instanceId = await resolveWorkflowInstanceId(env, run.id);
      const instance = await env.SYNTILA_RUN_WORKFLOW.get(instanceId);
      await instance.terminate();
    }
  }
  return json({ workRequestId, status: "cancelled" });
}

export async function handleClearWorkHistory(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  context?: ExecutionContext,
): Promise<Response> {
  const authorization = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "view",
    context,
  );

  const receipt = await MutationIdempotency.from(
    request,
    env.SYNTILA_DB,
    authorization.context.userId,
    `thread:${threadId}:clear-work-history`,
    {},
  );
  const thread = await env.SYNTILA_DB.prepare(
    "SELECT space_id AS spaceId FROM threads WHERE id = ?1",
  )
    .bind(threadId)
    .first<{ spaceId: string }>();
  if (!thread) throw new HttpError(404, "Thread not found");

  // A retried request may follow a commit whose event was never published, so
  // replays announce the clear again. The event is an idempotent invalidation.
  const announce = () =>
    publishCollaborationEvent(
      env,
      "thread.work_cleared",
      thread.spaceId,
      threadId,
      { threadId },
    );
  const replay = await receipt?.replay();
  if (replay) {
    await announce();
    return replay;
  }

  // AI History is cut off, not deleted: the Conversation keeps every request
  // and answer as they were. Worker sessions restart, and the context floor
  // keeps cleared exchanges out of any later Worker's context.
  const now = new Date().toISOString();
  const statements = [
    env.SYNTILA_DB.prepare(
      `UPDATE conversations SET context_floor_sequence = COALESCE(
         (SELECT MAX(sequence) FROM conversation_history_entries h
           WHERE h.conversation_id = conversations.id), 0)
       WHERE thread_id = ?1`,
    ).bind(threadId),
    env.SYNTILA_DB.prepare(
      `UPDATE threads SET ai_history_cleared_at = ?1,
         work_session_generation = work_session_generation + 1,
         ai_context_generation = ai_context_generation + 1, updated_at = ?1
       WHERE id = ?2`,
    ).bind(now, threadId),
  ];
  statements.push(
    threadNotice(
      env,
      threadId,
      authorization.context.userId,
      authorization.context.user.displayName || "Member",
      "ai.context_reset",
      "reset AI context. Future AI requests will start with fresh context.",
      now,
    ),
  );
  const body = { threadId, cleared: true, aiHistoryClearedAt: now };
  const reply = receipt
    ? await receipt.commit(body, 200, (receiptStatements) =>
        env.SYNTILA_DB.batch([...statements, ...receiptStatements]),
      )
    : (await env.SYNTILA_DB.batch(statements), null);

  await announce();

  return reply ?? json(body);
}

/**
 * A cancelled stateful Work Request must give up its Thread runtime lease.
 * Otherwise the lease stays active until it expires and the next request on
 * the Thread cannot start, which surfaces as a misleading "no eligible
 * Worker" failure. `complete` is idempotent for a lease that is already gone.
 */
async function releaseThreadLeaseAfterCancel(
  env: SecurityEnv,
  threadId: string,
  workRequestId: string,
): Promise<void> {
  const namespace = env.SYNTILA_THREAD_COORDINATOR;
  if (!namespace) return;
  const lease = await env.SYNTILA_DB.prepare(
    `SELECT id, fencing_token AS fencingToken FROM thread_runtime_leases
      WHERE work_request_id = ?1 AND thread_id = ?2 AND status = 'active'
      LIMIT 1`,
  )
    .bind(workRequestId, threadId)
    .first<{ id: string; fencingToken: number }>();
  if (!lease) return;
  const response = await namespace.getByName(threadId).fetch(
    new Request("https://thread-coordinator/complete", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-thread-id": threadId,
      },
      body: JSON.stringify({
        workRequestId,
        leaseId: lease.id,
        fencingToken: lease.fencingToken,
        status: "cancelled",
      }),
    }),
  );
  if (!response.ok)
    throw new HttpError(503, "Thread execution coordinator unavailable");
}
