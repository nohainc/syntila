import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { signToken, TokenVerifier } from "../src/auth";
import { configureIdentityVerifier } from "../src/domain/auth/identity-service";
import { EmailOutbox } from "../src/platform/email";
import { PgDb } from "../src/platform/data";
import { createRuntime } from "../src/runtime";
import { pgD1 } from "./domain/helpers/pg-d1";

let base = "", stop = async () => {}, sign: (claims: Record<string, unknown>) => Promise<string>, sql: any;
beforeAll(async () => {
  ({ sql } = await pgD1());
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pub = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k" };
  const priv = { ...(await crypto.subtle.exportKey("jwk", pair.privateKey)), kid: "k" } as JsonWebKey & { kid: string };
  configureIdentityVerifier(new TokenVerifier([pub], "https://syntila.app", "syntila-backend"));
  sign = (claims) => { const now = Math.floor(Date.now() / 1000); return signToken(priv, { iss: "https://syntila.app", aud: "syntila-backend", iat: now, exp: now + 60, ...claims }); };
  const runtime = createRuntime(sql, new PgDb(sql), { SYNTILA_ENVIRONMENT: "production", BETTER_AUTH_TRUSTED_ORIGINS: "https://syntila.app" });
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: (r, s) => runtime.fetch(r, s as any), websocket: runtime.websocket as any });
  await runtime.start();
  base = `http://127.0.0.1:${server.port}`;
  stop = async () => { server.stop(true); await runtime.stop(); };
});
afterAll(() => stop());

const call = async (token: string | null, path: string, body: unknown = {}) => {
  const r = await fetch(base + path, { method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) });
  const text = await r.text();
  try { return { status: r.status, body: JSON.parse(text) as any }; } catch { throw new Error(`${r.status} ${text.slice(0, 500)}`); }
};
const internalToken = () => sign({ sub: "syntila-auth", typ: "internal" });

describe("internal account endpoints", () => {
  test("accept only short-lived internal tokens", async () => {
    expect((await call(null, "/internal/accounts/u1/profile")).status).toBe(401);
    const user = await sign({ sub: "u1", typ: "user", email: "u1@test", name: "U1" });
    expect((await call(user, "/internal/accounts/u1/profile")).status).toBe(403);
    const now = Math.floor(Date.now() / 1000);
    const longLived = await sign({ sub: "syntila-auth", typ: "internal", exp: now + 3600 });
    expect((await call(longLived, "/internal/accounts/u1/profile")).status).toBe(401);
    // And internal tokens are not user identities on the API.
    const api = await fetch(`${base}/api/spaces`, { headers: { authorization: `Bearer ${await internalToken()}` } });
    expect(api.status).toBe(401);
  });

  test("profile sync updates the user and notifies connected people; deletion anonymizes and is idempotent", async () => {
    const userToken = await sign({ sub: "dora", typ: "user", email: "dora@test", name: "Dora" });
    const created = await fetch(`${base}/api/spaces`, { method: "POST", headers: { authorization: `Bearer ${userToken}`, "content-type": "application/json", origin: "https://syntila.app" }, body: JSON.stringify({ name: "Mine" }) });
    expect(created.status).toBe(201);

    const profile = await call(await internalToken(), "/internal/accounts/dora/profile", { name: "Dora N", email: "Dora.New@Test", image: null, emailVerified: true });
    expect(profile).toEqual({ status: 200, body: { ok: true, updated: true } });
    const [row] = await sql`SELECT email, display_name, email_verified, status FROM users WHERE id = 'dora'`;
    expect(row).toEqual({ email: "dora.new@test", display_name: "Dora N", email_verified: true, status: "active" });
    expect((await call(await internalToken(), "/internal/accounts/nobody/profile", { name: "X" })).body).toEqual({ ok: true, updated: false });

    for (let i = 0; i < 2; i++) expect((await call(await internalToken(), "/internal/accounts/dora/deletion")).status).toBe(200);
    const [gone] = await sql`SELECT email, display_name, status FROM users WHERE id = 'dora'`;
    expect(gone).toEqual({ email: "deleted+dora@syntila.invalid", display_name: "Deleted user", status: "deactivated" });
    // The account's own group Space with no other member is removed.
    expect(Number((await sql`SELECT count(*)::int AS n FROM spaces WHERE owner_user_id = 'dora'`)[0].n)).toBe(0);
  });
});

