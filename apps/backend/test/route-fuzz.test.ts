/**
 * Every route in the table, called with junk input by a signed-in user who
 * owns a Space and a Thread: unknown ids, empty and wrong-typed bodies.
 * Each route runs in its own freshly seeded world, and every path parameter
 * resolves to a real row (see `fixture`), so a DELETE in one route cannot
 * starve the routes after it.
 * A 5xx is a bug: the client's mistake must be answered 4xx.
 */
import { afterAll, beforeAll, expect, test } from "bun:test";
import { signToken, TokenVerifier } from "../src/auth";
import { configureIdentityVerifier } from "../src/domain/auth/identity-service";
import { routeTable, type WorkerRouteHandlers } from "../src/domain/routes/table";
import { PgD1Database } from "../src/platform/pg-d1";
import { createRuntime } from "../src/runtime";
import { pgD1 } from "./domain/helpers/pg-d1";
import { member, message, space, thread, user, workRequest, workspace } from "./domain/helpers/seed";
import { threadConversationId } from "../src/domain/routes/conversations";

let base = "", stop = async () => {}, mint: (sub: string) => Promise<string>, db: ReturnType<typeof pgD1>["sql"];
const logged: string[] = [];
beforeAll(async () => {
  const sql = db = pgD1().sql;
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pub = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k" };
  const priv = { ...(await crypto.subtle.exportKey("jwk", pair.privateKey)), kid: "k" } as JsonWebKey & { kid: string };
  configureIdentityVerifier(new TokenVerifier([pub], "https://syntila.app", "syntila-backend"));
  const now = Math.floor(Date.now() / 1000);
  mint = (sub) => signToken(priv, { iss: "https://syntila.app", aud: "syntila-backend", sub, typ: "user", email: `${sub}@test`, name: sub, iat: now, exp: now + 3600, sid: `s-${sub}`, client: "web" });
  const runtime = createRuntime(sql, new PgD1Database(sql), { SYNTILA_ENVIRONMENT: "production", BETTER_AUTH_TRUSTED_ORIGINS: "https://syntila.app", SYNTILA_RATE_LIMIT_PER_MINUTE: "0", SYNTILA_MUTATION_RATE_LIMIT_PER_MINUTE: "0" });
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: (r, s) => runtime.fetch(r, s as any), websocket: runtime.websocket as any });
  await runtime.start();
  base = `http://127.0.0.1:${server.port}`;
  stop = async () => { server.stop(true); await runtime.stop(); };
  const original = console.error;
  console.error = (...args: unknown[]) => { logged.push(args.map(String).join(" ")); };
  afterAll(() => { console.error = original; });
});
afterAll(() => stop());

const call = async (token: string, method: string, path: string, body?: string) => {
  const r = await fetch(base + path, {
    method,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", origin: "https://syntila.app" },
    body: method === "GET" || method === "HEAD" ? undefined : body,
    signal: AbortSignal.timeout(8_000),
  }).catch((e) => (e?.name === "TimeoutError" ? null : Promise.reject(e)));
  // null: the request hung (reported as a failure below).
  if (!r) return { status: 599, body: null, text: "hung for 8 s" };
  const text = await r.text();
  let json: any = null;
  try { json = text ? JSON.parse(text) : null; } catch {}
  return { status: r.status, body: json, text };
};


// ---- Fixtures --------------------------------------------------------------
type Fixture = { value: string; table?: string; column?: string; limitation?: string };
type World = Record<string, string>;
let worldSeq = 0;
const HEX = "a".repeat(64);
const FUTURE = "2099-01-01T00:00:00Z";
const T0 = "2026-01-01T00:00:00Z";

