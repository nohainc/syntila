import { dataOf } from "../platform/data.js";
import { extractBearerToken, hashToken, timingSafeEqual } from "@syntila/security";
import { isTerminalAssignmentStatus } from "@syntila/core";
import type { AssignmentLifecycleStatus } from "@syntila/core";
import { authenticateAgentSession, type AgentPrincipal } from "./worker-agents.js";
import { HttpError, json, type SecurityEnv } from "./routes/http-security.js";
import {
  readWorkRequestFileUpload,
  storeWorkRequestFile,
  workRequestFileKey,
  workRequestFileName,
} from "./routes/work-request-files.js";
import { getAttachmentLimits } from "./account-plan.js";
import { isFeatureEnabled } from "../feature-flags.js";

/**
 * Cross-Worker artifact handoff (ADR-037). Two Workers in one Thread do not
 * share a filesystem, so a step names an artifact ID and the downstream Agent
 * downloads it with a grant bound to that artifact and that Worker. A local
 * path is never a handoff.
 */

export const ARTIFACT_ID = /^art-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const ARTIFACT_RETENTION_DAYS = 7;
export const ARTIFACT_GRANT_TTL_SECONDS = 15 * 60;

export class MissingArtifactError extends Error {
  constructor(readonly reference: string) {
    super(
      ARTIFACT_ID.test(reference)
        ? `Missing artifact: ${reference} is not available`
        : "Missing artifact: a step hands off by artifact ID or Git reference, never by a local path",
    );
  }
}

/** Authenticates the calling Agent by its session (Bearer token, worker and session ids). */
async function agentOf(request: Request, env: SecurityEnv): Promise<AgentPrincipal> {
  if (!isFeatureEnabled("artifact_handoff")) throw new HttpError(404, "Not found");
  const token = extractBearerToken(request.headers);
  const workerId = request.headers.get("x-worker-id");
  const sessionId = request.headers.get("x-worker-session-id");
  if (!token || !workerId || !sessionId) throw new HttpError(401, "Agent credentials are required");
  const agent = await authenticateAgentSession(env as never, { workerId, sessionId, sessionToken: token });
  if (!agent) throw new HttpError(401, "Agent session is not valid");
  return agent;
}

/** Frees the owner's quota for a file that is gone. */
async function removeUserFile(env: SecurityEnv, fileId: string): Promise<void> {
  await dataOf(env).read.run`DELETE FROM user_files WHERE id = ${fileId}`;
}

const hexOf = (digest: string) => digest.replace(/^sha256:/, "").toLowerCase();

/**
 * POST /api/worker-agent/artifacts?assignmentId=&name= — raw body, with the
 * content's SHA-256 in `X-Content-Sha256`. The stored bytes are re-hashed and a
 * mismatch is refused and removed. Replaying the same upload returns the
 * artifact already stored.
 */
