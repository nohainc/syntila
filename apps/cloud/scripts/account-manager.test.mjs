import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { environment, listSQL, changeSQL, handle } from "./account-manager.mjs";

// Accounts and sessions: the auth Worker's D1 schema.
function database() {
  const db = new DatabaseSync(":memory:");
  db.exec(readFileSync(new URL("../migrations/0001_auth.sql", import.meta.url), "utf8"));
  db.exec(`
    INSERT INTO users(id,email,display_name,status,created_at,updated_at) VALUES ('one','one@example.com','One','active','2026-01-01','2026-01-01'),('two','two@example.com','Two','deactivated','2026-01-01','2026-01-01');
    INSERT INTO auth_sessions(id,user_id,token,expires_at,created_at,updated_at) VALUES ('session','one','secret','2099','2026','2026');
    INSERT INTO desktop_human_sessions(id,user_id,token_hash,audience,created_at,last_used_at,expires_at) VALUES ('desktop','one','hash','syntila.desktop.management','2026','2026','2099');`);
  return db;
}
const sqliteQuery = (db) => async (_config, sql) => {
  const rows = [];
  for (const statement of sql.split(/;\s*\n/).map((s) => s.trim()).filter(Boolean)) {
    const prepared = db.prepare(statement.replace(/;$/, ""));
    if (/^\s*SELECT/i.test(statement)) rows.push(...prepared.all());
    else prepared.run();
  }
  return rows;
};

test("environments are explicit and separated", () => {
  assert.equal(environment("local").flag, "--local");
  assert.equal(environment("production").flag, "--remote");
  assert.notEqual(environment("local").database, environment("production").database);
  assert.equal(environment("production").backend, "https://api.syntila.app");
  assert.equal(environment("local").backend, "http://localhost:8788");
  assert.throws(() => environment("prod"));
});

test("list reads accounts from D1, searches literally, and excludes credentials", () => {
  const db = database();
  const rows = db.prepare(listSQL()).all();
  assert.equal(rows.length, 2);
  assert.equal("password" in rows[0], false);
  assert.equal(db.prepare(listSQL("' OR 1=1 --")).all().length, 0);
  assert.equal(db.prepare(listSQL("one@")).all().length, 1);
  assert.equal(db.prepare(listSQL("%")).all().length, 0);
  db.close();
});

test("list merges usage and plans from the backend, and degrades without it", async () => {
  const db = database();
  const backend = async (_config, path, body) => {
    assert.equal(path, "/internal/admin/accounts/stats");
    assert.deepEqual(body.ids.sort(), ["one", "two"]);
    return { stats: { one: { spaces: 2, requests: 5, plan: "paid" } } };
  };
  const { users, warning } = await handle({ environment: "local", action: "list" }, sqliteQuery(db), fetch, backend);
  const one = users.find((u) => u.id === "one");
  assert.equal(one.spaces, 2);
  assert.equal(one.plan, "paid");
  assert.equal(one.email, "one@example.com");
  assert.equal(users.find((u) => u.id === "two").plan, "free");
  assert.equal(warning, undefined);
  const offline = await handle({ environment: "local", action: "list" }, sqliteQuery(db), fetch, async () => { throw new Error("HTTP 503"); });
  assert.equal(offline.users.length, 2);
  assert.match(offline.warning, /unavailable/);
  db.close();
});

test("plan changes go to the backend with the account email", async () => {
  const db = database();
  const calls = [];
  const backend = async (_config, path, body) => {
    calls.push([path, body]);
    return { ok: true, plan: body.action === "grant_paid" ? "paid" : "free" };
  };
  const result = await handle({ environment: "local", action: "grant_paid", id: "one", email: "one@example.com" }, sqliteQuery(db), fetch, backend);
  assert.match(result.message, /enabled/);
  assert.deepEqual(calls[0], ["/internal/admin/accounts/one/plan", { action: "grant_paid", email: "one@example.com" }]);
  await assert.rejects(handle({ environment: "local", action: "grant_paid", id: "one", email: "one@example.com" }, sqliteQuery(db), fetch, async () => ({ plan: "free" })));
  db.close();
});

