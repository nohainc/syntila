import { MAX_ARTIFACT_UPLOAD_BYTES } from "./handlers.js";

import { computePackageDigest } from "@syntila/security";
import { createEventPublisher } from "../event-publisher.js";
import {
  HttpError,
  artifactMetadata,
  artifactName,
  authorizeRequest,
  json,
  parseJson,
  recordAudit,
  workspaceOwnerContext,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

export async function handleUploadArtifact(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const url = new URL(request.url);
  const spaceId = url.searchParams.get("spaceId");
  const runId = url.searchParams.get("runId");
  const taskId = url.searchParams.get("taskId");
  const attemptId = url.searchParams.get("attemptId");
  const assignmentId = url.searchParams.get("assignmentId");
  if (!spaceId || !runId) {
    throw new HttpError(400, "spaceId and runId are required");
  }
  const context = await workspaceOwnerContext(
    request,
    env,
    workspaceId,
    "spaces:read",
    accessContext,
  );
  const scope = await env.SYNTILA_DB.prepare(
    `SELECT p.workspace_id AS workspaceId
       FROM spaces p JOIN runs r ON r.space_id = p.id
      WHERE p.id = ?1 AND r.id = ?2 AND p.workspace_id = ?3`,
  )
    .bind(spaceId, runId, workspaceId)
    .first<{ workspaceId: string }>();
  if (!scope) throw new HttpError(404, "Artifact scope not found");
  const lengthHeader = request.headers.get("content-length");
  const declaredLength = lengthHeader ? Number(lengthHeader) : null;
  if (
    declaredLength !== null &&
    (!Number.isSafeInteger(declaredLength) ||
      declaredLength > MAX_ARTIFACT_UPLOAD_BYTES)
  ) {
    throw new HttpError(413, "Artifact exceeds the 64 MiB upload limit");
  }
  const artifactId =
    url.searchParams.get("artifactId") ??
    request.headers.get("x-artifact-id") ??
    `artifact-${crypto.randomUUID()}`;
  const existing = await env.SYNTILA_DB.prepare(
    "SELECT * FROM artifacts WHERE id = ?1",
  )
    .bind(artifactId)
    .first<Record<string, unknown>>();
  if (existing) {
    if (String(existing.workspace_id) !== workspaceId) {
      throw new HttpError(409, "Artifact upload identity is already in use");
    }
    return json({ artifact: artifactMetadata(existing), deduplicated: true });
  }
  const body = await request.arrayBuffer();
  if (body.byteLength > MAX_ARTIFACT_UPLOAD_BYTES) {
    throw new HttpError(413, "Artifact exceeds the 64 MiB upload limit");
  }
  const mediaType =
    request.headers.get("content-type")?.split(";", 1)[0]?.trim() ||
    "application/octet-stream";
  const name = artifactName(
    url.searchParams.get("name") ?? request.headers.get("x-artifact-name"),
  );
  const computedDigest = await computePackageDigest(body);
  const suppliedDigest = request.headers.get("x-content-digest");
  if (suppliedDigest && suppliedDigest !== computedDigest) {
    throw new HttpError(422, "Artifact content digest does not match payload");
  }
  const digest = suppliedDigest ?? computedDigest;
  const storageKey = `artifact-objects/${workspaceId}/${crypto.randomUUID()}`;
  const bucket = env.SYNTILA_ARTIFACTS;
  if (!bucket) throw new HttpError(503, "Artifact storage is not configured");
  await bucket.put(storageKey, body, {
    httpMetadata: { contentType: mediaType },
    customMetadata: { artifactId, workspaceId, digest },
  });
  const now = new Date().toISOString();
  try {
    await env.SYNTILA_DB.prepare(
      `INSERT INTO artifacts
       (id, workspace_id, space_id, run_id, task_id, attempt_id, assignment_id,
        media_type, content_digest, storage_kind, storage_key, inline_content,
        size_bytes, provenance_json, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'r2', ?10, NULL, ?11, ?12, ?13)`,
    )
      .bind(
        artifactId,
        workspaceId,
        spaceId,
        runId,
        taskId,
        attemptId,
        assignmentId,
        mediaType,
        digest,
        storageKey,
        body.byteLength,
        JSON.stringify({ name }),
        now,
      )
      .run();
  } catch (error) {
    await bucket.delete(storageKey).catch(() => undefined);
    throw error;
  }
  const row = await env.SYNTILA_DB.prepare(
    "SELECT * FROM artifacts WHERE id = ?1",
  )
    .bind(artifactId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(500, "Artifact record was not created");
  await createEventPublisher(env).publish({
    type: "artifact.created",
    workspaceId,
    spaceId,
    runId,
    taskId: taskId ?? undefined,
    assignmentId: assignmentId ?? undefined,
    payload: {
      artifactId,
      entityId: artifactId,
      status: "available",
      summary: `${name} is ready to download`,
    },
  });
  await recordAudit(env, context, "artifact.created", "artifact", artifactId, {
    spaceId,
    runId,
    sizeBytes: body.byteLength,
    mediaType,
  });
  return json({ artifact: artifactMetadata(row) }, { status: 201 });
}

export async function handleGetArtifact(
  request: Request,
  env: SecurityEnv,
  artifactId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const row = await env.SYNTILA_DB.prepare(
    "SELECT * FROM artifacts WHERE id = ?1",
  )
    .bind(artifactId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Artifact not found");
  await authorizeRequest(
    request,
    env,
    "spaces:read",
    String(row.space_id),
    accessContext,
  );
  if (request.method === "HEAD") {
    return new Response(null, {
      status: 200,
      headers: {
        "content-type": String(row.media_type),
        "content-length": String(row.size_bytes),
      },
    });
  }
  if (row.storage_kind === "inline") {
    return new Response(String(row.inline_content ?? ""), {
      headers: { "content-type": String(row.media_type) },
    });
  }
  const object = await env.SYNTILA_ARTIFACTS.get(String(row.storage_key));
  if (!object) throw new HttpError(404, "Artifact content not found");
  const provenance = parseJson<Record<string, unknown>>(
    row.provenance_json,
    {},
  );
  return new Response(object.body, {
    headers: {
      "content-type": String(row.media_type),
      "content-length": String(row.size_bytes),
      "content-disposition": `inline; filename="${artifactName(typeof provenance.name === "string" ? provenance.name : null)}"`,
      "cache-control": "private, no-store",
    },
  });
}

// =========================================================================
// Workspace Artifacts & Worker Inventory Handlers
// =========================================================================
