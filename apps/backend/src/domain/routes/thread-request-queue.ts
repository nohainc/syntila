import { QueueRequestSchema } from "@syntila/protocol";
import { readBody } from "./validation.js";
import { appendToQueue, enqueueAtPosition, enqueueBeforePhases, lockQueue, moveToFront } from "./queue-positions.js";
import { threadSpace } from "../queries.js";
import { publishCollaborationEvent } from "../collaboration-events.js";
import { HttpError, json, type SecurityEnv } from "./http-security.js";
import { requireWorkflowPermission } from "./space-permissions.js";
import {
  authorizeThreadAccess,
  authorizeThreadAccessAsUser,
} from "./thread-policy.js";
import { isFeatureEnabled } from "../../feature-flags.js";
import { createWorkRequestForUser } from "./work-creation.js";
import { dataOf, queryOf, type Query, atomically, type Db } from "../../platform/data.js";

const selectThreadRequestQueueByThreadId = <T = Record<string, unknown>>(q: Query, p1: unknown) =>
  q.row<T>`SELECT COUNT(*) AS n FROM thread_request_queue WHERE thread_id = ${p1}`;

/**
 * Thread request queue: requests members send while earlier ones are still
 * processing. The queue is shared by every member of the Thread. Cloud sends
 * the next request, as its author and with that author's Space permissions
 * and Worker selection, whenever the Thread has nothing processing, so the
 * queue keeps moving after its authors close the app.
 *
 * Any member who can send requests may pause or resume the queue. Only the
 * author may edit, remove, or move their own queued request to the front.
 */

/**
 * Work that keeps the queue waiting. A phase that paused for input stays
 * `waiting` after its Workflow finished; it holds the remaining phases (the
 * queue pause), but not the requests people send in reply.
 */
const processingWork = (
  alias: string,
) => `(${alias}.status IN ('queued', 'running')
  OR (${alias}.status = 'waiting' AND (
    EXISTS (SELECT 1 FROM workflow_tasks pt WHERE pt.work_request_id = ${alias}.id
             AND pt.status IN ('queued', 'running', 'waiting'))
    OR NOT EXISTS (SELECT 1 FROM workflow_tasks pt WHERE pt.work_request_id = ${alias}.id))))`;
/** A send that has not finished in this time is retried by the sweep. */
const STALE_SENDING_MS = 2 * 60 * 1000;

interface QueueRow {
  id: string;
  threadId: string;
  authorUserId: string;
  authorName: string | null;
  requestJson: string;
  position: number;
  status: "queued" | "sending";
  createdAt: string;
  updatedAt: string;
}

interface StateRow {
  pausedReason: "user" | "failure";
  pausedByUserId: string | null;
  failureMessage: string | null;
}

function requestBody(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new HttpError(400, "request must be an object");
  const body = value as Record<string, unknown>;
  if (typeof body.workflowId !== "string" || !body.workflowId.trim())
    throw new HttpError(400, "request.workflowId is required");
  const input =
    body.input && typeof body.input === "object" && !Array.isArray(body.input)
      ? (body.input as Record<string, unknown>)
      : {};
  const attachments = input.attachments ?? body.attachments;
  if (attachments !== undefined && !Array.isArray(attachments))
    throw new HttpError(400, "attachments must be an array");
  // Cloud sends queued requests later, possibly with the author offline, so
  // a file still waiting to be uploaded from their device cannot be queued.
  if (
    Array.isArray(attachments) &&
    attachments.some(
      (item) =>
        item &&
        typeof item === "object" &&
        (item as Record<string, unknown>).delivery === "upload",
    )
  )
    throw new HttpError(
      400,
      "Files from this device cannot wait in the queue. Send the request when nothing is processing, or attach the file from My Files.",
    );
  if (JSON.stringify(body).length > 256 * 1024)
    throw new HttpError(413, "The queued request is too large");
  return body;
}

async function loadQueue(env: SecurityEnv, threadId: string) {
  const [items, state] = await Promise.all([
    dataOf(env).read.rows<QueueRow>`SELECT q.id, q.thread_id AS "threadId", q.author_user_id AS "authorUserId",
              u.display_name AS "authorName", q.request_json AS "requestJson",
              q.position, q.status, q.created_at AS "createdAt",
              q.updated_at AS "updatedAt"
         FROM thread_request_queue q
         LEFT JOIN users u ON u.id = q.author_user_id
        WHERE q.thread_id = ${threadId}
        ORDER BY q.position, q.created_at, q.id`,
    dataOf(env).read.row<StateRow>`SELECT paused_reason AS "pausedReason", paused_by_user_id AS "pausedByUserId",
              failure_message AS "failureMessage"
         FROM thread_request_queue_state WHERE thread_id = ${threadId}`,
  ]);
  return { items, state: state ?? null };
}

