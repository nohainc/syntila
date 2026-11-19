import { dataOf, type Db } from "../platform/data.js";
import { executionErrorMessage } from "@syntila/protocol";
import { ContextLimitError } from "@syntila/core";
import { createHash } from "node:crypto";
import {
  failOrRevokeDispatch,
  recordAssignmentCancelled,
  type AssignmentDispatcherEnv,
  type DispatchAssignmentParams,
  type DispatchAssignmentResult,
} from "./assignment-dispatcher.js";
import { acceptWorkerTarget, type WorkerTargetSnapshot } from "./worker-eligibility.js";
import { loadConversationBootstrap } from "./routes/conversation-bootstrap.js";
import { tryLogDiagnosticEvent } from "./observability.js";
import { publishAssignmentPhase } from "./assignment-phase-events.js";
import { DEFAULT_QUEUE_WAIT_TIMEOUT_MS } from "./assignment-delivery.js";
import { assignmentSourceStatusList } from "./assignment-transitions.js";
import { executionSlotAdmission } from "./account-plan.js";
import {
  clearExecutionWaiter,
  executionSlotRefused,
  recordExecutionWaiter,
  waiterCutoff,
} from "./account-execution-slots.js";

/**
 * Worker-targeted dispatch (ADR-035). The Worker path of `dispatchTaskAssignment`.
 *
 * An assignment here targets a Worker Instance, not a Workspace:
 *  - the row is created with `execution_path = 'worker'`, no Workspace or
 *    runtime identity, and the acceptance snapshot (migration 0029);
 *  - the command goes to the Worker's inbox (`agent_commands`) in the same
 *    transaction, and is delivered by the Worker gateway keyed by the Worker;
 *  - authority is the Agent session fence (ADR-034), never a Workspace runtime.
 *
 * Offline is a rejection, not a wait: with no live Agent session the request
 * fails with `worker_offline`. There is no queue and no other Worker is tried.
 */

/** A name for a gateway object that serves one Worker's Agent. */
export const workerGatewayName = (workerId: string): string => `worker:${workerId}`;

export interface WorkerDispatchEnv extends AssignmentDispatcherEnv {
  readonly SYNTILA_WORKER_GATEWAY?: DurableObjectNamespace;
}

export interface WorkerDispatchParams extends DispatchAssignmentParams {
  /** What was accepted: the Worker the request is bound to. */
  readonly workerTarget: WorkerTargetSnapshot;
}

function failed(error: string, workerId = ""): DispatchAssignmentResult {
  return {
    assignmentId: "",
    attemptId: "",
    workerId,
    workspaceRuntimeId: "",
    workerCatalogId: "",
    status: "failed",
    accepted: false,
    error,
  };
}

