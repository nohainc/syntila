/**
 * Test database helper: every call returns a fresh PostgreSQL database cloned
 * from a template built from apps/backend/schema/0001_initial.sql.
 *   const { db, sqlite } = pgD1();
 *   db     — D1-compatible async API (production adapter)
 *   sqlite — synchronous fixture API: exec(sql) / prepare(sql).run|get|all(...)
 * Requires TEST_DATABASE_URL (role with CREATEDB), default local dev settings.
 */
import { SQL } from "bun";
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { PgD1Database } from "../../../src/platform/pg-d1";
import { SyncPostgres } from "./pg-sync";

const BASE_URL = process.env.TEST_DATABASE_URL ?? "postgres://syntila_app:devpass@127.0.0.1:5432/postgres";
// Every migration in order, exactly as the deploy applies them.
const MIGRATIONS = new URL("../../../migrations/", import.meta.url);
const schema = readdirSync(MIGRATIONS).filter((f) => /^\d{4}_[a-z0-9_]+\.sql$/.test(f)).sort()
  .map((f) => readFileSync(new URL(f, MIGRATIONS), "utf8")).join("\n");
const TEMPLATE = `syntila_tpl_${createHash("sha256").update(schema).digest("hex").slice(0, 12)}`;
const urlFor = (db: string) => { const u = new URL(BASE_URL); u.pathname = `/${db}`; return u.toString(); };

let admin: SyncPostgres | null = null;
const created: { name: string; sync: SyncPostgres; sql: InstanceType<typeof SQL>; closed?: boolean }[] = [];
const LIVE_LIMIT = 12;

function dropStale(a: SyncPostgres) {
  // Only databases of test processes that are no longer running.
  const rows = a.prepare("SELECT datname FROM pg_database WHERE datname LIKE 'syntila\\_t\\_%'").all() as { datname: string }[];
  for (const { datname } of rows) {
    const pid = Number(datname.split("_")[2]);
    let alive = false;
    try { process.kill(pid, 0); alive = true; } catch {}
    if (!alive) { try { a.exec(`DROP DATABASE IF EXISTS ${datname} WITH (FORCE)`); } catch {} }
  }
}

let templateReady = false;
function ensureTemplate(a: SyncPostgres) {
  if (templateReady) return;
  // Parallel test processes: build the template once, under a lock, under a
  // temporary name, then rename it so nobody clones a half-built database.
  a.exec("SELECT pg_advisory_lock(7331002)");
  try {
    if (!a.prepare("SELECT 1 FROM pg_database WHERE datname = ?").get(TEMPLATE)) {
      const building = `${TEMPLATE}_building`;
      a.exec(`DROP DATABASE IF EXISTS ${building} WITH (FORCE)`);
      a.exec(`CREATE DATABASE ${building}`);
      const t = new SyncPostgres(urlFor(building));
      try { t.exec(schema); } finally { t.close(); }
      a.exec(`ALTER DATABASE ${building} RENAME TO ${TEMPLATE}`);
    }
    templateReady = true;
  } finally {
    a.exec("SELECT pg_advisory_unlock(7331002)");
  }
}

export function pgD1() {
  if (!admin) { admin = new SyncPostgres(BASE_URL); dropStale(admin); }
  ensureTemplate(admin);
  const name = `syntila_t_${process.pid}_${created.length}_${Math.random().toString(36).slice(2, 8)}`;
  admin.exec(`CREATE DATABASE ${name} TEMPLATE ${TEMPLATE}`);
  const sql = new SQL(urlFor(name), { bigint: true, max: 3, idleTimeout: 2 });
  const sync = new SyncPostgres(urlFor(name));
  created.push({ name, sync, sql });
  // Keep connection usage bounded: databases from earlier tests are closed
  // (not dropped) once more than LIVE_LIMIT exist; they are dropped at exit.
  const live = created.filter((c) => !c.closed);
  for (const old of live.slice(0, Math.max(0, live.length - LIVE_LIMIT))) {
    old.closed = true; old.sync.close(); void old.sql.close({ timeout: 0 }).catch(() => {});
  }
  return { db: new PgD1Database(sql) as unknown as D1Database, sqlite: sync, sql };
}

/** Drops databases created by this process (call from afterAll or rely on exit hook). */
export async function dropTestDatabases() {
  while (created.length) {
    const c = created.pop()!;
    if (!c.closed) { c.sync.close(); await c.sql.close().catch(() => {}); }
    admin?.exec(`DROP DATABASE IF EXISTS ${c.name} WITH (FORCE)`);
  }
}
process.on("beforeExit", () => { void dropTestDatabases(); });
