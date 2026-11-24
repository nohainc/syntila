import { dataOf, queryOf, type Tx, type Db } from "../../platform/data.js";
import {
  InputUploadFailedSchema,
} from "@syntila/protocol";
import { readBody } from "./validation.js";
import { extractBearerToken } from "@syntila/security";
import { createEventPublisher } from "../event-publisher.js";
import { HttpError, authorizeThreadAccess, json } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import {
  isWorkRequestFileId,
  readWorkRequestFileUpload,
  storedFileDigest,
  storeWorkRequestFile,
  workRequestFileKey,
} from "./work-request-files.js";
import { getAttachmentLimits } from "../account-plan.js";
import { authenticateAgentSession } from "../worker-agents.js";

/**
 * Input Delivery v1 (see docs/specifications/INPUT_DELIVERY_V1.md).
 *
 * A Work Request is accepted with a manifest of its file inputs before their
 * bytes exist. The web app uploads each file to R2. The Workflow starts the
 * first Step only when every input is `uploaded`; any Worker that runs a Step
 * downloads the files with its own session. A file that cannot be uploaded
 * after its retries is `failed`, which fails the request before any Worker
 * starts.
 */

export type WorkRequestInputState =
  "awaiting_upload" | "uploaded" | "delivered" | "failed";

export interface WorkRequestInputRow {
  readonly fileId: string;
  readonly workRequestId: string;
  readonly threadId: string;
  readonly userId: string;
  readonly position: number;
  readonly name: string;
  readonly mediaType: string;
  readonly sizeBytes: number;
  readonly contentDigest: string | null;
  readonly previewText: string | null;
  readonly previewImage: string | null;
  readonly state: WorkRequestInputState;
  readonly uploadAttempts: number;
  readonly deliveryAttempts: number;
  readonly errorMessage: string | null;
  readonly updatedAt: string;
}

/** Event type the Workflow waits for (no dots allowed by Workflows). */
export const WORK_INPUTS_EVENT_TYPE = "work-inputs";

/** The request fails when no input makes progress for this long. */
export const INPUT_DELIVERY_IDLE_TIMEOUT_MS = 10 * 60 * 1000;

const COLUMNS = `id AS "fileId", work_request_id AS "workRequestId",
  thread_id AS "threadId", user_id AS "userId",
  position, name, media_type AS "mediaType", size_bytes AS "sizeBytes",
  content_digest AS "contentDigest", preview_text AS "previewText",
  preview_image AS "previewImage", state, upload_attempts AS "uploadAttempts",
  delivery_attempts AS "deliveryAttempts", error_message AS "errorMessage",
  updated_at AS "updatedAt"`;

/** Rows for one request in attachment order. */
export async function loadWorkRequestInputs(
  db: Db,
  workRequestId: string,
): Promise<WorkRequestInputRow[]> {
  const q = queryOf(db);
  return q.rows<WorkRequestInputRow>`SELECT ${q.raw(COLUMNS)} FROM work_request_inputs WHERE work_request_id = ${workRequestId} ORDER BY position`;
}

/** Bounded, path-free progress for clients. */
export function inputProgress(rows: readonly WorkRequestInputRow[]) {
  return rows.map((row) => ({
    fileId: row.fileId,
    name: row.name,
    sizeBytes: row.sizeBytes,
    state: row.state,
    uploadAttempts: row.uploadAttempts,
    deliveryAttempts: row.deliveryAttempts,
    ...(row.errorMessage ? { errorMessage: row.errorMessage } : {}),
  }));
}

/**
 * Manifest rows inserted with the Work Request. A file that already carries
 * a verified digest (uploaded before submission) starts as `uploaded`.
 */
export async function insertWorkRequestInputs(
  tx: Tx,
  input: {
    workRequestId: string;
    threadId: string;
    userId: string;
    attachments: readonly Record<string, unknown>[];
    now: string;
  },
): Promise<void> {
  for (const [position, attachment] of input.attachments.entries()) {
    if (!(attachment.kind === "file" && isWorkRequestFileId(attachment.fileId))) continue;
    const digest =
      typeof attachment.contentDigest === "string" ? attachment.contentDigest : null;
    await tx.run`INSERT INTO work_request_inputs
               (id, work_request_id, thread_id, user_id, position,
                name, media_type, size_bytes, content_digest, state,
                created_at, updated_at)
               VALUES (${attachment.fileId}, ${input.workRequestId}, ${input.threadId}, ${input.userId}, ${position},
                ${String(attachment.name ?? "Attachment")}, ${String(attachment.mediaType ?? "application/octet-stream")}, ${Number(attachment.sizeBytes ?? 0)}, ${digest}, ${digest ? "uploaded" : "awaiting_upload"},
                ${input.now}, ${input.now})`;
  }
}

