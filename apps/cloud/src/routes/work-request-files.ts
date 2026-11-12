import { computePackageDigest } from "@syntila/security";
import { HttpError } from "./http-security.js";
import { artifactName, authorizeThreadAccess, json } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import {
  ATTACHMENT_LIMITS,
  FileTooLargeError,
  MAX_ATTACHMENTS_PER_SUBMISSION,
  getAttachmentLimits,
  type AttachmentLimits,
} from "../account-plan.js";
import { UploadStreamError, putStream } from "../upload-stream.js";
import {
  loadStorageUsage,
  releaseUpload,
  reserveUpload,
} from "../attachment-storage.js";

/** Base64 JPEG thumbnail budget; AX enforces the same value. */
const MAX_PREVIEW_IMAGE_CHARS = 32000;

/**
 * Attachments per submission (not plan based). Per-file and total-storage
 * limits depend on the uploader's plan; see `ATTACHMENT_LIMITS` in
 * `account-plan.ts` (decimal bytes).
 */
export const MAX_WORK_REQUEST_FILES = MAX_ATTACHMENTS_PER_SUBMISSION;
/**
 * Largest file any plan accepts. Only a sanity bound when an existing file is
 * referenced again: a file stored under a larger earlier allowance stays usable
 * after a downgrade.
 */
export const MAX_STORED_FILE_BYTES = ATTACHMENT_LIMITS.paid.fileBytes;
/** Multipart bodies are buffered, so they stay within the Free file size. */
const MULTIPART_BUFFER_LIMIT_BYTES =
  ATTACHMENT_LIMITS.free.fileBytes + 24 * 1024;

export interface UserStorageUsage {
  readonly usedBytes: number;
  readonly fileCount: number;
  /** Bytes held by uploads still in flight. */
  readonly reservedBytes: number;
  /** The uploader's total allowance on their current plan. */
  readonly quotaBytes: number;
  /** The uploader's individual-file allowance on their current plan. */
  readonly maxFileBytes: number;
}

/** Retained uploaded bytes and the uploader's current allowances. */
export async function userStorageUsage(
  env: SecurityEnv,
  userId: string,
): Promise<UserStorageUsage> {
  const [usage, limits] = await Promise.all([
    loadStorageUsage(env.SYNTILA_DB, userId),
    getAttachmentLimits(env as unknown as Env, userId),
  ]);
  return {
    ...usage,
    quotaBytes: limits.storageBytes,
    maxFileBytes: limits.fileBytes,
  };
}

class UploadRequirementError extends HttpError {
  constructor(
    status: number,
    message: string,
    readonly code: string,
  ) {
    super(status, message);
  }
}

const FILE_ID_PATTERN =
  /^wrf-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * A display name for a submitted file: path separators and control
 * characters become `_`; everything else (spaces, punctuation, Unicode) is
 * kept. Bytes are always stored under the generated file id, never this name.
 */
export function workRequestFileName(value: unknown): string {
  return typeof value === "string"
    ? // eslint-disable-next-line no-control-regex -- Strip control characters.
      value.replace(/[\\/\u0000-\u001f\u007f]/g, "_").slice(0, 255) ||
        "Attachment"
    : "Attachment";
}

export function isWorkRequestFileId(value: unknown): value is string {
  return typeof value === "string" && FILE_ID_PATTERN.test(value);
}

export function workRequestFileKey(fileId: string): string {
  return `work-request-inputs/${fileId}`;
}

/**
 * Stores one Work Request input file in R2. The object is bound to the
 * uploading user and Thread; Work Request creation verifies that binding
 * before it accepts the returned `fileId`.
 */