export async function dispatchWorkerAssignment(
  env: WorkerDispatchEnv,
  params: WorkerDispatchParams,
): Promise<DispatchAssignmentResult> {
  const { runId, taskId, task, workerTarget: accepted } = params;
  const requesterUserId = task.requestedByUserId!;
  const read = dataOf(env).read;

  // Every step re-checks eligibility against the Worker that was accepted: it
  // must still be the requester's, enabled, allowed in the Thread, and online.
  // Profile or name changes since acceptance do not matter; the snapshot does.
  const current = await acceptWorkerTarget(read, {
    workerId: accepted.workerId,
    requesterUserId,
    spaceId: task.spaceId!,
    threadId: task.threadId ?? accepted.threadId,
    workflowId: task.workBindingId === "chat" ? "chat" : "direct",
    model: accepted.model,
    reasoningEffort: accepted.reasoningEffort,
    readOnly: accepted.readOnly,
    capabilities: task.capabilities,
    requireOnline: true,
  });
  if (current.ok === false) {
    tryLogDiagnosticEvent({
      requestId: task.workRequestId,
      workerId: accepted.workerId,
      runId,
      taskId,
      component: "cloud",
      operation: "assignment",
      stage: "admission",
      severity: "warning",
      errorCode: current.code === "worker_offline" ? "worker_offline" : "worker_not_ready",
      retryable: false,
      context: { status: `rejected_${current.code}` },
    });
    return failed(
      current.code === "worker_offline"
        ? executionErrorMessage("worker_offline")
        : `Worker ${current.code}`,
      accepted.workerId,
    );
  }

  const attemptNumber = params.explicitAttemptNumber ?? 1;
  const randomPart = crypto.randomUUID().slice(0, 8);
  const attemptId = `att-${taskId}-${attemptNumber}-${Date.now()}-${randomPart}`;
  const assignmentId = `asg-${taskId}-${attemptNumber}-${Date.now()}-${randomPart}`;
  const idempotencyKey = `idem-${assignmentId}`;
  const timeoutMs = task.timeoutMs || 15 * 60_000;
  const queueWaitTimeoutMs = task.queueWaitTimeoutMs ?? DEFAULT_QUEUE_WAIT_TIMEOUT_MS;
  if (!Number.isSafeInteger(queueWaitTimeoutMs) || queueWaitTimeoutMs < 1_000 || queueWaitTimeoutMs > 2_147_483_647) {
    throw new Error("Assignment queueWaitTimeoutMs is outside the allowed range");
  }
  const sessionPolicy = task.sessionPolicy as string;
  const sessionKey = task.sessionKey;
  const assignmentInput = { ...(task.input ?? {}) };
  delete assignmentInput.externalWorkerConversation;
  delete assignmentInput.sessionPolicy;
  delete assignmentInput.sessionKey;
  delete assignmentInput.additionalFolderIds;

  const conversation = task.workRequestId
    ? await read.row<{ conversationId: string | null; baseContextRevision: number | null }>`SELECT cwr.conversation_id AS "conversationId",
              (cwr.conversation_revision - 1)::int AS "baseContextRevision"
         FROM conversation_work_requests cwr WHERE cwr.work_request_id = ${task.workRequestId}`
    : null;
  let bootstrap;
  if (conversation?.conversationId) {
    try {
      bootstrap = await loadConversationBootstrap(
        env.SYNTILA_DB as Db,
        conversation.conversationId,
        task.workRequestId!,
        conversation.baseContextRevision ?? 0,
        sessionPolicy === "stateless" ? "stateless" : "bootstrap",
        taskId,
      );
    } catch (error) {
      if (!(error instanceof ContextLimitError)) throw error;
      return failed("context_limit_exceeded", accepted.workerId);
    }
  }
  const workerSessionId =
    sessionPolicy === "durable_session"
      ? `worker-session-${createHash("sha256")
          .update(JSON.stringify([accepted.workerId, accepted.profile?.definitionId ?? null, conversation?.conversationId ?? null, sessionKey]))
          .digest("hex")}`
      : null;
  const permissionSnapshot = {
    permissions: accepted.permissions,
    ...(bootstrap
      ? {
          contextSnapshot: {
            schemaVersion: 1,
            baseContextRevision: bootstrap.contextRevision,
            turnRevision: bootstrap.turnRevision,
            throughSequence: bootstrap.throughSequence,
            digest: createHash("sha256").update(bootstrap.text).digest("hex"),
          },
        }
      : {}),
    baseContextRevision: conversation?.baseContextRevision ?? 0,
    workerSessionId,
  };

  const insertion = await dataOf(env).tx("assignment.admit_worker", async (tx) => {
    await tx.lock("syntila.execution_slots", requesterUserId);
    const created = new Date().toISOString();
    const inputJson = JSON.stringify(assignmentInput);
    // `workspace_worker_id` mirrors the Worker ID so readers that still key on
    // it keep working; the Workspace columns stay NULL on this path.
    return tx.row<{ id: string }>`INSERT INTO worker_assignments
       (id, space_id, run_id, task_id, attempt_id, requested_by_user_id,
        worker_type_id, workspace_worker_id, worker_instance_id,
        model, config_json, effective_permissions_json, permission_snapshot_json,
        timeout_ms, queue_wait_timeout_ms, session_policy, idempotency_key, status,
        input_json, created_at, updated_at, execution_path, worker_snapshot_json)
     SELECT ${assignmentId}::text, ${accepted.spaceId}::text, ${runId}::text, ${taskId}::text, ${attemptId}::text, ${requesterUserId}::text,
            ${accepted.workerTypeId}::text, ${accepted.workerId}::text, ${accepted.workerId}::text,
            ${accepted.model}::text, ${inputJson}::text, ${JSON.stringify(accepted.permissions)}::text, ${JSON.stringify(permissionSnapshot)}::text,
            ${timeoutMs}::bigint, ${queueWaitTimeoutMs}::bigint, ${sessionPolicy}::text, ${idempotencyKey}::text, 'created',
            ${inputJson}::text, ${created}::timestamptz, ${created}::timestamptz, 'worker', ${JSON.stringify(accepted)}::text
      WHERE ${executionSlotAdmission(tx, requesterUserId, taskId, waiterCutoff())}
     RETURNING id`;
  });
  if (insertion?.id !== assignmentId) {
    if (await executionSlotRefused(read, requesterUserId, taskId)) {
      await recordExecutionWaiter(read, {
        taskId,
        requesterUserId,
        runId,
        workRequestId: task.workRequestId,
        reason: "account_concurrency_limit",
      });
      return {
        assignmentId: "",
        attemptId: "",
        workerId: "",
        workspaceRuntimeId: "",
        workerCatalogId: "",
        status: "deferred",
        accepted: false,
        waitReason: "account_concurrency_limit",
      };
    }
    return failed("Worker capacity was claimed by another assignment", accepted.workerId);
  }
  await clearExecutionWaiter(read, taskId);

  if (task.workRequestId) {
    const cancellation = await read.row<{ cancelRequestedAt: string | null }>`SELECT cancel_requested_at AS "cancelRequestedAt"
       FROM work_requests WHERE id = ${task.workRequestId} AND status IN ('running', 'cancelled')`;
    if (cancellation?.cancelRequestedAt) {
      await recordAssignmentCancelled(env.SYNTILA_DB as Db, assignmentId, {
        status: "cancelled",
        reason: "Work Request cancellation was requested before dispatch",
      });
      return {
        assignmentId,
        attemptId,
        workerId: accepted.workerId,
        workspaceRuntimeId: "",
        workerCatalogId: accepted.workerTypeId,
        status: "cancelled",
        accepted: false,
        error: "Work assignment cancelled before dispatch",
      };
    }
  }

  const payload = {
    snapshot: {
      assignmentId,
      objective: task.objective,
      role: task.role,
      contextArtifactIds: task.contextArtifactIds ?? [],
      threadId: task.threadId ?? accepted.threadId,
      workRequestId: task.workRequestId,
      leaseId: task.leaseId,
      fencingToken: task.fencingToken,
      executionClass: task.executionClass ?? "stateless_read",
      readOnly: accepted.readOnly,
      spaceId: accepted.spaceId,
      runId,
      taskId,
      attemptId,
      requestedByUserId: requesterUserId,
      workerId: accepted.workerId,
      workerTypeId: accepted.workerTypeId,
      // The Profile the request was accepted with. The Agent runs exactly this
      // digest and revision, whatever has been published since.
      profileDefinitionId: accepted.profile?.definitionId ?? undefined,
      profileRevision: accepted.profile?.revision,
      profileDigest: accepted.profile?.digest,
      model: accepted.model,
      reasoningEffort: accepted.reasoningEffort,
      config: assignmentInput,
      permissions: accepted.permissions,
      permissionSnapshot,
      contextRefs: (task.contextArtifactIds ?? []).map((artifactId) => ({ artifactId })),
      timeoutMs,
      queueWaitTimeoutMs,
      sessionPolicy,
      ...(sessionKey !== undefined ? { sessionKey } : {}),
      ...(bootstrap && sessionPolicy === "stateless" ? { statelessContext: bootstrap } : {}),
      ...(conversation?.conversationId && sessionPolicy === "durable_session"
        ? {
            workerSession: {
              schemaVersion: 1,
              id: workerSessionId,
              conversationId: conversation.conversationId,
              workerId: accepted.workerId,
              baseContextRevision: conversation.baseContextRevision ?? 0,
              ...(bootstrap ? { bootstrap } : {}),
            },
          }
        : {}),
      idempotencyKey,
    },
    input: assignmentInput,
  };
  // The command is persisted before any delivery attempt, in the same
  // transaction as its inbox row, so it never exists without its payload.
  const ttlSeconds = Math.max(60, Math.ceil((queueWaitTimeoutMs + timeoutMs) / 1000) || 86_400);
  await dataOf(env).tx("assignment.command_worker", async (tx) => {
    await tx.run`UPDATE worker_assignments SET command_payload_json = ${JSON.stringify(payload)}
        WHERE id = ${assignmentId} AND status = 'created' AND command_payload_json IS NULL`;
    await tx.run`INSERT INTO agent_commands
          (command_id, worker_instance_id, assignment_id, attempt_id, type, payload_ref, expires_at)
        VALUES (${`cmd-${crypto.randomUUID()}`}, ${accepted.workerId}, ${assignmentId}, ${attemptId},
                'assignment.dispatch', ${`worker_assignments:${assignmentId}`},
                now() + make_interval(secs => ${ttlSeconds}::int))
        ON CONFLICT (assignment_id, type) DO NOTHING`;
  });

  const code = "provider_unavailable" as const;
  const fail = async (diagnostic: string): Promise<DispatchAssignmentResult> => {
    await failOrRevokeDispatch(env, assignmentId, attemptId, {
      error: { code, message: executionErrorMessage(code), retryable: true, details: { diagnostic } },
      failedAt: new Date().toISOString(),
    });
    return {
      assignmentId,
      attemptId,
      workerId: accepted.workerId,
      workspaceRuntimeId: "",
      workerCatalogId: accepted.workerTypeId,
      status: "failed",
      accepted: false,
      error: executionErrorMessage(code),
    };
  };
  const gateways = env.SYNTILA_WORKER_GATEWAY;
  if (!gateways) return fail("Worker gateway is not configured");
  try {
    const response = await gateways
      .get(gateways.idFromName(workerGatewayName(accepted.workerId)))
      .fetch("http://gateway/dispatch-assignment", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ workerId: accepted.workerId, runId, taskId, attemptId, assignmentId, idempotencyKey, payload }),
      });
    if (!response.ok) throw new Error(`Gateway returned HTTP ${response.status}`);
    const delivery = (await response.clone().json().catch(() => ({}))) as { delivered?: boolean; offline?: boolean };
    if (delivery.offline === true) {
      // The Agent went away between the check and the send. Nothing reached it.
      await failOrRevokeDispatch(env, assignmentId, attemptId, {
        error: {
          code: "worker_offline",
          message: executionErrorMessage("worker_offline"),
          retryable: false,
        },
        failedAt: new Date().toISOString(),
      });
      return {
        assignmentId,
        attemptId,
        workerId: accepted.workerId,
        workspaceRuntimeId: "",
        workerCatalogId: accepted.workerTypeId,
        status: "failed",
        accepted: false,
        error: executionErrorMessage("worker_offline"),
      };
    }
    const dispatchedAt = new Date().toISOString();
    await read.run`UPDATE worker_assignments SET status = 'dispatched', updated_at = ${dispatchedAt}::timestamptz,
              dispatched_at = COALESCE(dispatched_at, ${dispatchedAt}::timestamptz)
        WHERE id = ${assignmentId} AND status IN (${read.raw(assignmentSourceStatusList("dispatched"))})`;
    await publishAssignmentPhase(env, assignmentId);
  } catch {
    return fail("Worker gateway did not accept the assignment");
  }
  return {
    assignmentId,
    attemptId,
    workerId: accepted.workerId,
    workspaceRuntimeId: "",
    workerCatalogId: accepted.workerTypeId,
    status: "dispatched",
    accepted: true,
  };
}
