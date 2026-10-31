import { isProfileLabOwner } from "./profile-lab-policy.js";
import {
  handleBetterAuthRequest,
  identityService,
  provisionSyntilaUser,
  recordAuthAuditEvent,
} from "../auth/index.js";
import {
  DESKTOP_PROFILE_LAB_AUDIENCE,
  DESKTOP_WORKSPACE_AUDIENCE,
  SUPPORTED_DESKTOP_AUDIENCES,
  type DesktopAudience,
  extractBearerToken,
  hashToken,
} from "@syntila/security";
import { HttpError, json, recordAudit, securityContext } from "./handlers.js";
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

/** Completes a session-bound step-up proof after a strong authentication ceremony. */
export async function handleCompleteStepUp(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  return completeStepUpForContext(context, env);
}

/** Binds a browser-completed passkey proof to the dedicated Profile Lab session. */
export async function handleCompleteProfileLabStepUp(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (
    context.clientType !== "desktop" ||
    context.audience !== DESKTOP_PROFILE_LAB_AUDIENCE
  ) {
    throw new HttpError(403, "Profile Lab desktop session is required");
  }
  return completeStepUpForContext(context, env);
}

async function completeStepUpForContext(
  context: Awaited<ReturnType<typeof securityContext>>,
  env: SecurityEnv,
): Promise<Response> {
  const event = await env.SYNTILA_DB.prepare(
    `SELECT id, method, created_at FROM auth_step_up_events
     WHERE user_id = ?1 AND consumed_at IS NULL
     ORDER BY created_at DESC LIMIT 1`,
  )
    .bind(context.userId)
    .first<{ id: string; method: "passkey" | "totp"; created_at: string }>();
  if (!event) {
    return json(
      { error: "No recent strong authentication ceremony is available" },
      { status: 428 },
    );
  }

  const now = new Date();
  const ceremonyAt = Date.parse(event.created_at);
  if (
    !Number.isFinite(ceremonyAt) ||
    ceremonyAt > now.getTime() ||
    now.getTime() - ceremonyAt > 5 * 60 * 1000
  ) {
    await env.SYNTILA_DB.prepare(
      "UPDATE auth_step_up_events SET consumed_at = ?1 WHERE id = ?2 AND consumed_at IS NULL",
    )
      .bind(now.toISOString(), event.id)
      .run();
    return json(
      { error: "Strong authentication ceremony is stale; verify again" },
      { status: 428 },
    );
  }
  const authenticatedAt = now.toISOString();
  const expiresAt = new Date(now.getTime() + 10 * 60 * 1000).toISOString();
  await env.SYNTILA_DB.batch([
    env.SYNTILA_DB.prepare(
      `INSERT INTO auth_step_up_sessions
           (id, user_id, session_id, method, authenticated_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(session_id) DO UPDATE SET
           method = excluded.method,
           authenticated_at = excluded.authenticated_at,
           expires_at = excluded.expires_at`,
    ).bind(
      crypto.randomUUID(),
      context.userId,
      context.sessionId,
      event.method,
      authenticatedAt,
      expiresAt,
    ),
    env.SYNTILA_DB.prepare(
      "UPDATE auth_step_up_events SET consumed_at = ?1 WHERE id = ?2 AND consumed_at IS NULL",
    ).bind(authenticatedAt, event.id),
  ]);
  await recordAuthAuditEvent(env.SYNTILA_DB, {
    action: "auth.step_up.completed",
    outcome: "success",
    userId: context.userId,
    sessionId: context.sessionId,
    provider: event.method,
    operation: "step_up",
  });
  return json({ ok: true, method: event.method, expiresAt });
}

export async function handleSessionLogout(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const headers = new Headers(request.headers);
  headers.delete("content-length");
  headers.set("content-type", "application/json");
  const authRequest = new Request(new URL("/api/auth/sign-out", request.url), {
    method: "POST",
    headers,
    body: JSON.stringify({ disableRedirect: true }),
  });
  const response = await handleBetterAuthRequest(authRequest, env);
  if (response.ok && env.SYNTILA_DB) {
    await recordAudit(env, context, "logout", "session", context.sessionId);
  }
  return response;
}

