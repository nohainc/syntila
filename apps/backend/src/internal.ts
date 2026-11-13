/**
 * Server-to-server endpoints for the Cloudflare auth Worker, which owns the
 * Better Auth accounts. Authenticated with an EdDSA token (`typ: "internal"`)
 * signed by the same key as user tokens, so no extra shared secret exists.
 *
 *   POST /internal/accounts/:userId/deletion   before the Worker deletes an account
 *   POST /internal/accounts/:userId/profile    after a profile change {email,name,image,emailVerified}
 *
 * Operator endpoints (the "Syntila Accounts" tool, same token type):
 *   POST /internal/admin/accounts/stats        {ids} → usage and plan per user
 *   POST /internal/admin/accounts/:id/plan     {action: grant_paid|revoke_paid, email}
 *   POST /internal/admin/accounts/:id/status   {status: active|suspended} mirrors an auth lock
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
  const pathname = new URL(request.url).pathname;
  if (request.method === "POST" && pathname.startsWith("/internal/admin/"))
    return handleAdmin(request, env, pathname);
  const match = pathname.match(ROUTE);
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

const PAID = `(ap.tier = 'paid' AND ap.status IN ('active','trialing','past_due')
  AND (ap.current_period_end IS NULL OR ap.current_period_end > now()))`;
const ADMIN_ACCOUNT = /^\/internal\/admin\/accounts\/([A-Za-z0-9_-]{1,128})\/(plan|status)$/;

async function handleAdmin(request: Request, env: Env, pathname: string): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as Record<string, unknown>;
  const now = new Date().toISOString();
  if (pathname === "/internal/admin/accounts/stats") {
    const ids = Array.isArray(body.ids) ? body.ids.filter((id): id is string => typeof id === "string").slice(0, 500) : [];
    if (!ids.length) return json({ stats: {} });
    const rows = await env.SYNTILA_DB.prepare(
      `SELECT u.id,
         (SELECT count(*) FROM space_memberships m WHERE m.user_id = u.id) AS spaces,
         (SELECT count(*) FROM execution_workspaces w WHERE w.owner_user_id = u.id AND w.status <> 'revoked') AS workspaces,
         (SELECT count(*) FROM work_requests r WHERE r.requested_by_user_id = u.id) AS requests,
         (SELECT count(*) FROM work_requests r WHERE r.requested_by_user_id = u.id AND r.status = 'failed') AS failed_requests,
         (SELECT max(r.created_at) FROM work_requests r WHERE r.requested_by_user_id = u.id) AS last_request_at,
         (SELECT count(*) FROM discussion_messages m WHERE m.author_user_id = u.id) AS messages,
         (SELECT max(m.created_at) FROM discussion_messages m WHERE m.author_user_id = u.id) AS last_message_at,
         CASE WHEN EXISTS (SELECT 1 FROM account_plans ap WHERE ap.user_id = u.id AND ${PAID}) THEN 'paid' ELSE 'free' END AS plan,
         (SELECT source FROM account_plans ap WHERE ap.user_id = u.id) AS plan_source,
         (SELECT current_period_end FROM account_plans ap WHERE ap.user_id = u.id) AS plan_period_end
       FROM users u WHERE u.id IN (${ids.map((_, i) => `?${i + 1}`).join(",")})`,
    ).bind(...ids).all<Record<string, unknown> & { id: string }>();
    return json({ stats: Object.fromEntries((rows.results ?? []).map(({ id, ...rest }) => [id, rest])) });
  }
  const match = pathname.match(ADMIN_ACCOUNT);
  if (!match) return json({ error: "Not found" }, 404);
  const [, userId, action] = match as unknown as [string, string, "plan" | "status"];

  if (action === "status") {
    const status = body.status === "suspended" ? "suspended" : body.status === "active" ? "active" : null;
    if (!status) return json({ error: "status must be active or suspended" }, 400);
    const result = await env.SYNTILA_DB.prepare(
      "UPDATE users SET status = ?2, updated_at = ?3 WHERE id = ?1 AND status IN ('active','suspended')",
    ).bind(userId, status, now).run();
    // No backend row yet: the account never used the product, nothing to mirror.
    return json({ ok: true, updated: Number(result.meta?.changes ?? 0) > 0 });
  }

  const grant = body.action === "grant_paid" ? true : body.action === "revoke_paid" ? false : null;
  const email = typeof body.email === "string" && body.email.includes("@") ? body.email.trim().toLowerCase() : null;
  if (grant === null || !email) return json({ error: "action (grant_paid|revoke_paid) and email are required" }, 400);
  // The plan can be granted before the account first used the product.
  await env.SYNTILA_DB.prepare(
    `INSERT INTO users (id, email, display_name, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, 'active', ?4, ?4) ON CONFLICT (id) DO NOTHING`,
  ).bind(userId, email, email.split("@")[0], now).run();
  const owner = await env.SYNTILA_DB.prepare("SELECT email FROM users WHERE id = ?1").bind(userId).first<{ email: string }>();
  if (owner?.email.toLowerCase() !== email) return json({ error: "Account email does not match" }, 409);
  await env.SYNTILA_DB.prepare(
    `INSERT INTO account_plans (user_id, tier, status, source, current_period_end, created_at, updated_at)
       VALUES (?1, ?2, ?3, 'manual', NULL, ?4, ?4)
     ON CONFLICT (user_id) DO UPDATE SET tier = excluded.tier, status = excluded.status, source = 'manual',
       current_period_end = NULL, updated_at = excluded.updated_at`,
  ).bind(userId, grant ? "paid" : "free", grant ? "active" : "canceled", now).run();
  const plan = await env.SYNTILA_DB.prepare(
    `SELECT CASE WHEN EXISTS (SELECT 1 FROM account_plans ap WHERE ap.user_id = ?1 AND ${PAID}) THEN 'paid' ELSE 'free' END AS plan`,
  ).bind(userId).first<{ plan: string }>();
  return json({ ok: true, plan: plan?.plan ?? "free" });
}