function queueResponse(
  queue: Awaited<ReturnType<typeof loadQueue>>,
  status = 200,
) {
  return json(
    {
      paused: queue.state !== null,
      pauseReason: queue.state?.pausedReason ?? null,
      pausedByUserId: queue.state?.pausedByUserId ?? null,
      failureMessage: queue.state?.failureMessage ?? null,
      items: queue.items.map((item) => ({
        id: item.id,
        authorUserId: item.authorUserId,
        authorName: item.authorName ?? "",
        status: item.status,
        request: JSON.parse(item.requestJson) as unknown,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt,
      })),
    },
    { status },
  );
}

async function threadSpaceId(env: SecurityEnv, threadId: string) {
  const row = await threadSpace(dataOf(env).read, threadId);
  return row?.spaceId ?? null;
}

async function publishQueueUpdated(
  env: SecurityEnv,
  threadId: string,
  spaceId?: string | null,
) {
  const space = spaceId ?? (await threadSpaceId(env, threadId));
  if (!space) return;
  try {
    await publishCollaborationEvent(
      env,
      "thread.queue_updated",
      space,
      threadId,
      { threadId },
    );
  } catch (error) {
    console.error("Failed to publish thread.queue_updated", error);
  }
}

/**
 * Phases queued with a Worker ID in `executionSelection` (older plan approvals)
 * run on the Worker path, which takes it as `workerId`.
 */
function withWorkerTarget(
  body: Record<string, unknown>,
): Record<string, unknown> {
  const selection = body.executionSelection;
  if (
    !isFeatureEnabled("worker_target_dispatch") ||
    body.workerId !== undefined ||
    !selection ||
    typeof selection !== "object" ||
    typeof (selection as { workerId?: unknown }).workerId !== "string"
  )
    return body;
  const { executionSelection: _legacy, ...rest } = body;
  const { workerId, model, reasoningEffort } = selection as Record<
    string,
    unknown
  >;
  return {
    ...rest,
    workerId,
    ...(typeof model === "string" ? { model } : {}),
    ...(typeof reasoningEffort === "string" ? { reasoningEffort } : {}),
  };
}

async function pause(
  env: SecurityEnv,
  threadId: string,
  reason: "user" | "failure",
  userId: string | null,
  message: string | null,
) {
  await dataOf(env).read.run`INSERT INTO thread_request_queue_state
       (thread_id, paused_reason, paused_by_user_id, failure_message, updated_at)
     VALUES (${threadId}, ${reason}, ${userId}, ${message}, ${new Date().toISOString()})
     ON CONFLICT(thread_id) DO UPDATE SET paused_reason = excluded.paused_reason,
       paused_by_user_id = excluded.paused_by_user_id,
       failure_message = excluded.failure_message,
       updated_at = excluded.updated_at`;
}

async function resume(env: SecurityEnv, threadId: string) {
  await dataOf(env).read.run`DELETE FROM thread_request_queue_state WHERE thread_id = ${threadId}`;
}

async function errorMessageOf(response: Response) {
  try {
    const body = (await response.json()) as Record<string, unknown>;
    if (Array.isArray(body.issues)) {
      const messages = body.issues
        .map((issue) =>
          issue && typeof issue === "object"
            ? (issue as Record<string, unknown>).message
            : null,
        )
        .filter((message): message is string => typeof message === "string");
      if (messages.length) return messages.join(" ");
    }
    if (typeof body.error === "string") return body.error;
  } catch {
    // No JSON body: fall back to the status.
  }
  return `The request could not be sent (${response.status})`;
}

/**
 * Sends the next queued request when the Thread has nothing processing and
 * the queue is not paused. [failedRequest] reports that the request that just
 * finished failed: like the composer's own queue, that pauses the queue so
 * people decide whether to continue.
 */
const APPROVED_PLAN_HEADING = "Approved plan (prepared by the planning step):";

/**
 * Phases of an approved Implement plan run as separate requests. Each one is
 * sent with the full plan, overview included, so a phase never depends on AI
 * history that may be trimmed or cleared. Added at send time so phases queued
 * before this existed get it too.
 */