export {
  DESKTOP_PROFILE_LAB_AUDIENCE,
  DESKTOP_WORKSPACE_AUDIENCE,
  SUPPORTED_DESKTOP_AUDIENCES,
  type DesktopAudience,
};
const DESKTOP_HUMAN_SESSION_MS = 30 * 24 * 60 * 60 * 1000;

function desktopAuthAppOrigin(request: Request, env: SecurityEnv): string {
  const configured = env.SYNTILA_APP_URL?.trim() || env.BETTER_AUTH_URL?.trim();
  if (!configured) return new URL(request.url).origin;

  let parsed: URL;
  try {
    parsed = new URL(configured);
  } catch {
    throw new HttpError(500, "Desktop sign-in application URL is invalid");
  }
  if (
    parsed.protocol !== "https:" &&
    parsed.hostname !== "localhost" &&
    parsed.hostname !== "127.0.0.1"
  ) {
    throw new HttpError(500, "Desktop sign-in application URL must use HTTPS");
  }
  return parsed.origin;
}

export function randomSecret(prefix: string): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return `${prefix}${btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "")}`;
}

/** Headless email/password uses the same Better Auth verifier and restrictions
 * as AX. Its temporary cookie never crosses the desktop credential boundary.
 */
export async function handleDesktopPasswordSignIn(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const body = (await request.json().catch(() => null)) as Record<
    string,
    unknown
  > | null;
  if (
    !body ||
    Object.keys(body).some(
      (key) => !["email", "password", "deviceId"].includes(key),
    ) ||
    (body.deviceId !== undefined && !isDeviceId(body.deviceId)) ||
    typeof body.email !== "string" ||
    !body.email.trim() ||
    body.email.length > 320 ||
    typeof body.password !== "string" ||
    !body.password ||
    body.password.length > 128
  ) {
    throw new HttpError(400, "Email and password are required");
  }
  const headers = new Headers({
    "Content-Type": "application/json",
    Origin: new URL(request.url).origin,
  });
  for (const name of ["cf-connecting-ip", "user-agent"]) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  const signedIn = await handleBetterAuthRequest(
    new Request(new URL("/api/auth/sign-in/email", request.url), {
      method: "POST",
      headers,
      body: JSON.stringify({
        email: body.email.trim(),
        password: body.password,
        rememberMe: false,
      }),
    }),
    env,
  );
  if (!signedIn.ok) {
    throw new HttpError(
      signedIn.status === 429 ? 429 : signedIn.status >= 500 ? 503 : 401,
      signedIn.status === 429
        ? "Too many sign-in attempts; try later"
        : signedIn.status >= 500
          ? "Cloud authentication is unavailable; try again later"
          : "Email/password sign-in failed. Check your credentials and account status.",
    );
  }
  const result = (await signedIn.json()) as { twoFactorRedirect?: boolean };
  if (result.twoFactorRedirect) {
    throw new HttpError(
      403,
      "This account requires additional verification. Use browser sign-in; headless password login cannot bypass it.",
    );
  }
  const cookies = signedIn.headers
    .getSetCookie()
    .map((value) => value.split(";")[0])
    .join("; ");
  if (!cookies) throw new HttpError(401, "Account verification is required");
  const authenticatedHeaders = new Headers(headers);
  authenticatedHeaders.set("Cookie", cookies);
  try {
    const identity = await identityService.resolve(
      new Request(request.url, { headers: authenticatedHeaders }),
      env,
    );
    if (!identity) throw new HttpError(401, "Account verification is required");
    const created = await handleCreateDesktopAuthIntent(
      new Request(new URL("/api/desktop-auth/intents", request.url), {
        method: "POST",
        headers,
        body: JSON.stringify({
          clientName: "Syntila Headless Workspace",
          contractVersion: "1.1",
        }),
      }),
      env,
    );
    const intent = (await created.json()) as {
      intentId: string;
      pollToken: string;
    };
    await handleApproveDesktopAuthIntent(
      new Request(request.url, {
        method: "POST",
        headers: authenticatedHeaders,
        body: "{}",
      }),
      env,
      intent.intentId,
    );
    const claimed = await handleClaimDesktopAuthIntent(
      new Request(request.url, {
        method: "POST",
        headers,
        body: JSON.stringify({
          pollToken: intent.pollToken,
          deviceId: body.deviceId,
        }),
      }),
      env,
      intent.intentId,
    );
    claimed.headers.set("Cache-Control", "no-store");
    return claimed;
  } finally {
    // This cookie is only an internal bridge to an independent desktop session.
    await handleBetterAuthRequest(
      new Request(new URL("/api/auth/sign-out", request.url), {
        method: "POST",
        headers: authenticatedHeaders,
        body: "{}",
      }),
      env,
    ).catch(() => undefined);
  }
}

