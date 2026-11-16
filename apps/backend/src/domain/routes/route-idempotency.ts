/**
 * Idempotency for create endpoints marked `idempotent: "route"` in the route
 * table. A client that sends `Idempotency-Key` and retries (lost response,
 * flaky network, double tap) gets the first response back instead of a
 * second record.
 *
 *  1. The key is claimed with a pending receipt before the handler runs.
 *  2. The handler's successful (2xx) JSON response is stored on the receipt.
 *  3. A retry with the same key and body replays it (`Idempotency-Replayed:
 *     true`); a retry while the first is still running gets 409
 *     `idempotency_in_progress`; the same key with a different body gets 409
 *     `idempotency_key_reused`.
 *  4. If the handler does not succeed (exception or non-2xx), the claim is
 *     released so the request can be retried with the same key.
 *
 * Handlers that already write their receipt in the same transaction as their
 * own writes are marked `idempotent: "handler"` and are not wrapped.
 */
import { HttpError, readBodyText, securityContext, type SecurityEnv } from "./http-security.js";

const KEY = /^[A-Za-z0-9_-]{16,128}$/;
/** A claim older than this belongs to a request that died; it may be taken over. */
export const STALE_CLAIM_MS = 5 * 60_000;
const PENDING = 0;

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function withRouteIdempotency(
  request: Request,
  env: Env,
  ctx: ExecutionContext | undefined,
  run: (request: Request) => Promise<Response>,
): Promise<Response> {
  const key = request.headers.get("Idempotency-Key");
  if (key === null) return run(request);
  if (!KEY.test(key)) throw new HttpError(400, "Invalid Idempotency-Key");

  const security = env as unknown as SecurityEnv;
  const { userId } = await securityContext(request, security, ctx);
  const db = security.SYNTILA_DB;
  const pathname = new URL(request.url).pathname;
  const scope = `route:${request.method} ${pathname}`;
  const body = await readBodyText(request.clone());
  const hash = await sha256(body);

  const claim = () =>
    db
      .prepare(
        `INSERT INTO mutation_receipts (user_id, scope, idempotency_key, request_hash, response_json, response_status, created_at)
         VALUES (?1, ?2, ?3, ?4, '{}', ${PENDING}, ?5)
         ON CONFLICT DO NOTHING RETURNING 1 AS claimed`,
      )
      .bind(userId, scope, key, hash, new Date().toISOString())
      .first<{ claimed: number }>();

  let claimed = await claim();
  if (!claimed) {
    const existing = await db
      .prepare(
        `SELECT request_hash AS hash, response_json AS body, response_status AS status, created_at AS createdAt
           FROM mutation_receipts WHERE user_id = ?1 AND scope = ?2 AND idempotency_key = ?3`,
      )
      .bind(userId, scope, key)
      .first<{ hash: string; body: string; status: number; createdAt: string }>();
    if (existing && existing.hash !== hash)
      throw Object.assign(new HttpError(409, "Idempotency-Key was already used for a different request"), {
        code: "idempotency_key_reused",
      });
    if (existing && existing.status !== PENDING)
      return new Response(existing.body, {
        status: existing.status,
        headers: { "content-type": "application/json; charset=utf-8", "Idempotency-Replayed": "true" },
      });
    const stale = !existing || Date.now() - Date.parse(existing.createdAt) > STALE_CLAIM_MS;
    if (!stale)
      throw Object.assign(new HttpError(409, "A request with this Idempotency-Key is still being processed"), {
        code: "idempotency_in_progress",
      });
    await db
      .prepare(
        `DELETE FROM mutation_receipts
          WHERE user_id = ?1 AND scope = ?2 AND idempotency_key = ?3 AND response_status = ${PENDING}`,
      )
      .bind(userId, scope, key)
      .run();
    claimed = await claim();
    if (!claimed)
      throw Object.assign(new HttpError(409, "A request with this Idempotency-Key is still being processed"), {
        code: "idempotency_in_progress",
      });
  }

  const release = () =>
    db
      .prepare(
        `DELETE FROM mutation_receipts
          WHERE user_id = ?1 AND scope = ?2 AND idempotency_key = ?3 AND response_status = ${PENDING}`,
      )
      .bind(userId, scope, key)
      .run();

  let response: Response;
  try {
    response = await run(request);
  } catch (error) {
    await release();
    throw error;
  }
  const json = (response.headers.get("content-type") ?? "").includes("application/json");
  if (response.status < 200 || response.status > 299 || !json) {
    await release();
    return response;
  }
  const text = await response.text();
  await db
    .prepare(
      `UPDATE mutation_receipts SET response_json = ?4, response_status = ?5
        WHERE user_id = ?1 AND scope = ?2 AND idempotency_key = ?3`,
    )
    .bind(userId, scope, key, text, response.status)
    .run();
  return new Response(text, { status: response.status, statusText: response.statusText, headers: response.headers });
}
