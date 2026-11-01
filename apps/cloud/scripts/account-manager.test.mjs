import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { environment, listSQL, changeSQL, planSQL, handle } from "./account-manager.mjs";

import { readdirSync } from "node:fs";
function database() {
  const db = new DatabaseSync(":memory:");
  const dir = new URL("../migrations-v8/", import.meta.url);
  db.exec(
    readFileSync(
      new URL(
        readdirSync(dir).find((f) => f.startsWith("0001")),
        dir,
      ),
      "utf8",
    ),
  );
  for (const name of [
    "0010_conversation_workflows.sql",
    "0011_conversation_turns.sql",
    "0094_account_plans.sql",
  ]) {
    db.exec(readFileSync(new URL(name, dir), "utf8"));
  }
  db.exec(`
    INSERT INTO users(id,email,display_name,status,created_at,updated_at) VALUES ('one','one@example.com','One','active','2026-01-01','2026-01-01'),('two','two@example.com','Two','deactivated','2026-01-01','2026-01-01');
    INSERT INTO auth_sessions(id,user_id,token,expires_at,created_at,updated_at) VALUES ('session','one','secret','2099','2026','2026');
    INSERT INTO desktop_human_sessions(id,user_id,token_hash,audience,created_at,last_used_at,expires_at) VALUES ('desktop','one','hash','syntila.desktop.management','2026','2026','2099');`);
  return db;
}
test("environments are explicit and separated", () => {
  assert.equal(environment("local").flag, "--local");
  assert.equal(environment("production").flag, "--remote");
  assert.notEqual(
    environment("local").database,
    environment("production").database,
  );
  assert.throws(() => environment("prod"));
});
test("list uses actual schema, searches literally, and excludes credentials", () => {
  const db = database();
  const rows = db.prepare(listSQL()).all();
  assert.equal(rows.length, 2);
  assert.equal(rows[0].requests, 0);
  assert.equal(rows[0].messages, 0);
  assert.equal(rows[0].last_message_at, null);
  assert.equal("password" in rows[0], false);
  assert.equal(db.prepare(listSQL("' OR 1=1 --")).all().length, 0);
  assert.equal(db.prepare(listSQL("one@")).all().length, 1);
  assert.equal(db.prepare(listSQL("%")).all().length, 0);
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

test("activity counts remain scoped to the selected user", () => {
  const db = database();
  db.exec(`INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES ('space','one','Space','2026','2026');
    INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES ('membership','space','one','owner','2026','2026');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES ('thread','space','Thread','active','one','2026','2026');
    INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,created_at,updated_at) VALUES
    ('request1','thread','one','stateful','direct',1,'{}','completed','2026-01-01','2026'),
    ('request2','thread','one','stateful','direct',1,'{}','failed','2026-02-01','2026'),
    ('request3','thread','two','stateful','direct',1,'{}','failed','2026-03-01','2026');`);
  const [user] = db.prepare(listSQL("one@")).all();
  assert.equal(user.spaces, 1);
  assert.equal(user.requests, 2);
  assert.equal(user.failed_requests, 1);
  assert.equal(user.last_request_at, "2026-02-01");
  db.close();
});

test("message statistics exclude request prompts, edits, and other users", () => {
  const db = database();
  db.exec(`INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES ('space','one','Space','2026','2026');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES ('thread','space','Thread','active','one','2026','2026');
    INSERT INTO conversations(id,thread_id,workflow_id,workflow_version,created_at,updated_at) VALUES ('conversation','thread','chat',1,'2026','2026');
    INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,created_at,updated_at) VALUES
      ('request','thread','one','stateful','direct',1,'{}','completed','2026-01-01','2026');
    INSERT INTO conversation_user_messages(id,conversation_id,work_request_id,author_user_id,text,created_at) VALUES
      ('message','conversation','request','one','Hello','2026-03-01T10:30:00.000Z');
    INSERT INTO discussion_messages(id,thread_id,author_user_id,body,created_at,edited_at) VALUES
      ('discussion1','thread','one','Hello','2026-02-01T09:00:00.000Z','2026-06-01T00:00:00.000Z'),
      ('discussion2','thread','two','Other user','2026-05-01T00:00:00.000Z',NULL);`);
  let user = db.prepare(listSQL("one@")).get();
  assert.equal(user.messages, 1);
  assert.equal(user.requests, 1);
  assert.equal(user.last_message_at, "2026-02-01T09:00:00.000Z");
  db.exec(
    `INSERT INTO discussion_messages(id,thread_id,author_user_id,body,created_at) VALUES ('discussion3','thread','one','Latest','2026-04-01T12:15:30.000Z');`,
  );
  user = db.prepare(listSQL("one@")).get();
  assert.equal(user.messages, 2);
  assert.equal(user.last_message_at, "2026-04-01T12:15:30.000Z");
  db.close();
});

test("lock works without email retyping and still rejects stale account status", async () => {
  const input = {
    environment: "local",
    action: "lock",
    id: "one",
    email: "one@example.com",
  };
  let calls = 0;
  const reply = await handle(input, async () => {
    calls++;
    return [
      {
        id: "one",
        email: input.email,
        status: calls === 1 ? "active" : "suspended",
      },
    ];
  });
  assert.equal(calls, 2);
  assert.match(reply.message, /locked/);
  await assert.rejects(
    handle(input, async () => []),
    /changed or was removed/,
  );
  await assert.rejects(
    handle(input, async () => [{ status: "deactivated" }]),
    /status changed/,
  );
  await assert.rejects(
    handle({ ...input, action: "unlock" }, async () => []),
    /Retype/,
  );
  await assert.rejects(
    handle({ ...input, action: "reset" }, async () => []),
    /Retype/,
  );
});

test("plan grant and revoke toggle the effective tier and are audited", () => {
  const db = database();
  const plan = () => db.prepare(listSQL("one@")).get().plan;
  assert.equal(plan(), "free");
  db.exec(planSQL("one", "grant_paid", "one@example.com", "tester"));
  assert.equal(plan(), "paid");
  assert.equal(db.prepare(listSQL("one@")).get().plan_source, "manual");
  db.exec(planSQL("one", "revoke_paid", "one@example.com", "tester"));
  assert.equal(plan(), "free");
  assert.equal(
    db.prepare("SELECT status FROM account_plans WHERE user_id='one'").get()
      .status,
    "canceled",
  );
  // An expired provider period is overridden by an open-ended manual grant.
  db.exec(
    "UPDATE account_plans SET tier='paid',status='active',source='provider',current_period_end='2000-01-01' WHERE user_id='one'",
  );
  assert.equal(plan(), "free");
  db.exec(planSQL("one", "grant_paid", "one@example.com", "tester"));
  assert.equal(plan(), "paid");
  // Wrong email changes nothing.
  db.exec(planSQL("two", "grant_paid", "wrong@example.com", "tester"));
  assert.equal(db.prepare(listSQL("two@")).get().plan, "free");
  assert.equal(
    db
      .prepare(
        "SELECT count(*) AS n FROM auth_audit_events WHERE action LIKE 'account.admin.%_paid'",
      )
      .get().n,
    3,
  );
  db.close();
});