export async function handleUploadArtifact(request: Request, env: SecurityEnv): Promise<Response> {
  const agent = await agentOf(request, env);
  const url = new URL(request.url);
  const assignmentId = url.searchParams.get("assignmentId");
  const claimed = request.headers.get("x-content-sha256")?.trim().toLowerCase().replace(/^sha256:/, "");
  if (!assignmentId) throw new HttpError(400, "assignmentId is required");
  if (!claimed || !/^[0-9a-f]{64}$/.test(claimed)) throw new HttpError(400, "X-Content-Sha256 is required");
  const name = workRequestFileName(url.searchParams.get("name"));
  const read = dataOf(env).read;
  const assignment = await read.row<{
    status: string; threadId: string | null; workRequestId: string | null; spaceId: string; ownerUserId: string;
  }>`SELECT wa.status, COALESCE(NULLIF(wa.thread_id, ''), wr.thread_id) AS "threadId",
            wr.id AS "workRequestId", t.space_id AS "spaceId", s.owner_user_id AS "ownerUserId"
       FROM worker_assignments wa
       LEFT JOIN conversation_turns ct ON ct.assignment_id = wa.id
       LEFT JOIN work_requests wr ON wr.id = COALESCE(NULLIF(wa.work_request_id, ''), ct.work_request_id)
       JOIN threads t ON t.id = COALESCE(NULLIF(wa.thread_id, ''), wr.thread_id)
       JOIN spaces s ON s.id = t.space_id
      WHERE wa.id = ${assignmentId} AND wa.worker_instance_id = ${agent.workerInstanceId}
      LIMIT 1`;
  if (!assignment?.threadId) throw new HttpError(404, "Assignment not found");
  if (isTerminalAssignmentStatus(assignment.status as AssignmentLifecycleStatus))
    throw new HttpError(409, "Assignment has already finished");

  const existing = await read.row<Record<string, unknown>>`SELECT id AS "artifactId", name, media_type AS "mediaType",
         size_bytes AS "sizeBytes", content_digest AS "sha256", expires_at AS "expiresAt"
    FROM artifacts WHERE assignment_id = ${assignmentId} AND name = ${name} AND content_digest = ${`sha256:${claimed}`}
     AND state = 'available'`;
  if (existing) return json({ artifact: existing });

  const limits = await getAttachmentLimits(env as never, assignment.ownerUserId);
  const upload = await readWorkRequestFileUpload(request, limits);
  const fileId = `wrf-${crypto.randomUUID()}`;
  const stored = await storeWorkRequestFile(env, {
    fileId, name, upload, assignmentId,
    threadId: assignment.threadId, spaceId: assignment.spaceId, userId: assignment.ownerUserId,
    ...(assignment.workRequestId ? { workRequestId: assignment.workRequestId } : {}),
  });
  if (hexOf(stored.digest) !== claimed) {
    const key = workRequestFileKey(fileId);
    await env.SYNTILA_ARTIFACTS?.delete([key, `${key}/meta`, `${key}/preview`]).catch(() => undefined);
    await removeUserFile(env, fileId);
    throw new HttpError(422, "Checksum does not match the uploaded content");
  }
  const artifactId = `art-${crypto.randomUUID()}`;
  const expiresAt = new Date(Date.now() + ARTIFACT_RETENTION_DAYS * 86_400_000).toISOString();
  await dataOf(env).tx("artifact.register", async (tx) => {
    await tx.run`INSERT INTO artifacts
        (id, space_id, thread_id, work_request_id, assignment_id, content_digest, storage_key, created_at,
         worker_instance_id, name, media_type, size_bytes, state, expires_at)
      VALUES (${artifactId}, ${assignment.spaceId}, ${assignment.threadId}, ${assignment.workRequestId}, ${assignmentId},
              ${stored.digest}, ${workRequestFileKey(fileId)}, now(),
              ${agent.workerInstanceId}, ${name}, ${upload.mediaType}, ${stored.sizeBytes}, 'available', ${expiresAt}::timestamptz)`;
  });
  return json({ artifact: { artifactId, name, mediaType: upload.mediaType, sizeBytes: stored.sizeBytes, sha256: stored.digest, expiresAt } }, { status: 201 });
}

/** A step input must be an artifact ID that is available in the same Space. */
export async function assertHandoffAvailable(
  env: SecurityEnv,
  input: { artifactIds: readonly string[]; spaceId: string },
): Promise<void> {
  for (const id of input.artifactIds) {
    if (!ARTIFACT_ID.test(id)) throw new MissingArtifactError(id);
    const found = await dataOf(env).read.row`SELECT 1 AS present FROM artifacts
      WHERE id = ${id} AND space_id = ${input.spaceId} AND state = 'available'
        AND (expires_at IS NULL OR expires_at > now())`;
    if (!found) throw new MissingArtifactError(id);
  }
}

export interface ArtifactDescriptor {
  readonly artifactId: string;
  readonly name: string;
  readonly mediaType: string;
  readonly sizeBytes: number;
  readonly sha256: string;
  readonly grant: { readonly token: string; readonly expiresAt: string };
}