test("lock mirrors the status on the backend and reports when it cannot", async () => {
  const db = database();
  const calls = [];
  const result = await handle({ environment: "local", action: "lock", id: "one", email: "one@example.com" }, sqliteQuery(db), fetch, async (_c, path, body) => { calls.push([path, body]); return { ok: true }; });
  assert.match(result.message, /locked/);
  assert.deepEqual(calls[0], ["/internal/admin/accounts/one/status", { status: "suspended" }]);
  const unlocked = await handle({ environment: "local", action: "unlock", id: "one", email: "one@example.com", confirmEmail: "one@example.com" }, sqliteQuery(db), fetch, async () => { throw new Error("down"); });
  assert.match(unlocked.message, /could not be updated/);
  assert.equal(db.prepare("SELECT status FROM users WHERE id='one'").get().status, "active");
  db.close();
});

test("lock revokes sessions and audits; unlock preserves deactivated accounts", () => {
  const db = database();
  db.exec(changeSQL("one", "lock", "one@example.com", "tester"));
  assert.equal(
    db.prepare("SELECT status FROM users WHERE id='one'").get().status,
    "suspended",
  );
  assert.equal(
    db.prepare("SELECT count(*) AS n FROM auth_sessions").get().n,
    0,
  );
  assert.ok(
    db.prepare("SELECT revoked_at FROM desktop_human_sessions").get()
      .revoked_at,
  );
  assert.equal(
    db.prepare("SELECT count(*) AS n FROM auth_audit_events").get().n,
    1,
  );
  db.exec(changeSQL("one", "lock", "one@example.com", "tester"));
  assert.equal(
    db.prepare("SELECT count(*) AS n FROM auth_audit_events").get().n,
    1,
  );
  db.exec(changeSQL("one", "unlock", "one@example.com", "tester"));
  assert.equal(
    db.prepare("SELECT status FROM users WHERE id='one'").get().status,
    "active",
  );
  db.exec(changeSQL("two", "unlock", "two@example.com", "tester"));
  assert.equal(
    db.prepare("SELECT status FROM users WHERE id='two'").get().status,
    "deactivated",
  );
  db.close();
});

test("confirmation and stale accounts stop mutations", async () => {
  let calls = 0;
  const query = async () => {
    calls++;
    return [];
  };
  await assert.rejects(
    handle(
      {
        environment: "production",
        action: "unlock",
        email: "a",
        confirmEmail: "b",
      },
      query,
    ),
  );
  assert.equal(calls, 0);
  await assert.rejects(
    handle(
      {
        environment: "local",
        action: "unlock",
        id: "one",
        email: "a",
        confirmEmail: "a",
      },
      query,
    ),
  );
  assert.equal(calls, 1);
});

test("reset targets the selected environment and propagates delivery request failures", async () => {
  const input = {
    environment: "local",
    action: "reset",
    id: "one",
    email: "one@example.com",
    confirmEmail: "one@example.com",
  };
  const query = async () => [
    { id: "one", email: input.email, status: "active" },
  ];
  let sent;
  const response = await handle(input, query, async (url, options) => {
    sent = { url, body: JSON.parse(options.body) };
    return new Response("{}");
  });
  assert.equal(
    sent.url,
    "http://localhost:8787/api/auth/request-password-reset",
  );
  assert.equal(sent.body.email, input.email);
  assert.match(response.message, /delivery is not confirmed/);
  await assert.rejects(
    handle(input, query, async () => new Response("", { status: 503 })),
    /503/,
  );
  await assert.rejects(
    handle(
      input,
      async () => [{ status: "suspended" }],
      async () => {
        throw Error("must not send");
      },
    ),
    /Unlock/,
  );
});