/** A fresh, self-contained set of rows for one route: ids are unique per world. */
async function seedWorld(token: string): Promise<World> {
  const n = ++worldSeq;
  const w: World = {
    spaceId: `fz-sp-${n}`, threadId: `fz-th-${n}`, workspaceId: `fz-ws-${n}`, workRequestId: `fz-wr-${n}`,
    messageId: `fz-dm-${n}`, fileId: `fz-file-${n}`, itemId: `fz-q-${n}`, inputId: `fz-in-${n}`,
    personIn: `fz-pin-${n}`, personOut: `fz-pout-${n}`, spaceInvOut: `fz-sinv-out-${n}`, spaceInvIn: `fz-sinv-in-${n}`,
    wsInvOut: `fz-winv-out-${n}`, wsInvIn: `fz-winv-in-${n}`, otherSpace: `fz-osp-${n}`, otherWorkspace: `fz-ows-${n}`,
    release: `9.${n}.0`, pluginRef: `fz-plugin-${n}`, workerId: `fz-worker-${n}`,
  };
  w.conversationId = threadConversationId(w.threadId!);
  const note = await call(token, "POST", "/api/notes", JSON.stringify({ title: "n", body: "b" }));
  expect(note.status).toBe(201);
  w.noteId = note.body.note.id;
  const inv = (id: string, spaceId: string, email: string, by: string) =>
    `INSERT INTO space_invitations(id,space_id,email,role,token_hash,invited_by_user_id,status,expires_at,created_at,updated_at)
       VALUES ('${id}','${spaceId}','${email}','viewer','h-${id}','${by}','pending','${FUTURE}','${T0}','${T0}')`;
  const winv = (id: string, ws: string, email: string, by: string) =>
    `INSERT INTO workspace_invitations(id,workspace_id,email,token_hash,invited_by_user_id,status,expires_at,created_at,updated_at)
       VALUES ('${id}','${ws}','${email}','h-${id}','${by}','pending','${FUTURE}','${T0}','${T0}')`;
  await db.unsafe([
    space(w.spaceId!, "fuzz-owner"), member(w.spaceId!, "fuzz-owner"), member(w.spaceId!, "fuzz-member", "collaborator"),
    thread(w.threadId!, w.spaceId!, "fuzz-owner"),
    `INSERT INTO conversations(id,thread_id,workflow_id,workflow_version,created_at,updated_at) VALUES ('${w.conversationId}','${w.threadId}','chat',1,'${T0}','${T0}')`,
    message(w.threadId!, "fuzz-owner", "[]", w.messageId),
    workRequest(w.threadId!, "fuzz-owner", "{}", w.workRequestId),
    workspace(w.workspaceId!, "fuzz-owner"),
    `INSERT INTO workspace_person_grants(workspace_id,user_id,granted_by_user_id,status,created_at,updated_at) VALUES ('${w.workspaceId}','fuzz-member','fuzz-owner','active','${T0}','${T0}')`,
    `INSERT INTO work_request_inputs(id,work_request_id,thread_id,workspace_id,user_id,position,name,media_type,size_bytes,state,created_at,updated_at)
       VALUES ('${w.inputId}','${w.workRequestId}','${w.threadId}','${w.workspaceId}','fuzz-owner',0,'a.txt','text/plain',3,'uploaded','${T0}','${T0}')`,
    `INSERT INTO user_files(id,user_id,thread_id,space_id,name,media_type,size_bytes,created_at) VALUES ('${w.fileId}','fuzz-owner','${w.threadId}','${w.spaceId}','a.txt','text/plain',3,now())`,
    `INSERT INTO thread_request_queue(id,thread_id,author_user_id,request_json,position,status,created_at,updated_at) VALUES ('${w.itemId}','${w.threadId}','fuzz-owner','{"message":"hi"}',1,'queued','${T0}','${T0}')`,
    // The People relationship with fuzz-other, and one pending invitation each way.
    `INSERT INTO people_relationships(user_low_id,user_high_id,established_at) VALUES ('fuzz-other','fuzz-owner','${T0}') ON CONFLICT DO NOTHING`,
    // One pending invitation per pair of people, so each world has its own counterparts.
    user(`fz-from-${n}`), user(`fz-to-${n}`),
    `INSERT INTO person_invitations(id,inviter_user_id,invitee_user_id,status,created_at,expires_at,updated_at) VALUES ('${w.personIn}','fz-from-${n}','fuzz-owner','pending','${T0}','${FUTURE}','${T0}')`,
    `INSERT INTO person_invitations(id,inviter_user_id,invitee_user_id,status,created_at,expires_at,updated_at) VALUES ('${w.personOut}','fuzz-owner','fz-to-${n}','pending','${T0}','${FUTURE}','${T0}')`,
    // A second owner's Space and Workspace, which invite the owner.
    space(w.otherSpace!, "fuzz-other-owner"), member(w.otherSpace!, "fuzz-other-owner"),
    workspace(w.otherWorkspace!, "fuzz-other-owner"),
    inv(w.spaceInvOut!, w.spaceId!, "fuzz-stranger@test", "fuzz-owner"),
    inv(w.spaceInvIn!, w.otherSpace!, "fuzz-owner@test", "fuzz-other-owner"),
    winv(w.wsInvOut!, w.workspaceId!, "fuzz-stranger@test", "fuzz-owner"),
    winv(w.wsInvIn!, w.otherWorkspace!, "fuzz-owner@test", "fuzz-other-owner"),
    `INSERT INTO workspace_releases(version,package_digest,package_r2_key,signature,created_at) VALUES ('${w.release}','${HEX}','k-${n}','sig','${T0}')`,
    `INSERT INTO account_worker_plugins(plugin_ref,owner_user_id,plugin_id,display_name,created_at,updated_at) VALUES ('${w.pluginRef}','fuzz-owner','p${n}','Plugin','${T0}','${T0}')`,
    `INSERT INTO account_worker_plugin_versions(plugin_ref,version,manifest_digest,manifest_json,origin_json,created_at) VALUES ('${w.pluginRef}','1.0.0','${HEX}','{}','{}','${T0}')`,
    `INSERT INTO workspace_worker_plugin_enablements(workspace_id,plugin_ref,version,manifest_digest,consent_hash,intent,updated_at) VALUES ('${w.workspaceId}','${w.pluginRef}','1.0.0','${HEX}','${HEX}','enabled','${T0}')`,
    `INSERT INTO workspace_worker_inventory(worker_id,workspace_id,owner_user_id,worker_type_id,activation_state,readiness_state,local_concurrency_limit,revision,created_at,updated_at,last_seen_at)
       VALUES ('${w.workerId}','${w.workspaceId}','fuzz-owner','claude','enabled','ready',1,1,'${T0}','${T0}','${T0}')`,
  ].join(";\n"));
  return w;
}