export async function handleUploadWorkRequestFile(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    new URL(request.url).searchParams.get("purpose") === "discussion"
      ? "discuss"
      : "execute",
    accessContext,
  );
  const limits = await getAttachmentLimits(
    env as unknown as Env,
    context.userId,
  );
  const upload = await readWorkRequestFileUpload(request, limits);
  const url = new URL(request.url);
  const name = artifactName(
    url.searchParams.get("name") ?? request.headers.get("x-file-name"),
  );
  const fileId = `wrf-${crypto.randomUUID()}`;
  const stored = await storeWorkRequestFile(env, {
    fileId,
    threadId,
    spaceId: spaceId ?? null,
    userId: context.userId,
    name,
    upload,
  });
  return json(
    {
      file: {
        fileId,
        name,
        mediaType: upload.mediaType,
        sizeBytes: stored.sizeBytes,
        contentDigest: stored.digest,
      },
    },
    { status: 201 },
  );
}

export interface WorkRequestFileUpload {
  readonly mediaType: string;
  /**
   * Exact byte length. Actual for a buffered body; for a stream it is the
   * declared Content-Length, which the store enforces byte for byte.
   */
  readonly sizeBytes: number;
  readonly body?: ArrayBuffer;
  readonly stream?: ReadableStream<Uint8Array>;
  readonly previewImage?: string;
}

/**
 * Reads one upload. A raw body is never buffered: it stays a stream bounded by
 * its Content-Length. A multipart body (used to carry a JPEG preview) is
 * buffered, so it is only accepted up to the Free file size; larger files must
 * be sent raw.
 */
export async function readWorkRequestFileUpload(
  request: Request,
  limits: AttachmentLimits,
): Promise<WorkRequestFileUpload> {
  const multipart = !!request.headers
    .get("content-type")
    ?.startsWith("multipart/form-data");
  const header = request.headers.get("content-length");
  const declared = header === null ? null : Number(header);
  if (declared !== null && (!Number.isSafeInteger(declared) || declared < 0))
    throw new HttpError(400, "Invalid Content-Length");
  if (
    declared !== null &&
    declared > limits.fileBytes + (multipart ? 24 * 1024 : 0)
  )
    throw new FileTooLargeError(limits);
  const rawType = request.headers.get("content-type");
  if (multipart) {
    if (declared === null || declared > MULTIPART_BUFFER_LIMIT_BYTES)
      throw new UploadRequirementError(
        413,
        "Files this large must be uploaded as a raw request body, without a preview",
        "upload_requires_raw_body",
      );
    const form = await request.formData();
    const file = form.get("file");
    if (!file || typeof file === "string")
      throw new HttpError(400, "File content is required");
    const body = await file.arrayBuffer();
    if (body.byteLength > limits.fileBytes) throw new FileTooLargeError(limits);
    const type = form.get("mediaType");
    const preview = form.get("previewImage");
    let previewImage: string | undefined;
    if (typeof preview === "string") {
      if (
        preview.length > MAX_PREVIEW_IMAGE_CHARS ||
        !/^[A-Za-z0-9+/]*={0,2}$/.test(preview) ||
        !preview.startsWith("/9j/")
      )
        throw new HttpError(400, "Invalid image preview");
      previewImage = preview;
    }
    return {
      body,
      sizeBytes: body.byteLength,
      mediaType: mediaTypeOf(typeof type === "string" ? type : rawType),
      ...(previewImage ? { previewImage } : {}),
    };
  }
  if (declared === null)
    throw new UploadRequirementError(
      411,
      "Content-Length is required",
      "content_length_required",
    );
  return declared === 0 || !request.body
    ? {
        body: new ArrayBuffer(0),
        sizeBytes: 0,
        mediaType: mediaTypeOf(rawType),
      }
    : {
        stream: request.body,
        sizeBytes: declared,
        mediaType: mediaTypeOf(rawType),
      };
}

function mediaTypeOf(value: string | null): string {
  return (
    value?.split(";", 1)[0]?.trim().slice(0, 128) || "application/octet-stream"
  );
}

class UploadSizeMismatchError extends HttpError {
  readonly code = "upload_size_mismatch";
  constructor() {
    super(400, "The uploaded file size did not match the declared size");
  }
}

