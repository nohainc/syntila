import { extractBearerToken } from "@syntila/security";
import { WorkspaceRuntimeAuthenticator } from "../workspace-gateway/runtime-authenticator.js";
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

/**
 * Input Delivery v1 (see docs/specifications/INPUT_DELIVERY_V1.md).
 *
 * A Work Request is accepted with a manifest of its file inputs before their
 * bytes exist. AX uploads each file; the target Workspace Service polls for
 * uploaded inputs, downloads each over authenticated HTTPS and confirms it.
 * The Workflow dispatches the first step only when every input is
 * `delivered`. A file that cannot be uploaded or delivered after its retries
 * is `failed`, which fails the request before any Worker starts. Every retry
 * restarts the whole file.
 */

export type WorkRequestInputState =
  "awaiting_upload" | "uploaded" | "delivered" | "failed";

export interface WorkRequestInputRow {
  readonly fileId: string;
  readonly workRequestId: string;
  readonly threadId: string;
  readonly workspaceId: string;
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

const COLUMNS = `id AS fileId, work_request_id AS workRequestId,
  thread_id AS threadId, workspace_id AS workspaceId, user_id AS userId,
  position, name, media_type AS mediaType, size_bytes AS sizeBytes,
  content_digest AS contentDigest, preview_text AS previewText,
  preview_image AS previewImage, state, upload_attempts AS uploadAttempts,
  delivery_attempts AS deliveryAttempts, error_message AS errorMessage,
  updated_at AS updatedAt`;

/** Rows for one request in attachment order. */
export async function loadWorkRequestInputs(
  db: D1Database,
  workRequestId: string,
): Promise<WorkRequestInputRow[]> {
  const rows = await db
    .prepare(
      `SELECT ${COLUMNS} FROM work_request_inputs WHERE work_request_id = ?1 ORDER BY position`,
    )
    .bind(workRequestId)
    .all<WorkRequestInputRow>();
  return rows.results ?? [];
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
export function workRequestInputStatements(
  db: D1Database,
  input: {
    workRequestId: string;
    threadId: string;
    workspaceId: string;
    userId: string;
    attachments: readonly Record<string, unknown>[];
    now: string;
  },
): D1PreparedStatement[] {
  return input.attachments.flatMap((attachment, position) =>
    attachment.kind === "file" && isWorkRequestFileId(attachment.fileId)
      ? [
          db
            .prepare(
              `INSERT INTO work_request_inputs
               (id, work_request_id, thread_id, workspace_id, user_id, position,
                name, media_type, size_bytes, content_digest, state,
                created_at, updated_at)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?12)`,
            )
            .bind(
              attachment.fileId,
              input.workRequestId,
              input.threadId,
              input.workspaceId,
              input.userId,
              position,
              String(attachment.name ?? "Attachment"),
              String(attachment.mediaType ?? "application/octet-stream"),
              Number(attachment.sizeBytes ?? 0),
              typeof attachment.contentDigest === "string"
                ? attachment.contentDigest
                : null,
              typeof attachment.contentDigest === "string"
                ? "uploaded"
                : "awaiting_upload",
              input.now,
            ),
        ]
      : [],
  );
}

async function inputRow(
  db: D1Database,
  fileId: string,
): Promise<WorkRequestInputRow | null> {
  if (!isWorkRequestFileId(fileId)) return null;
  return db
    .prepare(`SELECT ${COLUMNS} FROM work_request_inputs WHERE id = ?1`)
    .bind(fileId)
    .first<WorkRequestInputRow>();
}

async function requestIsOpen(
  db: D1Database,
  workRequestId: string,
): Promise<boolean> {
  const row = await db
    .prepare(
      "SELECT status, cancel_requested_at AS cancelRequestedAt FROM work_requests WHERE id = ?1",
    )
    .bind(workRequestId)
    .first<{ status: string; cancelRequestedAt: string | null }>();
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
    const run = await env.SYNTILA_DB.prepare(
      `SELECT workflow_instance_id AS instanceId FROM runs
        WHERE work_request_id = ?1 AND workflow_instance_id IS NOT NULL
        ORDER BY created_at DESC LIMIT 1`,
    )
      .bind(row.workRequestId)
      .first<{ instanceId: string }>();
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
    const thread = await env.SYNTILA_DB.prepare(
      `SELECT t.space_id AS spaceId, wr.primary_workspace_id AS workspaceId
         FROM threads t JOIN work_requests wr ON wr.thread_id = t.id
        WHERE wr.id = ?1`,
    )
      .bind(row.workRequestId)
      .first<{ spaceId: string; workspaceId: string | null }>();
    if (!thread?.workspaceId) return;
    await createEventPublisher(env).publish({
      type: "work_request.input_updated",
      workspaceId: thread.workspaceId,
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

/** Sends the tiny `input.available` wake-up to the target Service. */
async function wakeWorkspace(env: SecurityEnv, workspaceId: string) {
  try {
    await env.SYNTILA_WORKSPACE_GATEWAY?.getByName(workspaceId).fetch(
      "https://workspace-gateway/inputs-available",
      { method: "POST" },
    );
  } catch {
    // The Service also polls.
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
  await env.SYNTILA_DB.prepare(
    `UPDATE work_request_inputs
        SET state = 'uploaded', content_digest = ?1, preview_text = ?2,
            preview_image = ?3, error_message = NULL,
            upload_attempts = upload_attempts + 1, updated_at = ?4
      WHERE id = ?5 AND state IN ('awaiting_upload', 'failed')`,
  )
    .bind(
      stored.digest,
      stored.previewText ?? null,
      stored.previewImage ?? null,
      new Date().toISOString(),
      fileId,
    )
    .run();
  await announceInputProgress(env, row, "uploaded");
  await wakeWorkspace(env, row.workspaceId);
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
  await env.SYNTILA_DB.prepare(
    `UPDATE work_request_inputs
        SET state = 'failed', error_message = ?1, updated_at = ?2
      WHERE id = ?3 AND state <> 'delivered'`,
  )
    .bind(message, new Date().toISOString(), row.fileId)
    .run();
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
  const body = (await request.json().catch(() => null)) as {
    message?: unknown;
  } | null;
  await failInput(
    env,
    row,
    `${row.name} could not be uploaded: ${failureMessage(body?.message, "upload failed")}`,
  );
  return json({ fileId, state: "failed" });
}

async function requireRuntime(request: Request, env: SecurityEnv) {
  const runtimeId = new URL(request.url).searchParams.get("workspaceRuntimeId");
  const credential = extractBearerToken(request.headers);
  if (!runtimeId || !credential)
    throw new HttpError(401, "Workspace runtime credentials are required");
  const runtime = await new WorkspaceRuntimeAuthenticator(
    env.SYNTILA_DB,
  ).authenticateRuntime(runtimeId, credential);
  if (!runtime)
    throw new HttpError(401, "Workspace runtime credential is invalid");
  return runtime.executionWorkspaceId;
}

async function runtimeRow(
  request: Request,
  env: SecurityEnv,
  fileId: string,
): Promise<WorkRequestInputRow> {
  const workspaceId = await requireRuntime(request, env);
  const row = await inputRow(env.SYNTILA_DB, fileId);
  if (!row || row.workspaceId !== workspaceId)
    throw new HttpError(404, "Input not found");
  return row;
}

/**
 * `GET /api/workspace-runtime/inputs` — uploaded inputs this Workspace still
 * has to download, oldest first. Requests that ended are excluded.
 */
export async function handleListRuntimeInputs(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const workspaceId = await requireRuntime(request, env);
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT i.id AS fileId, i.work_request_id AS workRequestId, i.name,
            i.size_bytes AS sizeBytes, i.content_digest AS contentDigest,
            i.delivery_attempts AS deliveryAttempts
       FROM work_request_inputs i
       JOIN work_requests wr ON wr.id = i.work_request_id
      WHERE i.workspace_id = ?1 AND i.state = 'uploaded'
        AND wr.status IN ('queued', 'running', 'waiting')
        AND wr.cancel_requested_at IS NULL
      ORDER BY i.created_at, i.position
      LIMIT 50`,
  )
    .bind(workspaceId)
    .all();
  return json({ inputs: rows.results ?? [] });
}

/**
 * `GET /api/workspace-runtime/inputs/:fileId/content` — streams the bytes
 * straight from R2. Also serves delivered files so a Service can re-download
 * one its local store no longer has (retry, later Workflow step).
 */
export async function handleDownloadRuntimeInput(
  request: Request,
  env: SecurityEnv,
  fileId: string,
): Promise<Response> {
  const row = await runtimeRow(request, env, fileId);
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

/**
 * `POST /api/workspace-runtime/inputs/:fileId/delivered` — the Service
 * stored the file and verified [contentDigest].
 */
export async function handleConfirmRuntimeInput(
  request: Request,
  env: SecurityEnv,
  fileId: string,
): Promise<Response> {
  const row = await runtimeRow(request, env, fileId);
  const body = (await request.json().catch(() => null)) as {
    contentDigest?: unknown;
  } | null;
  if (row.state === "delivered") return json({ fileId, state: "delivered" });
  if (row.state !== "uploaded" || body?.contentDigest !== row.contentDigest)
    throw new HttpError(409, "Input does not match the uploaded file");
  await env.SYNTILA_DB.prepare(
    `UPDATE work_request_inputs
        SET state = 'delivered', delivery_attempts = delivery_attempts + 1,
            error_message = NULL, updated_at = ?1
      WHERE id = ?2 AND state = 'uploaded'`,
  )
    .bind(new Date().toISOString(), fileId)
    .run();
  await announceInputProgress(env, row, "delivered");
  return json({ fileId, state: "delivered" });
}

/**
 * `POST /api/workspace-runtime/inputs/:fileId/attempt` — records a failed
 * download attempt; with `final: true` the input fails the request.
 */
export async function handleReportRuntimeInputAttempt(
  request: Request,
  env: SecurityEnv,
  fileId: string,
): Promise<Response> {
  const row = await runtimeRow(request, env, fileId);
  const body = (await request.json().catch(() => null)) as {
    final?: unknown;
    message?: unknown;
  } | null;
  if (row.state !== "uploaded") return json({ fileId, state: row.state });
  const message = failureMessage(body?.message, "download failed");
  if (body?.final === true) {
    await failInput(
      env,
      row,
      `${row.name} could not be delivered to the Workspace: ${message}`,
    );
    return json({ fileId, state: "failed" });
  }
  await env.SYNTILA_DB.prepare(
    `UPDATE work_request_inputs
        SET delivery_attempts = delivery_attempts + 1, error_message = ?1,
            updated_at = ?2
      WHERE id = ?3 AND state = 'uploaded'`,
  )
    .bind(message, new Date().toISOString(), fileId)
    .run();
  await announceInputProgress(env, row, "uploaded");
  return json({ fileId, state: "uploaded" });
}

/** Rows for several requests, keyed by request id. */
export async function loadInputsForRequests(
  db: D1Database,
  workRequestIds: readonly string[],
): Promise<Map<string, WorkRequestInputRow[]>> {
  const byRequest = new Map<string, WorkRequestInputRow[]>();
  if (workRequestIds.length === 0) return byRequest;
  const rows = await db
    .prepare(
      `SELECT ${COLUMNS} FROM work_request_inputs
        WHERE work_request_id IN (${workRequestIds.map((_, i) => `?${i + 1}`).join(", ")})
        ORDER BY position`,
    )
    .bind(...workRequestIds)
    .all<WorkRequestInputRow>();
  for (const row of rows.results ?? []) {
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
