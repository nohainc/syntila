import {
  hasProfileLabPermission,
  isProfileLabOwner,
} from "./profile-lab-policy.js";
import { isTrustedOrigin } from "../observability.js";
import {
  identityService,
  provisionSyntilaUser,
  hasRecentStepUp,
  recordAuthAuditEvent,
  type SensitiveOperation,
} from "../auth/index.js";
import {
  authorize,
  AuthorizationError,
  hashToken,
  resolveSpaceSecurityContextFromIdentity,
  authorizeSpaceMembership,
  authorizeWorkspaceOwner,
  authorizeSpaceOwner,
  type Permission,
  type SecurityContext,
} from "@syntila/security";

export function parseJson<T = Record<string, unknown>>(
  value: unknown,
  defaultValue: T = {} as T,
): T {
  if (typeof value !== "string" || value.trim().length === 0)
    return defaultValue;
  try {
    return JSON.parse(value) as T;
  } catch {
    return defaultValue;
  }
}

export function json(data: unknown, init?: ResponseInit): Response {
  return Response.json(data, {
    ...init,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...init?.headers,
    },
  });
}

export async function recordAudit(
  env: SecurityEnv,
  context: SecurityContext,
  action: string,
  targetType: string,
  targetId: string,
  details: Record<string, unknown> = {},
  resourceWorkspaceId?: string,
): Promise<void> {
  const auditWorkspaceId = resourceWorkspaceId;
  if (!auditWorkspaceId) {
    const spaceId =
      typeof details.spaceId === "string" ? details.spaceId : null;
    if (!spaceId) return;
    await env.SYNTILA_DB.prepare(
      `INSERT INTO space_audit_log
         (id, space_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'user', ?3, ?4, ?5, ?6, ?7, ?8)`,
    )
      .bind(
        `audit-${crypto.randomUUID()}`,
        spaceId,
        context.userId,
        action,
        targetType,
        targetId,
        JSON.stringify(details),
        new Date().toISOString(),
      )
      .run();
    return;
  }
  const values = [
    `audit-${crypto.randomUUID()}`,
    auditWorkspaceId,
    context.userId,
    action,
    targetType,
    targetId,
    JSON.stringify(details),
    new Date().toISOString(),
  ] as const;
  await env.SYNTILA_DB.prepare(
    `INSERT INTO workspace_audit_log
       (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
     VALUES (?1, ?2, 'user', ?3, ?4, ?5, ?6, ?7, ?8)`,
  )
    .bind(...values)
    .run();
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Workflow operation failed";
}

