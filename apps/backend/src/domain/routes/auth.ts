/**
 * Session endpoints left on the backend. Sign-in, desktop sign-in handoff,
 * logout and step-up live in the Cloudflare auth Worker; the backend only
 * answers who the bearer of a backend token is.
 */
import { isProfileLabOwner } from "./profile-lab-policy.js";
import { identityService, provisionSyntilaUser } from "../auth/index.js";
import { DESKTOP_PROFILE_LAB_AUDIENCE, extractBearerToken } from "@syntila/security";
import { HttpError, json, securityContext } from "./handlers.js";
import { avatarUrlFor } from "./profile.js";
import type { SecurityEnv } from "./handlers.js";

export async function handleSession(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const avatarUrl = avatarUrlFor(
    request,
    context.user.id,
    context.user.avatarUrl,
  );
  return json({
    authenticated: true,
    user: { ...context.user, avatarUrl },
    sessionId: context.sessionId,
    clientType: context.clientType,
  });
}

/**
 * Desktop callers (Workspace Service, Profile Lab) sign in at the Cloudflare
 * auth Worker and present a backend token with `client: "desktop"` and the
 * desktop audience. The session itself lives in the auth Worker.
 */
export async function findDesktopHumanSession(
  request: Request,
  env: SecurityEnv,
  sessionId?: string,
  expectedAudience?: string | readonly string[],
) {
  const credential = extractBearerToken(request.headers);
  if (!credential) throw new HttpError(401, "Desktop human session required");
  const now = new Date().toISOString();
  const identity = await identityService.resolve(request, env);
  if (!identity || identity.clientType !== "desktop" || !identity.audience)
    throw new HttpError(401, "Desktop human session is invalid, expired, or revoked");
  if (sessionId !== undefined && identity.sessionId !== sessionId)
    throw new HttpError(401, "Desktop human session is invalid, expired, or revoked");
  await provisionSyntilaUser(env.SYNTILA_DB, identity);
  const user = await env.SYNTILA_DB.prepare("SELECT status, display_name AS displayName FROM users WHERE id = ?1")
    .bind(identity.userId)
    .first<{ status: string; displayName: string }>();
  if (user?.status !== "active")
    throw new HttpError(401, "Desktop human session is invalid, expired, or revoked");
  const session = {
    sessionId: identity.sessionId,
    userId: identity.userId,
    audience: identity.audience,
    createdAt: now,
    expiresAt: null as string | null,
    email: identity.email,
    displayName: user.displayName,
  };
  if (
    session.audience === DESKTOP_PROFILE_LAB_AUDIENCE &&
    env.SYNTILA_PROFILE_LAB_OWNER_EMAIL !== undefined &&
    !(await isProfileLabOwner(env, session.userId))
  ) {
    throw new HttpError(403, "Profile Lab is restricted to its verified owner account");
  }
  if (expectedAudience) {
    const allowed = Array.isArray(expectedAudience) ? expectedAudience : [expectedAudience];
    if (!allowed.includes(session.audience)) {
      throw new HttpError(
        403,
        `Desktop session audience '${session.audience}' is not authorized for this operation`,
      );
    }
  }
  return { credential, session, now };
}