async function withApprovedPlan(
  db: Db,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const input = body.input as Record<string, unknown> | undefined;
  const planId = body.planWorkRequestId;
  const request = input?.originalRequest;
  if (
    typeof planId !== "string" ||
    typeof request !== "string" ||
    request.includes(APPROVED_PLAN_HEADING)
  )
    return body;
  const plan = await queryOf(db).row<{ outputJson: string | null }>`SELECT output_json AS "outputJson" FROM workflow_tasks
        WHERE work_request_id = ${planId} AND step_kind = 'plan' AND status = 'completed'
        ORDER BY attempt DESC LIMIT 1`;
  let planText = plan?.outputJson ?? "";
  try {
    const parsed = JSON.parse(planText) as unknown;
    const record = parsed as { text?: unknown; output?: { text?: unknown } };
    planText =
      typeof parsed === "string"
        ? parsed
        : typeof record?.text === "string"
          ? record.text
          : typeof record?.output?.text === "string"
            ? record.output.text
            : planText;
  } catch {
    // Not JSON: use the stored text as is.
  }
  if (!planText.trim()) return body;
  return {
    ...body,
    input: {
      ...input,
      originalRequest: `${request}\n\n${APPROVED_PLAN_HEADING}\n${planText.trim()}`,
    },
  };
}

export async function advanceThreadQueue(
  env: SecurityEnv,
  threadId: string,
  {
    failedRequest = false,
    pauseMessage,
    forceHead = false,
  }: {
    failedRequest?: boolean;
    pauseMessage?: string;
    forceHead?: boolean;
  } = {},
): Promise<void> {
  const db = env.SYNTILA_DB;
  const head = await queryOf(db).row<Pick<QueueRow, "id" | "authorUserId" | "requestJson" | "status">>`SELECT id, author_user_id AS "authorUserId", request_json AS "requestJson", status
         FROM thread_request_queue WHERE thread_id = ${threadId}
        ORDER BY position, created_at, id LIMIT 1`;
  if (!head) return;
  if (failedRequest) {
    await pause(
      env,
      threadId,
      "failure",
      null,
      pauseMessage ??
        "A request failed. Resume the queue to send the next request.",
    );
    await publishQueueUpdated(env, threadId);
    return;
  }
  if (head.status === "sending") return;
  const paused = await queryOf(db).row`SELECT 1 AS found FROM thread_request_queue_state WHERE thread_id = ${threadId}`;
  if (paused && !forceHead) return;
  const active = await queryOf(db).row`SELECT 1 AS found FROM work_requests w
        WHERE w.thread_id = ${threadId} AND ${dataOf(env).read.raw(processingWork("w"))} LIMIT 1`;
  if (active) return;
  const claimed = await queryOf(db).run`UPDATE thread_request_queue SET status = 'sending', updated_at = ${new Date().toISOString()}
        WHERE id = ${head.id} AND status = 'queued'`;
  if (!claimed) return;

  let failure: string | null = null;
  let spaceId: string | null = null;
  try {
    const access = await authorizeThreadAccessAsUser(
      env,
      head.authorUserId,
      threadId,
      "execute",
    );
    spaceId = access.spaceId;
    if (access.thread.status === "archived")
      throw new HttpError(409, "The Thread is archived");
    const response = await createWorkRequestForUser(env, {
      userId: head.authorUserId,
      spaceId: access.spaceId,
      threadId,
      body: await withApprovedPlan(
        db,
        withWorkerTarget(JSON.parse(head.requestJson) as Record<string, unknown>),
      ),
      submissionId: head.id,
    });
    if (response.status < 200 || response.status >= 300)
      failure = await errorMessageOf(response);
  } catch (error) {
    failure =
      error instanceof Error ? error.message : "The request could not be sent";
  }
  if (failure === null) {
    await queryOf(db).run`DELETE FROM thread_request_queue WHERE id = ${head.id}`;
  } else {
    // Keep the request first in line and wait for people to decide.
    await atomically(db, "thread-request-queue.batch333", async (q) => {
      await q.run`UPDATE thread_request_queue SET status = 'queued', updated_at = ${new Date().toISOString()} WHERE id = ${head.id}`;
    });
    await pause(env, threadId, "failure", null, failure);
  }
  await publishQueueUpdated(env, threadId, spaceId);
}

/**
 * A conditional change of a queued request matched no row: it is being sent
 * (409) or was removed meanwhile (404). Throws either way.
 */
async function lostQueuedItem(db: Db, itemId: string): Promise<never> {
  const still = await queryOf(db).row`SELECT 1 AS found FROM thread_request_queue WHERE id = ${itemId}`;
  if (still) throw new HttpError(409, "This request is already being sent");
  throw new HttpError(404, "Queued request not found");
}