/** Why a parameter cannot reach its row with a user token (machine, admin, or non-row ids). */
const LIMITS = {
  runtime: "Workspace runtime token required (401/400 for a user token)",
  admin: "Admin only (403 for a user token)",
  nonRow: "Not a database row",
};

/** The real value of path parameter `p` of `route`: which row it is, and where it lives. */
function fixture(route: string, p: string, w: World): Fixture | undefined {
  const row = (value: string | undefined, table: string, column = "id"): Fixture | undefined => value === undefined ? undefined : { value, table, column };
  switch (p) {
    case "spaceId": return row(w.spaceId, "spaces");
    case "threadId": return row(w.threadId, "threads");
    case "workspaceId": return row(w.workspaceId, "execution_workspaces");
    case "workRequestId": return row(w.workRequestId, "work_requests");
    case "messageId": return row(w.messageId, "discussion_messages");
    case "noteId": return row(w.noteId, "user_notes");
    case "conversationId": return row(w.conversationId, "conversations");
    case "itemId": return row(w.itemId, "thread_request_queue");
    case "inputId": return row(w.inputId, "work_request_inputs");
    case "pluginRef": return row(w.pluginRef, "account_worker_plugins", "plugin_ref");
    case "workerId": return row(w.workerId, "workspace_worker_inventory", "worker_id");
    case "workerTypeId": return row("claude", "worker_catalog", "worker_type_id");
    case "version": return route.includes("releases") ? row(w.release, "workspace_releases", "version") : undefined;
    case "workflowId": return { value: "chat", limitation: LIMITS.nonRow + " (built-in workflow id)" };
    case "kind": return { value: "thread", limitation: LIMITS.nonRow + " (pin kind)" };
    case "targetId": return row(w.threadId, "threads");
    case "fileId":
      if (route.includes("workspace-runtime")) return { value: w.fileId!, limitation: LIMITS.runtime };
      return row(w.fileId, "user_files");
    case "sessionId": return { value: `fz-session-${w.spaceId}`, limitation: LIMITS.runtime };
    case "keyId": return { value: `fz-key-${w.spaceId}`, limitation: LIMITS.admin };
    case "userId":
      if (route.includes("/members/")) return row("fuzz-member", "space_memberships", "user_id");
      if (route.includes("person-grants") || route.includes("member-access")) return row("fuzz-member", "workspace_person_grants", "user_id");
      return row("fuzz-other", "users");
    case "invitationId":
      if (route.startsWith("/api/workspaces/")) return row(w.wsInvOut, "workspace_invitations");
      if (route.startsWith("/api/spaces/")) return row(w.spaceInvOut, "space_invitations");
      return row(w.spaceInvIn, "space_invitations");
    case "id":
      if (route.includes("/people/invitations/")) return row(route.endsWith("/cancel") ? w.personOut : w.personIn, "person_invitations");
      if (route.includes("workspace-invitations")) return row(w.wsInvIn, "workspace_invitations");
      if (route.includes("issue-reports")) return { value: `fz-report-${w.spaceId}`, limitation: LIMITS.admin };
      return undefined;
  }
  return undefined;
}

