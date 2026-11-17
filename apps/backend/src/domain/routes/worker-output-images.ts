import { isTerminalAssignmentStatus } from "@syntila/core";
import type { AssignmentLifecycleStatus } from "@syntila/core";
import { HttpError, json } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import { requireRuntime } from "./work-request-inputs.js";
import {
  isWorkRequestFileId,
  workRequestFileName,
  readWorkRequestFileUpload,
  storeWorkRequestFile,
} from "./work-request-files.js";
import { getAttachmentLimits } from "../account-plan.js";

/**
 * Worker output files: files a Worker produced for the user. The
 * Workspace uploads each one while its assignment is still open and lists
 * the returned descriptors in the result's `output.images`; the AI message
 * shows them and the Thread file download serves them.
 */

export const MAX_WORKER_OUTPUT_IMAGES = 10;

export interface WorkerOutputImage {
  readonly kind: "file";
  readonly fileId: string;
  readonly name: string;
  readonly mediaType: string;
  readonly sizeBytes: number;
  /** Small base64 JPEG for inline display; the file is the original. */
  readonly previewImage?: string;
}

/** Base64 JPEG preview budget; the Workspace and app enforce the same value. */
export const MAX_WORKER_OUTPUT_PREVIEW_CHARS = 48000;

function previewImage(value: unknown): string | undefined {
  return typeof value === "string" &&
    value.length <= MAX_WORKER_OUTPUT_PREVIEW_CHARS &&
    value.startsWith("/9j/") &&
    /^[A-Za-z0-9+/]*={0,2}$/.test(value)
    ? value
    : undefined;
}

/**
 * `POST /api/workspace-runtime/outputs?assignmentId=…&name=…` — stores one
 * file for an assignment that runs on the calling Workspace.
 */
export async function handleUploadWorkerOutputImage(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const workspaceId = await requireRuntime(request, env);
  const url = new URL(request.url);
  const assignmentId = url.searchParams.get("assignmentId");
  if (!assignmentId) throw new HttpError(400, "assignmentId is required");
  // Workflow-dispatched assignments leave `thread_id` empty; their Thread
  // comes from the Work Request of the assignment's conversation turn.
  const assignment = await env.SYNTILA_DB.prepare(
    `SELECT COALESCE(NULLIF(wa.thread_id, ''), wr.thread_id) AS threadId,
            wa.status, t.space_id AS spaceId, s.owner_user_id AS ownerUserId
       FROM worker_assignments wa
       LEFT JOIN conversation_turns ct ON ct.assignment_id = wa.id
       LEFT JOIN work_requests wr
         ON wr.id = COALESCE(NULLIF(wa.work_request_id, ''), ct.work_request_id)
       JOIN threads t ON t.id = COALESCE(NULLIF(wa.thread_id, ''), wr.thread_id)
       JOIN spaces s ON s.id = t.space_id
      WHERE wa.id = ?1 AND wa.execution_workspace_id = ?2
      LIMIT 1`,
  )
    .bind(assignmentId, workspaceId)
    .first<{
      threadId: string | null;
      status: string;
      spaceId: string;
      ownerUserId: string;
    }>();
  if (!assignment?.threadId) throw new HttpError(404, "Assignment not found");
  if (
    isTerminalAssignmentStatus(assignment.status as AssignmentLifecycleStatus)
  )
    throw new HttpError(409, "Assignment has already finished");
  const limits = await getAttachmentLimits(
    env as unknown as Env,
    assignment.ownerUserId,
  );
  const upload = await readWorkRequestFileUpload(request, limits);
  const fileId = `wrf-${crypto.randomUUID()}`;
  const name = workRequestFileName(url.searchParams.get("name"));
  const stored = await storeWorkRequestFile(env, {
    fileId,
    name,
    upload,
    assignmentId,
    threadId: assignment.threadId,
    spaceId: assignment.spaceId,
    userId: assignment.ownerUserId,
  });
  const image: WorkerOutputImage = {
    kind: "file",
    fileId,
    name,
    mediaType: upload.mediaType,
    sizeBytes: stored.sizeBytes,
  };
  return json({ image }, { status: 201 });
}

/** Bounded, well-formed descriptors only; anything else is dropped. */
export function workerOutputImages(raw: unknown): WorkerOutputImage[] {
  let value = raw;
  if (typeof value === "string") {
    try {
      value = JSON.parse(value);
    } catch {
      return [];
    }
  }
  if (!Array.isArray(value)) return [];
  return value.slice(0, MAX_WORKER_OUTPUT_IMAGES).flatMap((entry) => {
    if (!entry || typeof entry !== "object") return [];
    const image = entry as Record<string, unknown>;
    if (
      !isWorkRequestFileId(image.fileId) ||
      typeof image.mediaType !== "string" ||
      image.mediaType.length === 0 ||
      image.mediaType.length > 128 ||
      typeof image.sizeBytes !== "number" ||
      !Number.isSafeInteger(image.sizeBytes) ||
      image.sizeBytes < 0
    )
      return [];
    const preview = previewImage(image.previewImage);
    return [
      {
        kind: "file" as const,
        fileId: image.fileId,
        name: workRequestFileName(image.name),
        mediaType: image.mediaType,
        sizeBytes: image.sizeBytes,
        ...(preview ? { previewImage: preview } : {}),
      },
    ];
  });
}
