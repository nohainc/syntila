/**
 * Server-to-server endpoints for the Cloudflare auth Worker, which owns the
 * Better Auth accounts. Authenticated with an EdDSA token (`typ: "internal"`)
 * signed by the same key as user tokens, so no extra shared secret exists.
 *
 *   POST /internal/accounts/:userId/deletion   before the Worker deletes an account
 *   POST /internal/accounts/:userId/profile    after a profile change {email,name,image,emailVerified}
 */
import { AuthError, bearer, type TokenVerifier } from "./auth";
import { prepareAccountDeletion, handleAccountProfileUpdated } from "./domain/auth/account-lifecycle";

type Env = { SYNTILA_DB: D1Database; SYNTILA_ARTIFACTS?: R2Bucket };
const ROUTE = /^\/internal\/accounts\/([A-Za-z0-9_-]{1,128})\/(deletion|profile)$/;
const json = (body: unknown, status = 200) => Response.json(body, { status });

export function isInternalPath(pathname: string) {
  return pathname.startsWith("/internal/");
}

export async function handleInternal(request: Request, env: Env, verifier: TokenVerifier | null): Promise<Response> {
  const token = bearer(request);
  if (!token || !verifier) return json({ error: "Authentication required" }, 401);
  try {
    if ((await verifier.verify(token)).kind !== "internal") return json({ error: "Forbidden" }, 403);
  } catch (error) {
    if (error instanceof AuthError) return json({ error: "Authentication required" }, 401);
    throw error;
  }
  const match = new URL(request.url).pathname.match(ROUTE);
  if (!match || request.method !== "POST") return json({ error: "Not found" }, 404);
  const [, userId, action] = match as unknown as [string, string, "deletion" | "profile"];
  const body = (await request.json().catch(() => ({}))) as Record<string, unknown>;
  const now = new Date().toISOString();

  if (action === "deletion") {
    // Idempotent: the Worker retries until this succeeds, then deletes the account.
    const user = await env.SYNTILA_DB.prepare("SELECT status FROM users WHERE id = ?1").bind(userId).first<{ status: string }>();
    if (user) {
      await prepareAccountDeletion(env, userId);
      // Authored content stays (RESTRICT foreign keys), attributed to an
      // anonymized, deactivated user; the address is free for a new account.
      await env.SYNTILA_DB.prepare(
        `UPDATE users SET status = 'deactivated', email = ?2, display_name = 'Deleted user', avatar_url = NULL,
           email_verified = 0, updated_at = ?3 WHERE id = ?1`,
      ).bind(userId, `deleted+${userId}@syntila.invalid`, now).run();
    }
    return json({ ok: true, existed: Boolean(user) });
  }

  const email = typeof body.email === "string" && body.email.includes("@") ? body.email.trim().toLowerCase() : null;
  const name = typeof body.name === "string" && body.name.trim() ? body.name.trim().slice(0, 200) : null;
  const image = typeof body.image === "string" ? body.image.slice(0, 2048) : body.image === null ? null : undefined;
  const result = await env.SYNTILA_DB.prepare(
    `UPDATE users SET email = COALESCE(?2, email), display_name = COALESCE(?3, display_name),
       avatar_url = CASE WHEN ?4::int = 1 THEN ?5 ELSE avatar_url END,
       email_verified = CASE WHEN ?6::smallint IS NULL THEN email_verified ELSE ?6::smallint END,
       updated_at = ?7
     WHERE id = ?1 AND status <> 'deactivated'`,
  ).bind(userId, email, name, image !== undefined ? 1 : 0, image ?? null,
    typeof body.emailVerified === "boolean" ? (body.emailVerified ? 1 : 0) : null, now).run();
  // A user who never called the backend has no row yet: nothing to sync.
  if (Number(result.meta?.changes ?? 0) > 0) await handleAccountProfileUpdated(env, userId);
  return json({ ok: true, updated: Number(result.meta?.changes ?? 0) > 0 });
}