const routes = routeTable({} as WorkerRouteHandlers);
const paramsOf = (route: { segments: string[] }) => route.segments.filter((s) => s.startsWith(":")).map((s) => s.slice(1));

const JUNK = [
  undefined,
  "{}",
  JSON.stringify({ name: 5, title: [], body: {}, kind: "nope", status: "nope", ids: "x", role: 7, email: 3, userId: [], permissions: "all", settings: "x", enabled: "yes", position: "first", limit: -1, cursor: 5, request: "x", message: 1, references: "x", attachments: {}, workerId: 1, runtimeId: 2, payload: "x" }),
  JSON.stringify({ name: "x".repeat(20_000), body: "x".repeat(200_000) }),
];
const QUERIES = ["", "?limit=abc&cursor=%%%&before=nope&after=-1"];


const REACH = { A: 0, B: 0, C: 0, routes: 0, withParams: { A: 0, B: 0, C: 0, routes: 0 } };

test("no route answers 5xx to junk input", async () => {
  const token = await mint("fuzz-owner");
  for (const sub of ["fuzz-member", "fuzz-stranger", "fuzz-other", "fuzz-other-owner"]) await call(await mint(sub), "GET", "/api/session");
  await call(token, "GET", "/api/session");
  const failures: string[] = [];
  const started = performance.now();
  for (const route of routes) {
    const methods = route.method === "*" ? ["GET", "POST", "PUT", "PATCH", "DELETE"] : [route.method];
    const params = paramsOf(route);
    const statuses = new Set<number>();
    for (const fill of ["real", "unknown"] as const) {
      // A fresh world per route and pass: a DELETE here cannot starve a later route.
      const w = fill === "real" ? await seedWorld(token) : {};
      const path = route.segments.map((s) => s.startsWith(":") ? encodeURIComponent(fill === "real" ? fixture(route.path, s.slice(1), w)?.value ?? `unknown-${s.slice(1)}` : `unknown-${s.slice(1)}`) : s).join("/");
      for (const method of methods)
        for (const query of QUERIES)
          for (const body of JUNK) {
            const before = logged.length;
            const r = await call(token, method, `/${path}${query}`, body);
            if (fill === "real") statuses.add(r.status);
            if (process.env.FUZZ_REPORT && body === JUNK[2] && method !== "GET" && r.status < 300)
              console.log(`ACCEPTED ${method} ${route.path} [${fill}] -> ${r.status} ${r.text.slice(0, 160)}`);
            // 503 "unavailable" is a service this test does not configure (support, file storage).
            if (r.status >= 500 && !(r.status === 503 && r.body?.code === "unavailable")) {
              const log = logged.slice(before).find((l) => l.includes("unhandled_error")) ?? r.text.slice(0, 200);
              failures.push(`${method} ${route.path}${query} [${fill}] body=${(body ?? "none").slice(0, 30)} -> ${r.status} ${log.slice(0, 400)}`);
            }
          }
    }
    // Reach, same method as the baseline: A some status other than 404, B other than 404/401/405, C some 2xx.
    const a = [...statuses].some((s) => s !== 404), b = [...statuses].some((s) => ![404, 401, 405].includes(s)), c = [...statuses].some((s) => s >= 200 && s < 300);
    REACH.routes++; REACH.A += +a; REACH.B += +b; REACH.C += +c;
    if (params.length) { REACH.withParams.routes++; REACH.withParams.A += +a; REACH.withParams.B += +b; REACH.withParams.C += +c; }
  }
  console.log(`REACH ${JSON.stringify(REACH)} seconds=${((performance.now() - started) / 1000).toFixed(1)}`);
  if (failures.length) console.log(failures.join("\n"));
  expect(failures).toEqual([]);
}, 600_000);