/**
 * Writes uploaded bytes to R2 under [fileId], bound to the uploading user and
 * Thread, and records them for My Files and the storage quota.
 *
 * The uploader's storage is reserved first (atomically, see `reserveUpload`),
 * the stored object's real size is verified, entitlement and quota are
 * rechecked at finalization without counting the upload twice, and the
 * `user_files` row and reservation release are one batch. Any failure deletes
 * the partial object and releases the reservation. Rewriting the same [fileId]
 * (a retried or restarted upload) replaces the object and its accounting.
 */
export async function storeWorkRequestFile(
  env: SecurityEnv,
  input: {
    fileId: string;
    threadId: string;
    spaceId: string | null;
    userId: string;
    name: string;
    upload: WorkRequestFileUpload;
    workRequestId?: string;
    /** Set for a file a Worker produced for the user in this assignment. */
    assignmentId?: string;
  },
): Promise<{
  digest: string;
  sizeBytes: number;
  previewText?: string;
  previewImage?: string;
}> {
  const bucket = env.SYNTILA_ARTIFACTS;
  if (!bucket) throw new HttpError(503, "File storage is not configured");
  const { upload } = input;
  const { mediaType, previewImage, sizeBytes } = upload;
  const key = workRequestFileKey(input.fileId);
  await reserveUpload(env as unknown as Env, {
    fileId: input.fileId,
    userId: input.userId,
    sizeBytes,
  });
  let written = false;
  try {
    const metadata = {
      threadId: input.threadId,
      userId: input.userId,
      name: input.name,
      ...(input.workRequestId ? { workRequestId: input.workRequestId } : {}),
      ...(input.assignmentId
        ? { assignmentId: input.assignmentId, source: "worker_output" }
        : {}),
    };
    let digest: string;
    let head: Uint8Array;
    const putOptions = (extra: Record<string, string>): R2PutOptions => ({
      httpMetadata: { contentType: mediaType },
      customMetadata: { ...metadata, ...extra },
    });
    if (upload.body) {
      digest = await computePackageDigest(upload.body);
      head = new Uint8Array(upload.body.slice(0, 1200));
      const preview = fileTextPreview(input.name, mediaType, upload.body);
      await bucket.put(
        key,
        upload.body,
        putOptions({
          digest,
          ...(preview || previewImage ? { hasPreview: "1" } : {}),
        }),
      );
    } else {
      // The digest is only known after the stream ends, so it is stamped on
      // the object by a metadata-free put followed by `head`-verified reads.
      const result = await putStream(
        bucket,
        key,
        upload.stream!,
        sizeBytes,
        putOptions({}),
      ).catch((error: unknown) => {
        throw error instanceof UploadStreamError
          ? new UploadSizeMismatchError()
          : error;
      });
      digest = result.digest;
      head = result.head;
    }
    written = true;
    const stored = await bucket.head(key);
    if (!stored || stored.size !== sizeBytes)
      throw new UploadSizeMismatchError();
    const previewText = fileTextPreview(
      input.name,
      mediaType,
      head.buffer.slice(
        head.byteOffset,
        head.byteOffset + head.byteLength,
      ) as ArrayBuffer,
    );
    if (!upload.body)
      // R2 metadata is fixed at write time, so the streamed object's digest
      // and preview flag are carried by a small sidecar object.
      await bucket.put(
        `${key}/meta`,
        JSON.stringify({ digest, hasPreview: !!(previewText || previewImage) }),
        { httpMetadata: { contentType: "application/json" } },
      );
    if (previewText || previewImage)
      await bucket.put(
        `${key}/preview`,
        JSON.stringify({ previewText, previewImage }),
        { httpMetadata: { contentType: "application/json" } },
      );
    // Finalization recheck: entitlement and quota again, excluding this
    // upload's own reservation, so a downgrade mid-upload is honored.
    await reserveUpload(env as unknown as Env, {
      fileId: input.fileId,
      userId: input.userId,
      sizeBytes: stored.size,
    });
    await env.SYNTILA_DB.batch([
      env.SYNTILA_DB.prepare(
        `INSERT OR REPLACE INTO user_files
          (id, user_id, thread_id, space_id, name, media_type, size_bytes, created_at)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
      ).bind(
        input.fileId,
        input.userId,
        input.threadId,
        input.spaceId,
        input.name,
        mediaType,
        stored.size,
        new Date().toISOString(),
      ),
      env.SYNTILA_DB.prepare(
        "DELETE FROM user_file_reservations WHERE id = ?1 AND user_id = ?2",
      ).bind(input.fileId, input.userId),
    ]);
    return {
      digest,
      sizeBytes: stored.size,
      ...(previewText ? { previewText } : {}),
      ...(previewImage ? { previewImage } : {}),
    };
  } catch (error) {
    // Rejected, failed or abandoned: nothing may keep the quota.
    if (written)
      await bucket
        .delete([key, `${key}/meta`, `${key}/preview`])
        .catch(() => undefined);
    await releaseUpload(env.SYNTILA_DB, input.fileId, input.userId).catch(
      () => undefined,
    );
    throw error;
  }
}

/** Confirms an uploaded file belongs to this user and Thread and matches the claim. */
/**
 * The stored file's content digest: object metadata for buffered uploads, the
 * sidecar for streamed ones (their digest is known only after the bytes land).
 */
export async function storedFileDigest(
  env: SecurityEnv,
  fileId: string,
  metadata: Record<string, string> | undefined,
): Promise<string | null> {
  if (metadata?.digest !== undefined) return metadata.digest;
  const sidecar = await env.SYNTILA_ARTIFACTS?.get(
    `${workRequestFileKey(fileId)}/meta`,
  );
  return sidecar
    ? ((await sidecar.json<{ digest?: string }>()).digest ?? null)
    : null;
}

export async function verifyWorkRequestFile(
  env: SecurityEnv,
  fileId: string,
  threadId: string,
  userId: string,
  sizeBytes: unknown,
): Promise<{ digest: string; previewText?: string; previewImage?: string }> {
  const key = workRequestFileKey(fileId);
  const object = await env.SYNTILA_ARTIFACTS?.head(key);
  const meta = object?.customMetadata;
  // An already stored file stays referenceable whatever the uploader's
  // current plan or quota (a downgrade or an over-quota account must not lose
  // access); only an absolute sanity bound applies.
  if (
    !object ||
    meta?.threadId !== threadId ||
    meta?.userId !== userId ||
    object.size > MAX_STORED_FILE_BYTES ||
    object.size !== sizeBytes
  )
    throw new HttpError(400, "Attached file was not found or does not match");
  // Streamed uploads learn their digest only after the bytes are stored, so
  // it lives in a sidecar; older objects carry it in their metadata.
  const sidecar =
    meta.digest === undefined
      ? await env.SYNTILA_ARTIFACTS?.get(`${key}/meta`)
      : null;
  const stored = sidecar
    ? await sidecar.json<{ digest?: string; hasPreview?: boolean }>()
    : null;
  const hasPreview = meta.hasPreview === "1" || stored?.hasPreview === true;
  const preview = hasPreview
    ? await env.SYNTILA_ARTIFACTS?.get(`${key}/preview`)
    : null;
  const display = preview
    ? await preview.json<{ previewText?: string; previewImage?: string }>()
    : {};
  return {
    ...display,
    digest: meta.digest ?? stored?.digest ?? "",
  };
}

/** Metadata and bounded display previews for authenticated Work history. */
export function workRequestFileMetadata(input: Record<string, unknown>) {
  if (!Array.isArray(input.attachments)) return [];
  return input.attachments.flatMap((value: unknown) => {
    if (!value || typeof value !== "object") return [];
    const file = value as Record<string, unknown>;
    if (file.kind !== "file") return [];
    return [
      {
        kind: "file" as const,
        ...(isWorkRequestFileId(file.fileId) ? { fileId: file.fileId } : {}),
        name: typeof file.name === "string" ? file.name : "Attachment",
        sizeBytes: typeof file.sizeBytes === "number" ? file.sizeBytes : 0,
        ...(typeof file.previewImage === "string"
          ? { previewImage: file.previewImage }
          : {}),
        ...(typeof file.previewText === "string"
          ? { previewText: file.previewText.slice(0, 1200) }
          : {}),
      },
    ];
  });
}

/** Plain text only; attached markup is never executed by the client. */
export function fileTextPreview(
  name: string,
  mediaType: string,
  body: ArrayBuffer,
): string | undefined {
  if (
    !mediaType.startsWith("text/") &&
    !/\.(txt|md|csv|json|yaml|yml|dart|ts|js|py|log)$/i.test(name)
  )
    return undefined;
  return (
    new TextDecoder()
      .decode(body.slice(0, 1200))
      // eslint-disable-next-line no-control-regex -- Remove null bytes from decoded text preview.
      .replace(/\u0000/g, "")
      .slice(0, 1200)
  );
}

/** Uses verified object metadata, never client-authored preview content. */
export async function normalizeDiscussionAttachments(
  env: SecurityEnv,
  raw: unknown,
  threadId: string,
  userId: string,
) {
  if (raw === undefined) return [];
  if (!Array.isArray(raw) || raw.length > MAX_WORK_REQUEST_FILES)
    throw new HttpError(400, "Choose up to 10 attachments");
  return Promise.all(
    raw.map(async (value: unknown) => {
      if (!value || typeof value !== "object")
        throw new HttpError(400, "Invalid attachment");
      const file = value as Record<string, unknown>;
      if (file.kind !== "file" || !isWorkRequestFileId(file.fileId))
        throw new HttpError(400, "Invalid attachment");
      const stored = await verifyWorkRequestFile(
        env,
        file.fileId,
        threadId,
        userId,
        file.sizeBytes,
      );
      const object = await env.SYNTILA_ARTIFACTS!.head(
        workRequestFileKey(file.fileId),
      );
      return {
        kind: "file",
        fileId: file.fileId,
        name: object!.customMetadata?.name ?? "Attachment",
        sizeBytes: object!.size,
        mediaType:
          object!.httpMetadata?.contentType ?? "application/octet-stream",
        ...stored,
      };
    }),
  );
}

/** Downloads remain authenticated and restricted to accepted Thread references. */
export async function handleDownloadThreadFile(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  fileId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeThreadAccess(request, env, threadId, "view", accessContext);
  if (!isWorkRequestFileId(fileId)) throw new HttpError(404, "File not found");
  const reference = await env.SYNTILA_DB.prepare(
    `SELECT 1 AS present FROM discussion_messages dm, json_each(dm.attachments_json) f
    WHERE dm.thread_id = ?1 AND json_extract(f.value, '$.fileId') = ?2
    UNION ALL SELECT 1 AS present FROM work_requests wr, json_each(wr.input_json, '$.attachments') f
    WHERE wr.thread_id = ?1 AND json_extract(f.value, '$.fileId') = ?2
    UNION ALL SELECT 1 AS present FROM worker_assignments wa, json_each(wa.output_json, '$.output.images') f
    WHERE wa.status = 'completed' AND json_extract(f.value, '$.fileId') = ?2
    UNION ALL SELECT 1 AS present FROM worker_assignments wa, json_each(wa.output_json, '$.output.files') f
    WHERE wa.status = 'completed' AND json_extract(f.value, '$.fileId') = ?2 LIMIT 1`,
  )
    .bind(threadId, fileId)
    .first();
  if (!reference) throw new HttpError(404, "File not found");
  const object = await env.SYNTILA_ARTIFACTS?.get(workRequestFileKey(fileId));
  // Worker outputs are referenced by a completed assignment whose own
  // `thread_id` may be empty (workflow dispatch); the object's Thread binding,
  // written at upload from the assignment's Work Request, scopes them.
  if (!object || object.customMetadata?.threadId !== threadId)
    throw new HttpError(404, "File not found");
  return new Response(object.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Disposition": "attachment",
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