async function inputRow(
  db: Db,
  fileId: string,
): Promise<WorkRequestInputRow | null> {
  if (!isWorkRequestFileId(fileId)) return null;
  const q = queryOf(db);
  return q.row<WorkRequestInputRow>`SELECT ${q.raw(COLUMNS)} FROM work_request_inputs WHERE id = ${fileId}`;
}

async function requestIsOpen(
  db: Db,
  workRequestId: string,
): Promise<boolean> {
  const row = await queryOf(db).row<{ status: string; cancelRequestedAt: string | null }>`SELECT status, cancel_requested_at AS "cancelRequestedAt" FROM work_requests WHERE id = ${workRequestId}`;
  return (
    !!row &&
    !row.cancelRequestedAt &&
    (row.status === "queued" ||
      row.status === "running" ||
      row.status === "waiting")
  );
}

/**
 * Wakes the request's Workflow and publishes progress to Thread viewers.
 * Both are hints: the Workflow re-reads D1 and times out into a re-read, and
 * clients refresh the request on the event.
 */
async function announceInputProgress(
  env: SecurityEnv,
  row: Pick<WorkRequestInputRow, "workRequestId" | "threadId" | "fileId">,
  state: WorkRequestInputState,
): Promise<void> {
  try {
    const run = await dataOf(env).read.row<{ instanceId: string }>`SELECT workflow_instance_id AS "instanceId" FROM runs
        WHERE work_request_id = ${row.workRequestId} AND workflow_instance_id IS NOT NULL
        ORDER BY created_at DESC LIMIT 1`;
    if (run?.instanceId && env.SYNTILA_RUN_WORKFLOW) {
      const instance = await env.SYNTILA_RUN_WORKFLOW.get(run.instanceId);
      await instance.sendEvent({
        type: WORK_INPUTS_EVENT_TYPE,
        payload: { fileId: row.fileId, state },
      });
    }
  } catch {
    // The Workflow's bounded wait re-reads D1.
  }
  try {
    const thread = await dataOf(env).read.row<{ spaceId: string }>`SELECT t.space_id AS "spaceId"
         FROM threads t JOIN work_requests wr ON wr.thread_id = t.id
        WHERE wr.id = ${row.workRequestId}`;
    if (!thread) return;
    await createEventPublisher(env).publish({
      type: "work_request.input_updated",
      stream: { kind: "space" as const, id: thread.spaceId },
      spaceId: thread.spaceId,
      idempotencyKey: `work-request-input:${row.fileId}:${crypto.randomUUID()}`,
      payload: {
        entityId: row.workRequestId,
        workRequestId: row.workRequestId,
        threadId: row.threadId,
        status: state,
      },
    });
  } catch {
    // Clients also refresh on their own schedule.
  }
}

async function requesterRow(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  fileId: string,
  accessContext?: ExecutionContext,
) {
  const row = await inputRow(env.SYNTILA_DB, fileId);
  if (!row || row.workRequestId !== workRequestId)
    throw new HttpError(404, "Input not found");
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    row.threadId,
    "execute",
    accessContext,
  );
  if (context.userId !== row.userId)
    throw new HttpError(403, "Only the requester can upload this file");
  return { row, spaceId: spaceId ?? null };
}

/**
 * `PUT /api/work-requests/:id/inputs/:fileId` — uploads (or restarts the
 * upload of) one manifest file. A delivered or already uploaded file is
 * immutable; the size must match the manifest.
 */
export async function handleUploadWorkRequestInput(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  fileId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { row, spaceId } = await requesterRow(
    request,
    env,
    workRequestId,
    fileId,
    accessContext,
  );
  if (row.state === "uploaded" || row.state === "delivered")
    return json({ fileId, state: row.state });
  if (!(await requestIsOpen(env.SYNTILA_DB, workRequestId)))
    throw new HttpError(409, "The request is no longer waiting for files");
  // Charged to the requester (the uploader), whatever plan owns the Space.
  const limits = await getAttachmentLimits(env as unknown as Env, row.userId);
  const upload = await readWorkRequestFileUpload(request, limits);
  if (upload.sizeBytes !== row.sizeBytes)
    throw new HttpError(400, "File size does not match the request");
  const stored = await storeWorkRequestFile(env, {
    fileId,
    threadId: row.threadId,
    spaceId,
    userId: row.userId,
    name: row.name,
    upload: { ...upload, mediaType: row.mediaType },
    workRequestId,
  });
  await dataOf(env).read.run`UPDATE work_request_inputs
        SET state = 'uploaded', content_digest = ${stored.digest}, preview_text = ${stored.previewText ?? null},
            preview_image = ${stored.previewImage ?? null}, error_message = NULL,
            upload_attempts = upload_attempts + 1, updated_at = ${new Date().toISOString()}
      WHERE id = ${fileId} AND state IN ('awaiting_upload', 'failed')`;
  await announceInputProgress(env, row, "uploaded");
  return json({ fileId, state: "uploaded" });
}

