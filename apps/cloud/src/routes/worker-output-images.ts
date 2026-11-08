import { isTerminalAssignmentStatus } from "@syntila/core";
import type { AssignmentLifecycleStatus } from "@syntila/core";
import { HttpError, json } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import { requireRuntime } from "./work-request-inputs.js";
import {
  isWorkRequestFileId,
  workRequestFileKey,
  workRequestFileName,
} from "./work-request-files.js";

/**
 * Worker output images: pictures a Worker produced for the user. The
 * Workspace uploads each one while its assignment is still open and lists
 * the returned descriptors in the result's `output.images`; the AI message
 * shows them and the Thread file download serves them.
 */

export const MAX_WORKER_OUTPUT_IMAGES = 10;
export const MAX_WORKER_OUTPUT_IMAGE_BYTES = 20 * 1024 * 1024;
const IMAGE_MEDIA_TYPES = new Set([
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
]);

export interface WorkerOutputImage {
  readonly kind: "file";
  readonly fileId: string;
  readonly name: string;
  readonly mediaType: string;
  readonly sizeBytes: number;
}

/**
 * `POST /api/workspace-runtime/outputs?assignmentId=…&name=…` — stores one
 * image for an assignment that runs on the calling Workspace.
 */
export async function handleUploadWorkerOutputImage(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const workspaceId = await requireRuntime(request, env);
  const url = new URL(request.url);
  const assignmentId = url.searchParams.get("assignmentId");
  if (!assignmentId) throw new HttpError(400, "assignmentId is required");
  const assignment = await env.SYNTILA_DB.prepare(
    `SELECT thread_id AS threadId, status FROM worker_assignments
      WHERE id = ?1 AND execution_workspace_id = ?2`,
  )
    .bind(assignmentId, workspaceId)
    .first<{ threadId: string | null; status: string }>();
  if (!assignment?.threadId) throw new HttpError(404, "Assignment not found");
  if (
    isTerminalAssignmentStatus(assignment.status as AssignmentLifecycleStatus)
  )
    throw new HttpError(409, "Assignment has already finished");
  const mediaType =
    request.headers.get("content-type")?.split(";", 1)[0]?.trim() ?? "";
  if (!IMAGE_MEDIA_TYPES.has(mediaType))
    throw new HttpError(415, "Only PNG, JPEG, GIF and WebP images are accepted");
  const body = await request.arrayBuffer();
  if (body.byteLength === 0 || body.byteLength > MAX_WORKER_OUTPUT_IMAGE_BYTES)
    throw new HttpError(413, "Image exceeds the 20 MiB limit");
  const bucket = env.SYNTILA_ARTIFACTS;
  if (!bucket) throw new HttpError(503, "File storage is not configured");
  const fileId = `wrf-${crypto.randomUUID()}`;
  const name = workRequestFileName(url.searchParams.get("name"));
  await bucket.put(workRequestFileKey(fileId), body, {
    httpMetadata: { contentType: mediaType },
    customMetadata: {
      threadId: assignment.threadId,
      assignmentId,
      name,
      source: "worker_output",
    },
  });
  const image: WorkerOutputImage = {
    kind: "file",
    fileId,
    name,
    mediaType,
    sizeBytes: body.byteLength,
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
      !IMAGE_MEDIA_TYPES.has(image.mediaType) ||
      typeof image.sizeBytes !== "number"
    )
      return [];
    return [
      {
        kind: "file" as const,
        fileId: image.fileId,
        name: workRequestFileName(image.name),
        mediaType: image.mediaType,
        sizeBytes: image.sizeBytes,
      },
    ];
  });
}
