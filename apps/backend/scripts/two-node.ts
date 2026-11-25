#!/usr/bin/env bun
/**
 * Two backend processes on one PostgreSQL database: the guard for the
 * multi-server rules of ADR-033 (state committed in PostgreSQL, no correctness
 * held in process memory). Used from P2 on; P0 adds the harness.
 *
 *   bun scripts/two-node.ts            run all checks
 *   bun scripts/two-node.ts --strict   treat the known gaps below as failures
 *
 * It creates (and drops) its own database, applies the migrations, starts two
 * `bun src/server.ts` processes on different ports and talks to both as one
 * user. Environment: PGHOST/PGPORT/PGUSER/PGPASSWORD for a role with CREATEDB
 * (defaults as in scripts/rehearse.sh), TWO_NODE_DB (default syntila_twonode).
 *
 * Checks that must always pass (they are the multi-server rules):
 *   1. both nodes become ready on the same database;
 *   2. a Space and Thread created on node A are readable on node B;
 *   3. an Idempotency-Key replayed on the other node returns the first response;
 *   4. concurrent posts alternating between the nodes number the history 1..n
 *      without gaps, and scripts/check-invariants.sql reports no violation.
 *   5. (P2, ADR-033) a node killed with SIGKILL while writes are in flight
 *      loses no notification: every committed event has its outbox row, and the
 *      surviving node's dispatcher delivers what the dead node left pending.
 *
 * Known gaps (reported, not failed, until the phase that closes them; `--strict`
 * fails them): realtime fan-out across nodes. The realtime hub is in process
 * today, so an event written on node B does not reach a socket on node A. ADR-038
 * (P9) and ADR-039 (P12) close it; then run with --strict.
 */
import { SQL } from "bun";
import { join } from "node:path";
import { User, tokenMinter, waitFor, type Jwk } from "./lib/clients";

const backendDir = join(import.meta.dir, "..");
const strict = Bun.argv.includes("--strict");
const dbName = process.env.TWO_NODE_DB ?? "syntila_twonode";
if (/^(syntila|syntila_prod|syntila_production)$/.test(dbName)) { console.error(`refusing to touch ${dbName}`); process.exit(2); }

const pg = {
  hostname: process.env.PGHOST ?? "127.0.0.1",
  port: Number(process.env.PGPORT ?? 5432),
  username: process.env.PGUSER ?? "syntila_app",
  password: process.env.PGPASSWORD ?? "devpass",
};
const PORTS = [Number(process.env.TWO_NODE_PORT_A ?? 3101), Number(process.env.TWO_NODE_PORT_B ?? 3102)] as const;
const ORIGIN = "https://syntila.app";

let failures = 0;
const known: string[] = [];
const check = (ok: unknown, label: string) => {
  if (ok) console.log(`ok   ${label}`);
  else { console.error(`FAIL ${label}`); failures++; }
};
const gap = (ok: unknown, label: string) => {
  if (ok) console.log(`ok   ${label}`);
  else if (strict) { console.error(`FAIL ${label}`); failures++; }
  else { console.log(`GAP  ${label} (known until ADR-038/039; --strict fails it)`); known.push(label); }
};

// Signing key for this run only.
const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
const kid = `two-node-${crypto.randomUUID().slice(0, 8)}`;
const publicJwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid, alg: "EdDSA", use: "sig" };
const privateJwk = { ...(await crypto.subtle.exportKey("jwk", pair.privateKey)), kid, alg: "EdDSA" } as Jwk;
const mint = tokenMinter(privateJwk);

const admin = new SQL({ ...pg, database: "postgres", max: 2 });
await admin.unsafe(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`);
await admin.unsafe(`CREATE DATABASE ${dbName}`);

const childEnv = (port: number): Record<string, string> => ({
  ...(process.env as Record<string, string>),
  PGHOST: pg.hostname, PGPORT: String(pg.port), PGUSER: pg.username, PGPASSWORD: pg.password, PGDATABASE: dbName,
  PORT: String(port), BIND_HOST: "127.0.0.1",
  AUTH_JWT_PUBLIC_KEYS: JSON.stringify([publicJwk]),
  ALLOWED_ORIGINS: ORIGIN,
  SYNTILA_ENVIRONMENT: "test",
  SYNTILA_RATE_LIMIT_PER_MINUTE: "0", SYNTILA_MUTATION_RATE_LIMIT_PER_MINUTE: "0",
});
const children: Bun.Subprocess[] = [];
async function cleanup() {
  for (const child of children) child.kill();
  await Promise.all(children.map((c) => c.exited.catch(() => {})));
  await admin.unsafe(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`).catch(() => {});
  await admin.close();
}
process.on("SIGINT", () => { void cleanup().then(() => process.exit(130)); });