export async function handleCreateDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as {
    clientName?: unknown;
    contractVersion?: unknown;
    audience?: unknown;
  };
  if (
    !body ||
    typeof body !== "object" ||
    Array.isArray(body) ||
    Object.keys(body).some(
      (key) => !["clientName", "contractVersion", "audience"].includes(key),
    ) ||
    body.contractVersion !== "1.1" ||
    typeof body.clientName !== "string" ||
    !body.clientName.trim()
  ) {
    throw new HttpError(
      400,
      "A supported contract version and client name are required",
    );
  }
  const audience =
    typeof body.audience === "string"
      ? (body.audience.trim() as DesktopAudience)
      : DESKTOP_WORKSPACE_AUDIENCE;
  if (!SUPPORTED_DESKTOP_AUDIENCES.includes(audience)) {
    throw new HttpError(
      400,
      `Unsupported desktop authentication audience: ${audience}`,
    );
  }
  const intentId = crypto.randomUUID();
  const pollToken = randomSecret("syntila_dap_");
  const createdAt = new Date();
  const expiresAt = new Date(createdAt.getTime() + 10 * 60_000);
  await env.SYNTILA_DB.prepare(
    `INSERT INTO desktop_auth_intents
       (id, poll_token_hash, client_name, audience, created_at, expires_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  )
    .bind(
      intentId,
      await hashToken(pollToken),
      body.clientName.trim().slice(0, 128),
      audience,
      createdAt.toISOString(),
      expiresAt.toISOString(),
    )
    .run();

  const verificationUrl = new URL(
    "/desktop-auth/approve",
    desktopAuthAppOrigin(request, env),
  );
  verificationUrl.searchParams.set("intentId", intentId);
  return json(
    {
      intentId,
      pollToken,
      verificationUrl: verificationUrl.toString(),
      expiresAt: expiresAt.toISOString(),
      pollIntervalMs: 2000,
      audience,
    },
    { status: 201 },
  );
}

export async function handleDesktopAuthIntentStatus(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const pollToken = extractBearerToken(request.headers);
  if (!pollToken)
    throw new HttpError(401, "Desktop auth polling credential required");
  const intent = await env.SYNTILA_DB.prepare(
    `SELECT expires_at AS expiresAt, approved_at AS approvedAt,
            claimed_at AS claimedAt, denied_at AS deniedAt
       FROM desktop_auth_intents WHERE id = ?1 AND poll_token_hash = ?2`,
  )
    .bind(intentId, await hashToken(pollToken))
    .first<{
      expiresAt: string;
      approvedAt: string | null;
      claimedAt: string | null;
      deniedAt: string | null;
    }>();
  if (!intent) throw new HttpError(404, "Desktop auth intent not found");
  const status = intent.claimedAt
    ? "claimed"
    : intent.deniedAt
      ? "denied"
      : intent.approvedAt
        ? "approved"
        : intent.expiresAt <= new Date().toISOString()
          ? "expired"
          : "pending";
  return json({ intentId, status, expiresAt: intent.expiresAt });
}

/** Public, non-secret state for tabs opened by the desktop system browser. */
export async function handleDesktopAuthIntentBrowserStatus(
  _request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const intent = await env.SYNTILA_DB.prepare(
    `SELECT expires_at AS expiresAt, approved_at AS approvedAt,
            claimed_at AS claimedAt, denied_at AS deniedAt,
            client_name AS clientName, audience
       FROM desktop_auth_intents WHERE id = ?1`,
  )
    .bind(intentId)
    .first<{
      expiresAt: string;
      approvedAt: string | null;
      claimedAt: string | null;
      deniedAt: string | null;
      clientName: string;
      audience: string;
    }>();
  if (!intent) throw new HttpError(404, "Desktop auth intent not found");
  const status = intent.claimedAt
    ? "claimed"
    : intent.deniedAt
      ? "denied"
      : intent.approvedAt
        ? "approved"
        : intent.expiresAt <= new Date().toISOString()
          ? "expired"
          : "pending";
  return json({
    intentId,
    status,
    expiresAt: intent.expiresAt,
    clientName: intent.clientName,
    audience: intent.audience,
  });
}

export async function handleCancelDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const pollToken = extractBearerToken(request.headers);
  if (!pollToken) {
    throw new HttpError(401, "Desktop auth polling credential required");
  }
  const now = new Date().toISOString();
  const result = await env.SYNTILA_DB.prepare(
    `UPDATE desktop_auth_intents SET denied_at = ?1
      WHERE id = ?2 AND poll_token_hash = ?3 AND approved_at IS NULL
        AND claimed_at IS NULL AND denied_at IS NULL AND expires_at > ?1`,
  )
    .bind(now, intentId, await hashToken(pollToken))
    .run();
  if ((result.meta?.changes ?? 0) !== 1) {
    throw new HttpError(409, "Desktop sign-in is no longer pending");
  }
  return json({ intentId, cancelled: true });
}

export async function handleDenyDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const identity = await identityService.resolve(request, env);
  if (!identity)
    throw new HttpError(401, "Sign in before canceling this request");
  const now = new Date().toISOString();
  const result = await env.SYNTILA_DB.prepare(
    `UPDATE desktop_auth_intents SET denied_at = ?1
      WHERE id = ?2 AND approved_at IS NULL AND claimed_at IS NULL
        AND denied_at IS NULL AND expires_at > ?1`,
  )
    .bind(now, intentId)
    .run();
  if ((result.meta?.changes ?? 0) !== 1) {
    throw new HttpError(409, "Desktop sign-in is no longer pending");
  }
  return json({ intentId, cancelled: true });
}

export async function handleApproveDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const identity = await identityService.resolve(request, env);
  if (!identity)
    throw new HttpError(
      401,
      "Sign in to Syntila before approving desktop sign-in",
    );
  await provisionSyntilaUser(env.SYNTILA_DB, identity);
  const body: unknown = await request.json().catch(() => ({}));
  if (
    !body ||
    typeof body !== "object" ||
    Array.isArray(body) ||
    Object.keys(body).length !== 0
  ) {
    throw new HttpError(400, "Desktop approval does not accept request fields");
  }
  const intent = await env.SYNTILA_DB.prepare(
    "SELECT audience FROM desktop_auth_intents WHERE id = ?1",
  )
    .bind(intentId)
    .first<{ audience: string }>();
  if (
    intent?.audience === DESKTOP_PROFILE_LAB_AUDIENCE &&
    env.SYNTILA_PROFILE_LAB_OWNER_EMAIL !== undefined &&
    !(await isProfileLabOwner(env, identity.userId))
  ) {
    throw new HttpError(
      403,
      "Profile Lab is restricted to its verified owner account",
    );
  }
  const now = new Date().toISOString();
  const result = await env.SYNTILA_DB.prepare(
    `UPDATE desktop_auth_intents
        SET approved_at = ?1, approved_user_id = ?2
      WHERE id = ?3 AND approved_at IS NULL
        AND claimed_at IS NULL AND denied_at IS NULL AND expires_at > ?1`,
  )
    .bind(now, identity.userId, intentId)
    .run();
  if ((result.meta?.changes ?? 0) !== 1) {
    throw new HttpError(
      409,
      "This sign-in request is invalid, expired, or already used",
    );
  }
  return json({
    approved: true,
    approvedAt: now,
    user: {
      userId: identity.userId,
      displayName: identity.name,
      email: identity.email,
    },
  });
}

function isDeviceId(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{8,128}$/.test(value);
}

export async function handleClaimDesktopAuthIntent(
  request: Request,
  env: SecurityEnv,
  intentId: string,
): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as {
    pollToken?: unknown;
    deviceId?: unknown;
  };
  const pollToken = typeof body.pollToken === "string" ? body.pollToken : "";
  if (!pollToken)
    throw new HttpError(401, "Desktop auth polling credential required");
  if (body.deviceId !== undefined && !isDeviceId(body.deviceId))
    throw new HttpError(400, "Desktop device identifier is invalid");
  const deviceId = body.deviceId ?? null;
  const intent = await env.SYNTILA_DB.prepare(
    `SELECT approved_user_id AS userId, expires_at AS expiresAt, audience
       FROM desktop_auth_intents
      WHERE id = ?1 AND poll_token_hash = ?2 AND approved_at IS NOT NULL
        AND claimed_at IS NULL AND denied_at IS NULL AND expires_at > ?3`,
  )
    .bind(intentId, await hashToken(pollToken), new Date().toISOString())
    .first<{ userId: string; expiresAt: string; audience: string }>();
  if (!intent)
    throw new HttpError(
      409,
      "Desktop sign-in is not approved, expired, or already claimed",
    );
  const user = await env.SYNTILA_DB.prepare(
    "SELECT id AS userId, email, display_name AS displayName FROM users WHERE id = ?1 AND status = 'active'",
  )
    .bind(intent.userId)
    .first<{ userId: string; email: string; displayName: string }>();
  if (!user) throw new HttpError(403, "Syntila account is unavailable");

  if (
    intent.audience === DESKTOP_PROFILE_LAB_AUDIENCE &&
    env.SYNTILA_PROFILE_LAB_OWNER_EMAIL !== undefined &&
    !(await isProfileLabOwner(env, user.userId))
  ) {
    throw new HttpError(
      403,
      "Profile Lab is restricted to its verified owner account",
    );
  }
  const sessionId = crypto.randomUUID();
  const credential = randomSecret("syntila_dhs_");
  const tokenHash = await hashToken(credential);
  const issuedAt = new Date();
  const expiresAt = new Date(issuedAt.getTime() + DESKTOP_HUMAN_SESSION_MS);
  const results = await env.SYNTILA_DB.batch([
    env.SYNTILA_DB.prepare(
      `UPDATE desktop_auth_intents SET claimed_at = ?1, claimed_session_id = ?2
        WHERE id = ?3 AND poll_token_hash = ?4 AND approved_at IS NOT NULL
          AND claimed_at IS NULL AND denied_at IS NULL AND expires_at > ?1`,
    ).bind(
      issuedAt.toISOString(),
      sessionId,
      intentId,
      await hashToken(pollToken),
    ),
    env.SYNTILA_DB.prepare(
      `INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at, device_id)
       SELECT ?1, ?2, ?3, ?4, ?5, ?5, ?6, ?8 FROM desktop_auth_intents
        WHERE id = ?7 AND claimed_session_id = ?1`,
    ).bind(
      sessionId,
      user.userId,
      tokenHash,
      intent.audience,
      issuedAt.toISOString(),
      expiresAt.toISOString(),
      intentId,
      deviceId,
    ),
    // A new sign-in on the same install supersedes that install's earlier
    // sessions for the same account and audience.
    env.SYNTILA_DB.prepare(
      `UPDATE desktop_human_sessions SET revoked_at = ?1
        WHERE user_id = ?2 AND audience = ?3 AND device_id = ?4 AND id <> ?5
          AND revoked_at IS NULL
          AND EXISTS (SELECT 1 FROM desktop_auth_intents
                       WHERE id = ?6 AND claimed_session_id = ?5)`,
    ).bind(
      issuedAt.toISOString(),
      user.userId,
      intent.audience,
      deviceId,
      sessionId,
      intentId,
    ),
  ]);
  const changes =
    (results[0] as { meta?: { changes?: number } } | undefined)?.meta
      ?.changes ?? 0;
  if (changes !== 1)
    throw new HttpError(409, "Desktop sign-in is already claimed or expired");
  return json({
    credential,
    user: {
      userId: user.userId,
      displayName: user.displayName,
      email: user.email,
    },
    issuedAt: issuedAt.toISOString(),
    expiresAt: expiresAt.toISOString(),
    sessionId,
    audience: intent.audience,
  });
}

export async function handleRevokeDesktopHumanSession(
  request: Request,
  env: SecurityEnv,
  sessionId: string,
): Promise<Response> {
  const credential = extractBearerToken(request.headers);
  if (!credential) throw new HttpError(401, "Desktop human session required");
  const now = new Date().toISOString();
  const result = await env.SYNTILA_DB.prepare(
    `UPDATE desktop_human_sessions SET revoked_at = ?1
      WHERE id = ?2 AND token_hash = ?3 AND revoked_at IS NULL AND expires_at > ?1`,
  )
    .bind(now, sessionId, await hashToken(credential))
    .run();
  if ((result.meta?.changes ?? 0) !== 1)
    throw new HttpError(401, "Desktop human session is invalid or revoked");
  return json({ revoked: true, revokedAt: now });
}

export async function findDesktopHumanSession(
  request: Request,
  env: SecurityEnv,
  sessionId?: string,
  expectedAudience?: string | readonly string[],
) {
  const credential = extractBearerToken(request.headers);
  if (!credential) throw new HttpError(401, "Desktop human session required");
  const now = new Date().toISOString();
  const session = await env.SYNTILA_DB.prepare(
    `SELECT s.id AS sessionId, s.user_id AS userId, s.audience, s.created_at AS createdAt,
            s.expires_at AS expiresAt,
            u.email, u.display_name AS displayName
       FROM desktop_human_sessions s JOIN users u ON u.id = s.user_id
      WHERE s.token_hash = ?1 AND s.revoked_at IS NULL
        AND s.expires_at > ?2 AND u.status = 'active'
        AND (?3 IS NULL OR s.id = ?3)`,
  )
    .bind(await hashToken(credential), now, sessionId ?? null)
    .first<{
      sessionId: string;
      userId: string;
      audience: string;
      createdAt: string;
      expiresAt: string;
      email: string;
      displayName: string;
    }>();
  if (!session)
    throw new HttpError(
      401,
      "Desktop human session is invalid, expired, or revoked",
    );

  if (
    session.audience === DESKTOP_PROFILE_LAB_AUDIENCE &&
    env.SYNTILA_PROFILE_LAB_OWNER_EMAIL !== undefined &&
    !(await isProfileLabOwner(env, session.userId))
  ) {
    throw new HttpError(
      403,
      "Profile Lab is restricted to its verified owner account",
    );
  }

  if (expectedAudience) {
    const allowed = Array.isArray(expectedAudience)
      ? expectedAudience
      : [expectedAudience];
    if (!allowed.includes(session.audience)) {
      throw new HttpError(
        403,
        `Desktop session audience '${session.audience}' is not authorized for this operation`,
      );
    }
  }

  await env.SYNTILA_DB.prepare(
    "UPDATE desktop_human_sessions SET last_used_at = ?1 WHERE id = ?2",
  )
    .bind(now, session.sessionId)
    .run();
  return { credential, session, now };
}

export async function handleGetDesktopHumanSession(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const { session } = await findDesktopHumanSession(request, env);
  return json({
    sessionId: session.sessionId,
    user: {
      userId: session.userId,
      displayName: session.displayName,
      email: session.email,
    },
    audience: session.audience,
    expiresAt: session.expiresAt,
  });
}

export async function handleRotateDesktopHumanSession(
  request: Request,
  env: SecurityEnv,
  sessionId: string,
): Promise<Response> {
  const {
    credential: currentCredential,
    session,
    now,
  } = await findDesktopHumanSession(request, env, sessionId);
  const nextCredential = randomSecret("syntila_dhs_");
  const expiresAt = new Date(
    Date.now() + DESKTOP_HUMAN_SESSION_MS,
  ).toISOString();
  const result = await env.SYNTILA_DB.prepare(
    `UPDATE desktop_human_sessions SET token_hash = ?1,
        last_used_at = ?2, expires_at = ?3
       WHERE id = ?4 AND token_hash = ?5 AND revoked_at IS NULL`,
  )
    .bind(
      await hashToken(nextCredential),
      now,
      expiresAt,
      session.sessionId,
      await hashToken(currentCredential),
    )
    .run();
  if ((result.meta?.changes ?? 0) !== 1) {
    throw new HttpError(401, "Desktop human session changed or was revoked");
  }
  return json({
    credential: nextCredential,
    user: {
      userId: session.userId,
      displayName: session.displayName,
      email: session.email,
    },
    issuedAt: now,
    expiresAt,
    sessionId: session.sessionId,
    audience: session.audience,
  });
}