/** Never lets a queue error break the caller that finished a request. */
export async function advanceThreadQueueSafely(
  env: SecurityEnv,
  threadId: string,
  options?: {
    failedRequest?: boolean;
    pauseMessage?: string;
    forceHead?: boolean;
  },
) {
  try {
    await advanceThreadQueue(env, threadId, options);
  } catch (error) {
    console.error("Failed to advance the Thread request queue", error);
  }
}

/**
 * Scheduled fallback: releases sends that never finished and advances every
 * running queue whose Thread has nothing processing, covering request
 * endings that do not pass through the Workflow's terminal events.
 */
export async function sweepThreadRequestQueues(env: SecurityEnv) {
  const stale = new Date(Date.now() - STALE_SENDING_MS).toISOString();
  await dataOf(env).read.run`UPDATE thread_request_queue SET status = 'queued', updated_at = ${new Date().toISOString()}
      WHERE status = 'sending' AND updated_at < ${stale}`;
  const read = dataOf(env).read;
  const threads = await read.rows<{ threadId: string }>`SELECT DISTINCT q.thread_id AS "threadId" FROM thread_request_queue q
      WHERE NOT EXISTS (SELECT 1 FROM thread_request_queue_state s
                         WHERE s.thread_id = q.thread_id)
        AND NOT EXISTS (SELECT 1 FROM work_requests w
                         WHERE w.thread_id = q.thread_id
                           AND ${read.raw(processingWork("w"))})
      LIMIT 50`;
  for (const { threadId } of threads)
    await advanceThreadQueueSafely(env, threadId);
}

/**
 * GET    /api/threads/:id/queue                 read the queue
 * POST   /api/threads/:id/queue                 add a request
 * POST   /api/threads/:id/queue/pause|resume    pause or resume
 * PUT    /api/threads/:id/queue/:item           edit your request
 * DELETE /api/threads/:id/queue/:item           remove your request
 * POST   /api/threads/:id/queue/:item/send-now  move your request first
 * POST   /api/threads/:id/queue/:item/stop-phases  remove every queued phase of that plan
 */