/** Mints one expiring grant per artifact for the Worker that will run the step. */
export async function mintHandoffGrants(
  env: SecurityEnv,
  input: { artifactIds: readonly string[]; workerInstanceId: string; assignmentId: string },
): Promise<ArtifactDescriptor[]> {
  const expiresAt = new Date(Date.now() + ARTIFACT_GRANT_TTL_SECONDS * 1000).toISOString();
  const out: ArtifactDescriptor[] = [];
  for (const id of input.artifactIds) {
    const row = await dataOf(env).read.row<{ name: string | null; mediaType: string | null; sizeBytes: string | null; sha256: string }>`
      SELECT name, media_type AS "mediaType", size_bytes::text AS "sizeBytes", content_digest AS sha256
        FROM artifacts WHERE id = ${id} AND state = 'available'`;
    if (!row) throw new MissingArtifactError(id);
    const token = `agt-${crypto.randomUUID()}${crypto.randomUUID()}`.replaceAll("-", "");
    await dataOf(env).read.run`INSERT INTO artifact_download_grants
        (id, artifact_id, worker_instance_id, assignment_id, token_digest, expires_at)
      VALUES (${`grant-${crypto.randomUUID()}`}, ${id}, ${input.workerInstanceId}, ${input.assignmentId},
              ${await hashToken(token)}, ${expiresAt}::timestamptz)`;
    out.push({
      artifactId: id, name: row.name ?? "artifact", mediaType: row.mediaType ?? "application/octet-stream",
      sizeBytes: Number(row.sizeBytes ?? 0), sha256: row.sha256, grant: { token, expiresAt },
    });
  }
  return out;
}

/**
 * GET /api/worker-agent/artifacts/:artifactId/content — the Agent's session and
 * the grant (`X-Artifact-Grant`) must both match; the grant is bound to this
 * artifact and this Worker and expires.
 */
export async function handleDownloadArtifact(request: Request, env: SecurityEnv, artifactId: string): Promise<Response> {
  const agent = await agentOf(request, env);
  const token = request.headers.get("x-artifact-grant");
  if (!token || !ARTIFACT_ID.test(artifactId)) throw new HttpError(404, "Artifact not found");
  const digest = await hashToken(token);
  const grant = await dataOf(env).read.row<{ digest: string; storageKey: string; sha256: string; name: string | null }>`
    SELECT g.token_digest AS digest, a.storage_key AS "storageKey", a.content_digest AS sha256, a.name
      FROM artifact_download_grants g JOIN artifacts a ON a.id = g.artifact_id
     WHERE g.artifact_id = ${artifactId} AND g.worker_instance_id = ${agent.workerInstanceId}
       AND g.expires_at > now() AND a.state = 'available' AND (a.expires_at IS NULL OR a.expires_at > now())
       AND g.token_digest = ${digest}`;
  if (!grant || !timingSafeEqual(grant.digest, digest)) throw new HttpError(404, "Artifact not found");
  const object = await env.SYNTILA_ARTIFACTS?.get(grant.storageKey);
  if (!object) throw new HttpError(404, "Artifact not found");
  return new Response(object.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Disposition": "attachment",
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
      "X-Content-Sha256": hexOf(grant.sha256),
    },
  });
}

/** Retention: expire due artifacts and their objects, drop spent grants. Never throws. */
export async function expireArtifacts(env: SecurityEnv, limit = 100): Promise<number> {
  const db = dataOf(env).read;
  const due = await db.rows<{ id: string; storageKey: string }>`
    UPDATE artifacts SET state = 'expired'
     WHERE id IN (SELECT id FROM artifacts WHERE state = 'available' AND expires_at <= now() ORDER BY expires_at LIMIT ${limit})
    RETURNING id, storage_key AS "storageKey"`;
  for (const row of due) {
    await env.SYNTILA_ARTIFACTS?.delete([row.storageKey, `${row.storageKey}/meta`, `${row.storageKey}/preview`]).catch(() => undefined);
    await removeUserFile(env, row.storageKey.split("/").pop()!);
  }
  await db.run`DELETE FROM artifact_download_grants WHERE expires_at < now() - interval '1 day'`;
  return due.length;
}