describe("email outbox", () => {
  test("stores at once, retries with backoff until the relay accepts, then marks sent", async () => {
    let calls = 0;
    const relay = { async send() { calls++; if (calls === 1) throw new Error("relay down"); return { messageId: "relay-1" }; } };
    const outbox = new EmailOutbox(sql, relay);
    const { messageId } = await outbox.send({ to: "a@test", subject: "Hi", text: "x" });
    await Bun.sleep(50); // the enqueue pokes a delivery: first attempt fails
    let [row] = await sql`SELECT status, attempts, last_error, next_attempt_at > now() AS later FROM email_outbox WHERE id = ${messageId}`;
    expect(row).toMatchObject({ status: "pending", attempts: 1, last_error: "relay down", later: true });
    expect(await outbox.deliverDue()).toBe(0); // not due yet
    await sql`UPDATE email_outbox SET next_attempt_at = now() WHERE id = ${messageId}`;
    expect(await outbox.deliverDue()).toBe(1);
    [row] = await sql`SELECT status, relay_message_id FROM email_outbox WHERE id = ${messageId}`;
    expect(row).toEqual({ status: "sent", relay_message_id: "relay-1" });
  });

  test("gives up on an invalid recipient", async () => {
    const outbox = new EmailOutbox(sql, { async send() { throw Object.assign(new Error("bad address"), { code: "invalid_recipient" }); } });
    const { messageId } = await outbox.send({ to: "nope", subject: "s" });
    await Bun.sleep(50);
    const [row] = await sql`SELECT status FROM email_outbox WHERE id = ${messageId}`;
    expect(row.status).toBe("failed");
  });
});