try {
  const migrate = Bun.spawn(["bun", "src/migrate.ts"], { cwd: backendDir, env: childEnv(PORTS[0]), stdout: "inherit", stderr: "inherit" });
  if ((await migrate.exited) !== 0) throw new Error("migrations failed");

  for (const port of PORTS) {
    children.push(Bun.spawn(["bun", "src/server.ts"], { cwd: backendDir, env: childEnv(port), stdout: "ignore", stderr: "inherit" }));
  }
  const bases = PORTS.map((p) => `http://127.0.0.1:${p}`);
  const ready = await Promise.all(bases.map((b) => waitFor(`${b} ready`, async () => (await fetch(`${b}/health/ready`).catch(() => null))?.ok, 30_000).then(() => true, () => false)));
  check(ready.every(Boolean), "both nodes are ready on one database");
  if (!ready.every(Boolean)) throw new Error("a node did not start");

  const token = await mint(`two-node-${Date.now().toString(36)}`);
  const [a, b] = bases.map((base) => new User(base, token)) as [User, User];

  // 2. Created on A, read on B.
  const { spaceId, threadId } = await a.spaceWithThread("Two node");
  const spacesOnB = await b.api("GET", "/api/spaces");
  check(JSON.stringify(spacesOnB.body).includes(spaceId), "a Space created on node A is visible on node B");

  // 3. Idempotency across nodes.
  const key = `two-node-${crypto.randomUUID()}`;
  const first = await a.api("POST", `/api/threads/${threadId}/discussion-messages`, { body: "once" }, { "idempotency-key": key });
  const replay = await b.api("POST", `/api/threads/${threadId}/discussion-messages`, { body: "once" }, { "idempotency-key": key });
  check(first.status < 300 && replay.status === first.status && JSON.stringify(replay.body) === JSON.stringify(first.body),
    "an Idempotency-Key replayed on the other node returns the first response");
  const listed = await b.api("GET", `/api/threads/${threadId}/discussion-messages`);
  check(JSON.stringify(listed.body).split('"once"').length - 1 === 1, "the replayed request created exactly one message");

  // 4. Concurrent writes from both nodes, then the invariants.
  const posts = await Promise.all(Array.from({ length: 40 }, (_, i) =>
    (i % 2 ? a : b).api("POST", `/api/threads/${threadId}/discussion-messages`, { body: `m${i}` })));
  check(posts.every((p) => p.status < 300), `40 concurrent posts alternating between nodes all succeed (${posts.filter((p) => p.status >= 300).map((p) => p.status).join(",") || "no errors"})`);
  const db = new SQL({ ...pg, database: dbName, max: 2 });
  const rows: { invariant: string; violations: number | bigint }[] =
    await db.unsafe(await Bun.file(join(import.meta.dir, "check-invariants.sql")).text());
  const broken = rows.filter((r) => Number(r.violations) !== 0);
  check(broken.length === 0, `data invariants hold after cross-node writes${broken.length ? `: ${broken.map((r) => r.invariant).join("; ")}` : ""}`);
  await db.close();

  // Known gap: realtime across nodes.
  const live = a.realtime([spaceId]);
  await live.waitFor("subscription on node A", (f) => f.type === "subscription.ready", 15_000);
  await b.api("POST", `/api/threads/${threadId}/discussion-messages`, { body: "across" });
  const crossed = await waitFor("event from node B", () => live.state.frames.find((f) => JSON.stringify(f).includes("across")), 4_000).then(() => true, () => false);
  live.close();
  gap(crossed, "a message posted on node B reaches a realtime socket on node A");

  // 5. Kill node A while posts are in flight (always last: it needs node A alive before).
  const db2 = new SQL({ ...pg, database: dbName, max: 2 });
  const burst = Promise.allSettled(Array.from({ length: 30 }, (_, i) =>
    a.api("POST", `/api/threads/${threadId}/discussion-messages`, { body: `kill${i}` })));
  await Bun.sleep(150);
  children[0]!.kill("SIGKILL");
  await burst;
  const orphans = await db2.unsafe(`SELECT count(*)::int AS n FROM realtime_events e
                                     WHERE NOT EXISTS (SELECT 1 FROM outbox o WHERE o.event_id = e.event_id)`);
  check(Number(orphans[0].n) === 0, "after killing node A mid-write, every committed event has its outbox row");
  const drained = await waitFor("outbox drained by node B", async () =>
    Number((await db2.unsafe(`SELECT count(*)::int AS n FROM outbox WHERE status = 'pending'`))[0].n) === 0, 45_000)
    .then(() => true, () => false);
  check(drained, "the surviving node's dispatcher delivers what the killed node left pending");
  const rows2: { invariant: string; violations: number | bigint }[] =
    await db2.unsafe(await Bun.file(join(import.meta.dir, "check-invariants.sql")).text());
  const broken2 = rows2.filter((r) => Number(r.violations) !== 0);
  check(broken2.length === 0, `data invariants hold after killing a node${broken2.length ? `: ${broken2.map((r) => r.invariant).join("; ")}` : ""}`);
  await db2.close();
} catch (error) {
  console.error(`FAIL ${(error as Error).message}`);
  failures++;
} finally {
  await cleanup();
}
console.log(`\n${failures ? "FAILED" : "PASSED"}: ${failures} failure(s), ${known.length} known gap(s)`);
process.exit(failures ? 1 : 0);
