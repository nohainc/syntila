import type { SecurityContext } from "@syntila/security";
import { extractBearerToken } from "@syntila/security";
import { hasProfileLabPermission } from "./profile-lab-policy.js";
import {
  getCurrentWorkerProfile,
  listWorkerProfileHistory,
  listWorkerProfiles,
  publishWorkerProfile,
  restoreWorkerProfile,
  validateWorkerProfileCandidate,
} from "../worker-profile-registry.js";
import type { SecurityEnv } from "./http-security.js";
import { HttpError, json, securityContext } from "./http-security.js";
import { WorkspaceRuntimeAuthenticator } from "../workspace-gateway/runtime-authenticator.js";

export async function authorizeToolProfileAdmin(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
  permission: "profiles:admin" | "profiles:release:manage" = "profiles:admin",
): Promise<SecurityContext> {
  const actor = await securityContext(request, env, ctx);
  if (!(await hasProfileLabPermission(env, actor, permission))) {
    throw new HttpError(403, `The ${permission} permission is required`);
  }
  return actor;
}

export async function readToolProfileAdminBody(
  request: Request,
  allowed: readonly string[],
): Promise<Record<string, unknown>> {
  const maxBytes = 384 * 1024;
  const contentLength = Number(request.headers.get("content-length") ?? 0);
  if (contentLength > maxBytes)
    throw new HttpError(413, "request body is too large");
  const reader = request.body?.getReader();
  if (!reader) throw new HttpError(400, "request body is required");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) {
        await reader.cancel();
        throw new HttpError(413, "request body is too large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new HttpError(400, "request body must be valid JSON");
  }
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.keys(value).some((key) => !allowed.includes(key))
  ) {
    throw new HttpError(400, "request body contains unsupported fields");
  }
  return value as Record<string, unknown>;
}

function requireBodyNumber(
  body: Record<string, unknown>,
  field: string,
): number {
  const value = body[field];
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 0 ||
    value > 2_147_483_647
  ) {
    throw new HttpError(400, `${field} is invalid`);
  }
  return value;
}

function snapshotResponse(
  snapshot: Awaited<ReturnType<typeof getCurrentWorkerProfile>>,
) {
  return {
    workerTypeId: snapshot.workerTypeId,
    schemaVersion: snapshot.schemaVersion,
    profile: snapshot.profile,
    revision: snapshot.revision,
    digest: snapshot.digest,
    updatedByUserId: snapshot.updatedByUserId,
    updatedAt: snapshot.updatedAt,
  };
}

export async function handleListV9WorkerProfiles(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  await authorizeToolProfileAdmin(request, env, ctx);
  return json(await listWorkerProfiles(env.SYNTILA_DB));
}

export async function handleGetV9WorkerProfile(
  request: Request,
  env: SecurityEnv,
  workerTypeId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  await authorizeToolProfileAdmin(request, env, ctx);
  return json(
    snapshotResponse(await getCurrentWorkerProfile(env, workerTypeId)),
  );
}

export async function handleValidateV9WorkerProfile(
  request: Request,
  env: SecurityEnv,
  workerTypeId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  await authorizeToolProfileAdmin(request, env, ctx);
  const body = await readToolProfileAdminBody(request, [
    "profile",
    "candidateDigest",
    "evidence",
  ]);
  const validated = await validateWorkerProfileCandidate(
    workerTypeId,
    body.profile,
    body.candidateDigest,
    body.evidence,
  );
  return json({
    valid: true,
    workerTypeId,
    schemaVersion: validated.profile.schemaVersion,
    profile: validated.profile,
    canonicalJson: validated.canonicalJson,
    digest: validated.digest,
    evidenceAccepted: validated.evidence !== null,
  });
}

export async function handlePublishV9WorkerProfile(
  request: Request,
  env: SecurityEnv,
  workerTypeId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await authorizeToolProfileAdmin(request, env, ctx);
  const body = await readToolProfileAdminBody(request, [
    "expectedRevision",
    "profile",
    "candidateDigest",
    "evidence",
  ]);
  const snapshot = await publishWorkerProfile({
    env,
    workerTypeId,
    expectedRevision: requireBodyNumber(body, "expectedRevision"),
    candidate: body.profile,
    candidateDigest: body.candidateDigest,
    evidence: body.evidence,
    actorUserId: actor.userId,
  });
  return json(snapshotResponse(snapshot), { status: 200 });
}

export async function handleListV9WorkerProfileHistory(
  request: Request,
  env: SecurityEnv,
  workerTypeId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  await authorizeToolProfileAdmin(request, env, ctx);
  return json(await listWorkerProfileHistory(env, workerTypeId));
}

export async function handleRestoreV9WorkerProfile(
  request: Request,
  env: SecurityEnv,
  workerTypeId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await authorizeToolProfileAdmin(request, env, ctx);
  const body = await readToolProfileAdminBody(request, [
    "expectedRevision",
    "targetRevision",
    "restorationReason",
  ]);
  if (typeof body.restorationReason !== "string") {
    throw new HttpError(400, "restorationReason is required");
  }
  const snapshot = await restoreWorkerProfile({
    env,
    workerTypeId,
    expectedRevision: requireBodyNumber(body, "expectedRevision"),
    targetRevision: requireBodyNumber(body, "targetRevision"),
    restorationReason: body.restorationReason,
    actorUserId: actor.userId,
  });
  return json(snapshotResponse(snapshot), { status: 200 });
}

async function requireAuthorizedWorkspaceRuntime(
  request: Request,
  env: SecurityEnv,
): Promise<void> {
  const url = new URL(request.url);
  const runtimeId = url.searchParams.get("workspaceRuntimeId");
  const credential = extractBearerToken(request.headers);
  if (!runtimeId || !credential) {
    throw new HttpError(401, "Workspace runtime credentials are required");
  }
  const runtime = await new WorkspaceRuntimeAuthenticator(
    env.SYNTILA_DB,
  ).authenticateRuntime(runtimeId, credential);
  if (!runtime) {
    throw new HttpError(401, "Workspace runtime credential is invalid");
  }
}

export async function handleGetWorkspaceV9WorkerProfile(
  request: Request,
  env: SecurityEnv,
  workerTypeId: string,
): Promise<Response> {
  // Profile synchronization precedes local configuration and inventory
  // publication. Any authenticated runtime can read the current catalog
  // Profile; local installation is not an authorization prerequisite.
  await requireAuthorizedWorkspaceRuntime(request, env);
  return json(
    snapshotResponse(await getCurrentWorkerProfile(env, workerTypeId)),
  );
}

export async function handleProfileLabAccess(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await securityContext(request, env, ctx);
  const profilesAdmin = await hasProfileLabPermission(env, actor);
  const issueSupport = (env.SYNTILA_ISSUE_SUPPORT_USER_IDS ?? "")
    .split(",")
    .map((id) => id.trim())
    .filter(Boolean)
    .includes(actor.userId);
  return new Response(
    JSON.stringify({
      schemaVersion: 1,
      authenticated: true,
      audience: actor.audience ?? null,
      permissions: { profilesAdmin, issueSupport },
    }),
    {
      headers: {
        "content-type": "application/json",
        "cache-control": "no-store",
      },
    },
  );
}