describe("account admin endpoints", () => {
  test("refuses manual plan changes for provider-linked subscriptions", async () => {
    await sql`INSERT INTO users(id,email,display_name,status,created_at,updated_at) VALUES
      ('provider-user','provider@test','Provider','active',now(),now()),
      ('overridden-user','overridden@test','Overridden','active',now(),now()),
      ('customer-user','customer@test','Customer','active',now(),now()),
      ('sandbox-user','sandbox@test','Sandbox','active',now(),now()),
      ('sandbox-no-plan','no-plan@test','No plan','active',now(),now())`;
    await sql`INSERT INTO account_plans(user_id,tier,status,source,provider_customer_id,provider_subscription_id,created_at,updated_at) VALUES
      ('provider-user','paid','active','provider','ctm_test','sub_test',now(),now()),
      ('overridden-user','free','canceled','manual','ctm_old','sub_old',now(),now()),
      ('customer-user','free','canceled','manual','ctm_only',NULL,now(),now()),
      ('sandbox-user','paid','active','manual',NULL,NULL,now(),now())`;
    await sql`INSERT INTO paddle_sandbox_subscriptions(subscription_id,user_id,customer_id,status,occurred_at) VALUES('sub_sandbox','sandbox-user','ctm_sandbox','active',now()),('sub_no_plan','sandbox-no-plan','ctm_no_plan','active',now())`;
    const token = await internalToken();
    for (const [id, email] of [['provider-user', 'provider@test'], ['overridden-user', 'overridden@test'], ['customer-user', 'customer@test'], ['sandbox-user', 'sandbox@test'], ['sandbox-no-plan', 'no-plan@test']]) {
      for (const action of ['grant_paid', 'revoke_paid']) {
        const result = await call(token, `/internal/admin/accounts/${id}/plan`, { action, email });
        expect(result.status).toBe(409);
        expect(result.body.code).toBe('provider_subscription_managed');
      }
    }
    const rows = await sql`SELECT user_id,tier,status,source,provider_subscription_id FROM account_plans WHERE user_id IN ('provider-user','overridden-user','customer-user','sandbox-user') ORDER BY user_id`;
    expect(rows).toEqual([
      { user_id: 'customer-user', tier: 'free', status: 'canceled', source: 'manual', provider_subscription_id: null },
      { user_id: 'overridden-user', tier: 'free', status: 'canceled', source: 'manual', provider_subscription_id: 'sub_old' },
      { user_id: 'provider-user', tier: 'paid', status: 'active', source: 'provider', provider_subscription_id: 'sub_test' },
      { user_id: 'sandbox-user', tier: 'paid', status: 'active', source: 'manual', provider_subscription_id: null },
    ]);
    expect(Number((await sql`SELECT count(*) AS n FROM account_plans WHERE user_id='sandbox-no-plan'`)[0].n)).toBe(0);
    const stats = await call(token, '/internal/admin/accounts/stats', { ids: ['provider-user', 'overridden-user', 'customer-user', 'sandbox-user', 'sandbox-no-plan'] });
    expect(stats.body.stats['provider-user'].plan_management).toBe('provider');
    expect(stats.body.stats['overridden-user'].plan_management).toBe('provider');
    expect(stats.body.stats['customer-user'].plan_management).toBe('provider');
    expect(stats.body.stats['sandbox-user'].plan_management).toBe('provider');
    expect(stats.body.stats['sandbox-no-plan'].plan_management).toBe('provider');
  });

  test("stats, plan grant/revoke and status mirror", async () => {
    const user = await sign({ sub: "ops-user", typ: "user", email: "ops@test", name: "Ops" });
    await fetch(`${base}/api/spaces`, { method: "POST", headers: { authorization: `Bearer ${user}`, "content-type": "application/json", origin: "https://syntila.app" }, body: JSON.stringify({ name: "Ops" }) });
    await sql`INSERT INTO worker_instances (id, actor_id, owner_user_id, worker_type_id, name)
      VALUES ('ops-worker', '', 'ops-user', 'chatgpt', 'Operator Worker')`;
    const stats = await call(await internalToken(), "/internal/admin/accounts/stats", { ids: ["ops-user", "missing"] });
    expect(stats.status).toBe(200);
    expect(stats.body.stats["ops-user"]).toMatchObject({ spaces: 1, workers: 1, plan: "free" });
    expect(stats.body.stats["ops-user"]).not.toHaveProperty("workspaces");
    expect(stats.body.stats["ops-user"].plan_management).toBe("manual");
    expect(stats.body.stats.missing).toBeUndefined();

    expect((await call(await internalToken(), "/internal/admin/accounts/ops-user/plan", { action: "grant_paid", email: "nobody@test" })).status).toBe(409);
    expect((await call(await internalToken(), "/internal/admin/accounts/ops-user/plan", { action: "grant_paid", email: "ops@test" })).body).toEqual({ ok: true, plan: "paid" });
    expect((await call(await internalToken(), "/internal/admin/accounts/new-user/plan", { action: "grant_paid", email: "new@test" })).body.plan).toBe("paid");
    expect((await call(await internalToken(), "/internal/admin/accounts/ops-user/plan", { action: "revoke_paid", email: "ops@test" })).body.plan).toBe("free");

    expect((await call(await internalToken(), "/internal/admin/accounts/ops-user/status", { status: "suspended" })).body).toEqual({ ok: true, updated: true });
    const blocked = await fetch(`${base}/api/spaces`, { headers: { authorization: `Bearer ${user}` } });
    expect(blocked.status).toBeGreaterThanOrEqual(401);
    expect((await call(await internalToken(), "/internal/admin/accounts/ops-user/status", { status: "active" })).body.updated).toBe(true);
    expect((await fetch(`${base}/api/spaces`, { headers: { authorization: `Bearer ${user}` } })).status).toBe(200);
  });
});