test("every path parameter of every route has a real fixture", async () => {
  const token = await mint("fuzz-owner");
  await call(token, "GET", "/api/session");
  for (const sub of ["fuzz-member", "fuzz-stranger", "fuzz-other", "fuzz-other-owner"]) await call(await mint(sub), "GET", "/api/session");
  const w = await seedWorld(token);
  const unmapped: string[] = [], missingRows: string[] = [];
  for (const route of routes)
    for (const p of paramsOf(route)) {
      const f = fixture(route.path, p, w);
      if (!f) { unmapped.push(`${route.path} :${p}`); continue; }
      if (f.limitation || !f.table) continue;
      const rows = await db.unsafe(`SELECT 1 FROM ${f.table} WHERE ${f.column} = $1 LIMIT 1`, [f.value]);
      if (rows.length === 0) missingRows.push(`${route.path} :${p} -> ${f.table}.${f.column}=${f.value}`);
    }
  // A new route with a new parameter must get a fixture here.
  expect(unmapped).toEqual([]);
  // A mapping alone proves nothing: the row must exist.
  expect(missingRows).toEqual([]);
}, 120_000);

test("an oversized body is refused with 413 promptly, not left hanging", async () => {
  const token = await mint("fuzz-big");
  await call(token, "GET", "/api/session");
  const ws = "fuzz-big-ws";
  await db.unsafe(workspace(ws, "fuzz-big"));
  const big = new Uint8Array(6 * 1024 * 1024);
  const form = new FormData();
  form.set("original", new File([big], "a.png", { type: "image/png" }));
  form.set("thumbnail", new File([new Uint8Array(10)], "t.png", { type: "image/png" }));
  const started = performance.now();
  const avatar = await fetch(base + "/api/profile/avatar", {
    method: "PUT", body: form, signal: AbortSignal.timeout(8_000),
    headers: { authorization: `Bearer ${token}`, origin: "https://syntila.app" },
  });
  expect(avatar.status).toBe(413);
  const prefs = await call(token, "PUT", `/api/workspaces/${ws}/worker-preferences`, JSON.stringify({ pad: "x".repeat(2 * 1024 * 1024) }));
  expect(prefs.status).toBe(413);
  // JSON bodies are capped at 2 MiB for every route, with or without an Idempotency-Key.
  const huge = JSON.stringify({ title: "t", body: "x".repeat(3 * 1024 * 1024) });
  const note = await call(token, "POST", "/api/notes", huge);
  expect([note.status, note.body?.code]).toEqual([413, "payload_too_large"]);
  const keyed = await fetch(base + "/api/notes", {
    method: "POST", body: huge, signal: AbortSignal.timeout(8_000),
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", origin: "https://syntila.app", "idempotency-key": "huge-0000000000001" },
  });
  expect(keyed.status).toBe(413);
  expect(performance.now() - started).toBeLessThan(8_000);
});