export function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${field} is required`);
  }
  return value;
}

export function workflowInstanceId(idempotencyKey: string): string {
  return `workflow-${idempotencyKey}`;
}

export async function resolveWorkflowInstanceId(
  env: Env,
  runId: string,
  idempotencyKey?: string,
): Promise<string> {
  const run = await env.SYNTILA_DB.prepare(
    "SELECT workflow_instance_id FROM runs WHERE id = ?1",
  )
    .bind(runId)
    .first<{ workflow_instance_id?: string | null }>();
  if (run?.workflow_instance_id) return run.workflow_instance_id;
  if (!idempotencyKey) return workflowInstanceId(runId);
  const candidate = workflowInstanceId(idempotencyKey);
  const now = new Date().toISOString();
  await env.SYNTILA_DB.prepare(
    "UPDATE runs SET workflow_instance_id = COALESCE(workflow_instance_id, ?1), updated_at = ?2 WHERE id = ?3",
  )
    .bind(candidate, now, runId)
    .run();
  const stored = await env.SYNTILA_DB.prepare(
    "SELECT workflow_instance_id FROM runs WHERE id = ?1",
  )
    .bind(runId)
    .first<{ workflow_instance_id?: string | null }>();
  return stored?.workflow_instance_id ?? candidate;
}

export class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export type SecurityEnv = Env & {
  /** Comma-separated user IDs permitted to administer catalog entries and drafts. */
  readonly SYNTILA_PROFILE_ADMIN_USER_IDS?: string;
  readonly SYNTILA_PROFILE_LAB_OWNER_EMAIL?: string;
  readonly SYNTILA_PROFILE_RELEASE_MANAGER_USER_IDS?: string;
  readonly SYNTILA_ISSUE_SUPPORT_USER_IDS?: string;
  /** Email of the active Syntila account that staffs personal support Spaces. */
  readonly SYNTILA_SUPPORT_ACCOUNT_EMAIL?: string;
  readonly BETTER_AUTH_SECRET?: string;
  readonly BETTER_AUTH_URL?: string;
  readonly SYNTILA_AUTH_GITHUB_CLIENT_ID?: string;
  readonly SYNTILA_AUTH_GITHUB_CLIENT_SECRET?: string;
  readonly SYNTILA_AUTH_GOOGLE_CLIENT_ID?: string;
  readonly SYNTILA_AUTH_GOOGLE_CLIENT_SECRET?: string;
  readonly TEST_AUTHENTICATION?: (
    request: Request,
    env: Env,
  ) => Promise<SecurityContext>;
  readonly SYNTILA_APP_URL?: string;
  readonly SYNTILA_EMAIL_FROM?: string;
  readonly SYNTILA_EMAIL_FALLBACK_FROM?: string;
  readonly SYNTILA_EMAIL_FROM_NAME?: string;
  readonly SYNTILA_WORKSPACE_GATEWAY?: DurableObjectNamespace;
  readonly SYNTILA_REALTIME_GATEWAY?: DurableObjectNamespace;
  readonly SYNTILA_THREAD_COORDINATOR?: DurableObjectNamespace;
};

export function testAuthenticationEnabled(env: Env): boolean {
  return (
    env.SYNTILA_ENVIRONMENT === "development" &&
    typeof (env as SecurityEnv).TEST_AUTHENTICATION === "function"
  );
}

export function bearer(request: Request): string | null {
  const value = request.headers.get("authorization");
  return value?.startsWith("Bearer ") ? value.slice(7) : null;
}

export function requireSameOriginForCookieMutation(request: Request): void {
  if (!request.headers.get("cookie") || bearer(request)) return;

  const requestOrigin = new URL(request.url).origin;
  const origin = request.headers.get("origin");
  if (origin === requestOrigin || (origin && isTrustedOrigin(request))) return;

  const referer = request.headers.get("referer");
  if (origin === null && referer) {
    try {
      if (new URL(referer).origin === requestOrigin) return;
      const refUrl = new URL(referer);
      if (
        refUrl.hostname === "localhost" ||
        refUrl.hostname === "127.0.0.1" ||
        refUrl.hostname === "[::1]"
      ) {
        return;
      }
    } catch {
      // Treat malformed referers as untrusted.
    }
  }

  throw new HttpError(403, "Same-origin request required for cookie session");
}

export async function securityContext(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  // Preserve the route-handler context contract for callers that also use it
  // for non-authentication infrastructure; human identity never comes from it.
  void accessContext;
  const testAuthentication = env.TEST_AUTHENTICATION;
  if (
    env.SYNTILA_ENVIRONMENT === "development" &&
    typeof testAuthentication === "function"
  ) {
    return testAuthentication(request, env);
  }

  {
    const identity = await identityService.resolve(request, env);
    if (!identity) throw new HttpError(401, "Authentication required");
    try {
      await provisionSyntilaUser(env.SYNTILA_DB, identity);
      if (
        identity.audience === "syntila.profile-lab.management" &&
        env.SYNTILA_PROFILE_LAB_OWNER_EMAIL !== undefined &&
        !(await isProfileLabOwner(env, identity.userId))
      ) {
        throw new HttpError(403, "Profile Lab is restricted to its verified owner account");
      }
      return await resolveSpaceSecurityContextFromIdentity(
        env.SYNTILA_DB,
        identity,
        identity.clientType ?? "web",
        identity.audience,
      );
    } catch (err: unknown) {
      if (
        err instanceof Error &&
        "code" in err &&
        (err as { code: string }).code === "UNAUTHORIZED"
      ) {
        throw new HttpError(401, err.message);
      }
      if (
        err instanceof Error &&
        "code" in err &&
        (err as { code: string }).code === "FORBIDDEN"
      ) {
        throw new HttpError(403, err.message);
      }
      throw err;
    }
  }
}

export async function authorizeRequest(
  request: Request,
  env: SecurityEnv,
  permission: Permission,
  spaceId?: string,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  const context = await securityContext(request, env, accessContext);
  if (
    permission === "profiles:admin" ||
    permission === "profiles:release:manage"
  ) {
    if (!(await hasProfileLabPermission(env, context, permission))) {
      throw new HttpError(
        403,
        "Profile administrator authorization is required",
      );
    }
  }
  if (spaceId && !testAuthenticationEnabled(env)) {
    try {
      await authorizeSpaceMembership(
        env.SYNTILA_DB,
        context,
        spaceId,
        permission,
      );
    } catch (error) {
      if (!(error instanceof AuthorizationError)) throw error;
      throw new HttpError(404, "Resource not found");
    }
  }
  try {
    if (
      !testAuthenticationEnabled(env) &&
      (spaceId ||
        permission === "spaces:read" ||
        permission === "spaces:manage")
    ) {
      authorize(context, permission, spaceId);
    }
  } catch (error) {
    await recordAuthAuditEvent(env.SYNTILA_DB, {
      action: "auth.authorization.denied",
      outcome: "denied",
      userId: context.userId,
      sessionId: context.sessionId,
      workspaceId: null,
      reason: "not_authorized",
      operation: permission,
    });
    throw new HttpError(
      403,
      error instanceof Error ? error.message : "Forbidden",
    );
  }
  return context;
}

export async function requireWorkspaceContext(
  context: SecurityContext,
  env: SecurityEnv,
  workspaceId: string,
): Promise<void> {
  try {
    await authorizeWorkspaceOwner(env.SYNTILA_DB, context, workspaceId);
  } catch {
    if (!testAuthenticationEnabled(env))
      throw new HttpError(404, "Resource not found");
  }
}

export async function requireRecentStepUp(
  env: SecurityEnv,
  context: SecurityContext,
  operation: SensitiveOperation,
): Promise<void> {
  const satisfied = await hasRecentStepUp(
    env.SYNTILA_DB,
    context.userId,
    context.sessionId,
    operation,
  );
  if (!satisfied) {
    throw new HttpError(428, "Fresh strong authentication required");
  }
}

export const MAX_ARTIFACT_UPLOAD_BYTES = 64 * 1024 * 1024;

export function artifactName(value: string | null): string {
  const normalized = (value ?? "artifact").replace(/[^a-zA-Z0-9._-]/g, "_");
  return normalized.slice(0, 160) || "artifact";
}

export function artifactMetadata(
  row: Record<string, unknown>,
): Record<string, unknown> {
  const provenance = parseJson<Record<string, unknown>>(
    row.provenance_json,
    {},
  );
  return {
    id: String(row.id),
    workspaceId: String(row.workspace_id),
    spaceId: String(row.space_id),
    runId: String(row.run_id),
    ...(row.task_id ? { taskId: String(row.task_id) } : {}),
    ...(row.attempt_id ? { attemptId: String(row.attempt_id) } : {}),
    mediaType: String(row.media_type),
    contentDigest: String(row.content_digest),
    sizeBytes: Number(row.size_bytes),
    name: artifactName(
      typeof provenance.name === "string" ? provenance.name : null,
    ),
    storage: "artifact-service",
    downloadUrl: `/api/artifacts/${encodeURIComponent(String(row.id))}?workspaceId=${encodeURIComponent(String(row.workspace_id))}`,
    createdAt: String(row.created_at),
  };
}

export async function workspaceOwnerContext(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  permission: Permission,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  const context = await securityContext(request, env, accessContext);
  try {
    await authorizeWorkspaceOwner(
      env.SYNTILA_DB,
      context,
      workspaceId,
      permission,
    );
  } catch {
    if (testAuthenticationEnabled(env)) return context;
    throw new HttpError(404, "Workspace not found");
  }
  return context;
}

export function securityEnv(env: Env): SecurityEnv {
  return env as SecurityEnv;
}

export async function authorizeSpaceOwnerOrThrow(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:read",
    spaceId,
    accessContext,
  );
  try {
    await authorizeSpaceOwner(env.SYNTILA_DB, context, spaceId);
  } catch {
    throw new HttpError(403, "Only the Space owner can manage collaboration");
  }
  return context;
}

// =========================================================================
// Thread Discuss / Work API
// =========================================================================
