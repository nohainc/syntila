/**
 * Request security for the auth Worker. The Worker resolves who is signed in
 * (Better Auth cookie/bearer session or a desktop human session) from its D1
 * users table; Space and Workspace authorization lives in the VPS backend.
 */
import { isProfileLabOwner } from "./profile-lab-policy.js";
import { isTrustedOrigin } from "../observability.js";
import { identityService, provisionSyntilaUser } from "../auth/index.js";
import { hashToken, type SecurityContext } from "@syntila/security";

export function parseJson<T = Record<string, unknown>>(value: unknown, defaultValue: T = {} as T): T {
  if (typeof value !== "string" || value.trim().length === 0) return defaultValue;
  try {
    return JSON.parse(value) as T;
  } catch {
    return defaultValue;
  }
}

export function json(data: unknown, init?: ResponseInit): Response {
  return Response.json(data, {
    ...init,
    headers: { "content-type": "application/json; charset=utf-8", ...init?.headers },
  });
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Request failed";
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
  readonly SYNTILA_PROFILE_ADMIN_USER_IDS?: string;
  readonly SYNTILA_PROFILE_LAB_OWNER_EMAIL?: string;
  readonly SYNTILA_PROFILE_RELEASE_MANAGER_USER_IDS?: string;
  readonly BETTER_AUTH_SECRET?: string;
  readonly BETTER_AUTH_URL?: string;
  readonly SYNTILA_AUTH_GITHUB_CLIENT_ID?: string;
  readonly SYNTILA_AUTH_GITHUB_CLIENT_SECRET?: string;
  readonly SYNTILA_AUTH_GOOGLE_CLIENT_ID?: string;
  readonly SYNTILA_AUTH_GOOGLE_CLIENT_SECRET?: string;
  readonly TEST_AUTHENTICATION?: (request: Request, env: Env) => Promise<SecurityContext>;
  readonly SYNTILA_APP_URL?: string;
  readonly SYNTILA_EMAIL_FROM?: string;
  readonly SYNTILA_EMAIL_FALLBACK_FROM?: string;
  readonly SYNTILA_EMAIL_FROM_NAME?: string;
  readonly SYNTILA_BACKEND_SIGNING_KEY?: string;
  readonly SYNTILA_BACKEND_URL?: string;
  readonly EMAIL_RELAY_SECRET?: string;
};

export function testAuthenticationEnabled(env: Env): boolean {
  return env.SYNTILA_ENVIRONMENT === "development" && typeof (env as SecurityEnv).TEST_AUTHENTICATION === "function";
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
      const refUrl = new URL(referer);
      if (refUrl.origin === requestOrigin) return;
      if (refUrl.hostname === "localhost" || refUrl.hostname === "127.0.0.1" || refUrl.hostname === "[::1]") return;
    } catch {
      // Treat malformed referers as untrusted.
    }
  }
  throw new HttpError(403, "Same-origin request required for cookie session");
}

/** The signed-in user's context (no Space roles: those are the backend's concern). */
async function userContext(
  env: SecurityEnv,
  identity: { userId: string; sessionId: string },
  clientType: "web" | "desktop" = "web",
  audience?: string,
): Promise<SecurityContext> {
  const row = await env.SYNTILA_DB.prepare(
    "SELECT id, email, display_name, avatar_url, status FROM users WHERE id = ?1",
  )
    .bind(identity.userId)
    .first<{ id: string; email: string; display_name: string; avatar_url: string | null; status: string }>();
  if (!row) throw new HttpError(401, "Syntila user not found");
  if (row.status !== "active") throw new HttpError(403, `User account is ${row.status}`);
  return {
    userId: row.id,
    user: { id: row.id, email: row.email, displayName: row.display_name, avatarUrl: row.avatar_url, status: "active" },
    spaceRoles: {},
    sessionId: identity.sessionId,
    clientType,
    ...(audience ? { audience } : {}),
  };
}

export async function securityContext(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  void accessContext;
  if (testAuthenticationEnabled(env)) return env.TEST_AUTHENTICATION!(request, env);

  const token = bearer(request);
  if (token && token.startsWith("syntila_dhs_")) {
    const now = new Date().toISOString();
    const session = await env.SYNTILA_DB.prepare(
      `SELECT s.id AS sessionId, s.user_id AS userId, s.audience
         FROM desktop_human_sessions s JOIN users u ON u.id = s.user_id
        WHERE s.token_hash = ?1 AND s.revoked_at IS NULL AND s.expires_at > ?2 AND u.status = 'active'`,
    )
      .bind(await hashToken(token), now)
      .first<{ sessionId: string; userId: string; audience: string }>();
    if (!session) throw new HttpError(401, "Desktop human session is invalid, expired, or revoked");
    if (
      session.audience === "syntila.profile-lab.management" &&
      env.SYNTILA_PROFILE_LAB_OWNER_EMAIL !== undefined &&
      !(await isProfileLabOwner(env, session.userId))
    )
      throw new HttpError(403, "Profile Lab is restricted to its verified owner account");
    await env.SYNTILA_DB.prepare("UPDATE desktop_human_sessions SET last_used_at = ?1 WHERE id = ?2")
      .bind(now, session.sessionId)
      .run();
    return userContext(env, session, "desktop", session.audience);
  }

  if (env.BETTER_AUTH_SECRET) {
    const identity = await identityService.resolve(request, env);
    if (!identity) throw new HttpError(401, "Authentication required");
    await provisionSyntilaUser(env.SYNTILA_DB, identity);
    return userContext(env, identity);
  }
  throw new HttpError(401, "Better Auth authentication required");
}