function failureMessage(value: unknown, fallback: string): string {
  return typeof value === "string" && value.trim()
    ? value.trim().slice(0, 300)
    : fallback;
}

async function failInput(
  env: SecurityEnv,
  row: WorkRequestInputRow,
  message: string,
): Promise<void> {
  await dataOf(env).read.run`UPDATE work_request_inputs
        SET state = 'failed', error_message = ${message}, updated_at = ${new Date().toISOString()}
      WHERE id = ${row.fileId} AND state <> 'delivered'`;
  await announceInputProgress(env, row, "failed");
}

/** `POST /api/work-requests/:id/inputs/:fileId/failed` — AX gave up. */
export async function handleFailWorkRequestInputUpload(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  fileId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { row } = await requesterRow(
    request,
    env,
    workRequestId,
    fileId,
    accessContext,
  );
  if (row.state !== "awaiting_upload")
    return json({ fileId, state: row.state });
  const body = await readBody(request, InputUploadFailedSchema);
  await failInput(
    env,
    row,
    `${row.name} could not be uploaded: ${failureMessage(body?.message, "upload failed")}`,
  );
  return json({ fileId, state: "failed" });
}

/**
 * `GET /api/worker-agent/inputs/:fileId/content` — streams the bytes straight
 * from R2 to the Agent of a Worker that runs a Step of the request.
 */
export async function handleDownloadAgentInput(
  request: Request,
  env: SecurityEnv,
  fileId: string,
): Promise<Response> {
  const workerId = request.headers.get("x-worker-id");
  const sessionId = request.headers.get("x-worker-session-id");
  const token = extractBearerToken(request.headers);
  const principal = workerId && sessionId && token
    ? await authenticateAgentSession(env, { workerId, sessionId, sessionToken: token })
    : null;
  if (!workerId || !principal) throw new HttpError(401, "Invalid Worker session");
  const row = await inputRow(env.SYNTILA_DB, fileId);
  const runsAStep = !!row && !!(await dataOf(env).read.row`SELECT 1 AS ok FROM worker_assignments
       WHERE work_request_id = ${row.workRequestId} AND worker_instance_id = ${workerId} LIMIT 1`);
  if (!row || !runsAStep) throw new HttpError(404, "Input not found");
  if (row.state !== "uploaded" && row.state !== "delivered")
    throw new HttpError(409, "Input is not available");
  const object = await env.SYNTILA_ARTIFACTS?.get(workRequestFileKey(fileId));
  if (
    !object ||
    object.size !== row.sizeBytes ||
    (await storedFileDigest(env, fileId, object.customMetadata)) !==
      row.contentDigest
  )
    throw new HttpError(409, "Input content is unavailable");
  return new Response(object.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Length": String(object.size),
      "X-Content-Digest": row.contentDigest ?? "",
      "Cache-Control": "private, no-store",
    },
  });
}

/** Rows for several requests, keyed by request id. */
export async function loadInputsForRequests(
  db: Db,
  workRequestIds: readonly string[],
): Promise<Map<string, WorkRequestInputRow[]>> {
  const byRequest = new Map<string, WorkRequestInputRow[]>();
  if (workRequestIds.length === 0) return byRequest;
  const q = queryOf(db);
  const rows = await q.rows<WorkRequestInputRow>`SELECT ${q.raw(COLUMNS)} FROM work_request_inputs
        WHERE work_request_id IN ${q.list(workRequestIds)}
        ORDER BY position`;
  for (const row of rows) {
    const values = byRequest.get(row.workRequestId) ?? [];
    values.push(row);
    byRequest.set(row.workRequestId, values);
  }
  return byRequest;
}

/**
 * The request input with each delivered file's verified digest and display
 * previews. The stored input_json is immutable; uploads finish after it.
 */
export function withInputFacts(
  input: Record<string, unknown>,
  rows: readonly WorkRequestInputRow[] | undefined,
): Record<string, unknown> {
  if (!rows?.length || !Array.isArray(input.attachments)) return input;
  const byId = new Map(rows.map((row) => [row.fileId, row]));
  return {
    ...input,
    attachments: (input.attachments as unknown[]).map((value) => {
      if (!value || typeof value !== "object") return value;
      const attachment = value as Record<string, unknown>;
      const row =
        typeof attachment.fileId === "string"
          ? byId.get(attachment.fileId)
          : undefined;
      if (!row) return attachment;
      return {
        ...attachment,
        ...(row.contentDigest ? { contentDigest: row.contentDigest } : {}),
        ...(row.previewText ? { previewText: row.previewText } : {}),
        ...(row.previewImage ? { previewImage: row.previewImage } : {}),
      };
    }),
  };
}