export async function handleThreadRequestQueue(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  itemId: string | null,
  action: string | null,
  ctx?: ExecutionContext,
): Promise<Response> {
  const method = request.method;
  if (method === "GET" && !itemId) {
    await authorizeThreadAccess(request, env, threadId, "view", ctx);
    return queueResponse(await loadQueue(env, threadId));
  }
  const { context, spaceId, thread } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "execute",
    ctx,
  );
  const db = env.SYNTILA_DB;
  const now = new Date().toISOString();

  if (!itemId && !action && method === "POST") {
    if (thread.status === "archived")
      throw new HttpError(
        409,
        "Restore the Thread before sending messages or requests",
      );
    const payload = await readBody(request, QueueRequestSchema);
    const body = requestBody(payload.request);
    await requireWorkflowPermission(
      env,
      context.userId,
      spaceId,
      String(body.workflowId),
    );
    const last = await selectThreadRequestQueueByThreadId<{ n: number }>(queryOf(db), threadId);
    // A pause belongs to the requests it held; a new queue starts running.
    if (!last?.n) await resume(env, threadId);
    // People's requests run between implementation phases instead of after
    // the whole plan (enqueueBeforePhases). A plan paused for input waits for
    // this reply: it is sent right away and the remaining phases stay paused
    // until someone resumes them.
    const planPaused =
      !body.isPhased &&
      !!(await queryOf(db).row`SELECT 1 AS found FROM thread_request_queue_state s
            WHERE s.thread_id = ${threadId} AND EXISTS (
              SELECT 1 FROM thread_request_queue q WHERE q.thread_id = ${threadId}
                 AND (q.request_json::jsonb #>> '{isPhased}') IN ('true', '1'))`);
    const item = {
      id: `trq-${crypto.randomUUID()}`,
      threadId,
      authorUserId: context.userId,
      requestJson: JSON.stringify(body),
      now,
    };
    const hasAnchor =
      !body.isPhased &&
      (payload.beforeItemIds !== undefined || payload.afterItemIds !== undefined);
    await dataOf(env).tx("queue.enqueue", async (tx) => {
      await lockQueue(tx, threadId);
      if (body.isPhased) {
        await appendToQueue(tx, item);
      } else if (hasAnchor) {
        await enqueueAtPosition(
          tx,
          item,
          payload.beforeItemIds ?? [],
          payload.afterItemIds ?? [],
        );
      } else {
        await enqueueBeforePhases(tx, item);
      }
    });
    await advanceThreadQueueSafely(env, threadId, { forceHead: planPaused });
    await publishQueueUpdated(env, threadId, spaceId);
    return queueResponse(await loadQueue(env, threadId), 201);
  }

  if (!itemId && (action === "pause" || action === "resume")) {
    if (method !== "POST") throw new HttpError(405, "Unsupported method");
    if (action === "pause")
      await pause(env, threadId, "user", context.userId, null);
    else {
      await resume(env, threadId);
      await advanceThreadQueueSafely(env, threadId);
    }
    await publishQueueUpdated(env, threadId, spaceId);
    return queueResponse(await loadQueue(env, threadId));
  }

  if (!itemId) throw new HttpError(405, "Unsupported method");
  const item = await queryOf(db).row<{ authorUserId: string; status: string; requestJson: string }>`SELECT author_user_id AS "authorUserId", status, request_json AS "requestJson" FROM thread_request_queue
        WHERE id = ${itemId} AND thread_id = ${threadId}`;
  if (!item) throw new HttpError(404, "Queued request not found");
  // Members share the queue but act only on their own requests.
  if (item.authorUserId !== context.userId)
    throw new HttpError(
      403,
      "Only the person who queued this request can change it",
    );
  if (item.status !== "queued")
    throw new HttpError(409, "This request is already being sent");

  let existingRequest: Record<string, unknown> = {};
  try {
    existingRequest = JSON.parse(item.requestJson) as Record<string, unknown>;
  } catch {
    // ignore
  }

  if (method === "PUT" && !action) {
    if (existingRequest.isPhased) {
      throw new HttpError(
        400,
        "Phased implementation steps cannot be edited. Remove the step if you wish to cancel it.",
      );
    }
    const payload = await readBody(request, QueueRequestSchema);
    const body = requestBody(payload.request);
    await requireWorkflowPermission(
      env,
      context.userId,
      spaceId,
      String(body.workflowId),
    );
    const edited = await queryOf(db).row<{ id: string }>`UPDATE thread_request_queue SET request_json = ${JSON.stringify(body)}, updated_at = ${now}
          WHERE id = ${itemId} AND status = 'queued' RETURNING id`;
    if (!edited) await lostQueuedItem(db, itemId);
  } else if (method === "DELETE" && !action) {
    if (existingRequest.isPhased)
      throw new HttpError(
        400,
        "A single implementation phase cannot be removed. Stop all phases instead.",
      );
    const removed = await queryOf(db).row<{ id: string }>`DELETE FROM thread_request_queue WHERE id = ${itemId} AND status = 'queued' RETURNING id`;
    if (!removed) await lostQueuedItem(db, itemId);
    const left = await selectThreadRequestQueueByThreadId<{ n: number }>(queryOf(db), threadId);
    if (!left?.n) await resume(env, threadId);
  } else if (method === "POST" && action === "stop-phases") {
    const planId = existingRequest.planWorkRequestId;
    if (!existingRequest.isPhased || typeof planId !== "string")
      throw new HttpError(400, "This request is not an implementation phase");
    await queryOf(db).run`DELETE FROM thread_request_queue
          WHERE thread_id = ${threadId} AND status = 'queued' AND author_user_id = ${context.userId}
            AND (request_json::jsonb #>> '{planWorkRequestId}') = ${planId}`;
    const left = await selectThreadRequestQueueByThreadId<{ n: number }>(queryOf(db), threadId);
    if (!left?.n) await resume(env, threadId);
  } else if (method === "POST" && action === "send-now") {
    if (existingRequest.isPhased) {
      throw new HttpError(
        400,
        "Phased implementation steps execute in their planned sequence and cannot be moved to the front.",
      );
    }
    // First in line and running again. Requests still processing finish
    // first: members cannot cancel each other's requests.
    const moved = await dataOf(env).tx("queue.send-now", async (tx) => {
      await lockQueue(tx, threadId);
      return moveToFront(tx, threadId, itemId, now);
    });
    // Side effects (advancing the queue) only after this request won the item.
    if (!moved) await lostQueuedItem(db, itemId);
    // A paused queue (for example after a failed phase) stays paused: only
    // this request is sent, the remaining phases wait for an explicit resume.
    await advanceThreadQueueSafely(env, threadId, { forceHead: true });
  } else {
    throw new HttpError(405, "Unsupported method");
  }
  await publishQueueUpdated(env, threadId, spaceId);
  return queueResponse(await loadQueue(env, threadId));
}
