/**
 * Test database helper: every call returns a fresh PostgreSQL database cloned
 * from a template built from every file in apps/backend/migrations.
 *   const { db, sqlite } = pgD1();
 *   db     — the production holder (PgDb); `db.sql` is the pool
 *   sqlite — async fixture API: await exec(sql) / await prepare(sql).run|get|all(...)
 *   (pgD1 itself is async: `await pgD1()`)
 * Requires TEST_DATABASE_URL (role with CREATEDB), default local dev settings.
 */
import { SQL } from "bun";
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { dataOf } from "../../../src/platform/data";
import { PgDb } from "../../../src/platform/data";
import { FixtureDb } from "./fixture-db";

const BASE_URL = process.env.TEST_DATABASE_URL ?? "postgres://syntila_app:devpass@127.0.0.1:5432/postgres";
// Every migration in order, exactly as the deploy applies them.
const MIGRATIONS = new URL("../../../migrations/", import.meta.url);
const schema = readdirSync(MIGRATIONS).filter((f) => /^\d{4}_[a-z0-9_]+\.sql$/.test(f)).sort()
  .map((f) => readFileSync(new URL(f, MIGRATIONS), "utf8")).join("\n")
  // The template is built in one implicit transaction; a plain index build
  // produces the same schema as the CONCURRENTLY one used in production.
  .replace(/\bCONCURRENTLY /g, "");
const TEMPLATE = `syntila_tpl_${createHash("sha256").update(schema).digest("hex").slice(0, 12)}`;
const urlFor = (db: string) => { const u = new URL(BASE_URL); u.pathname = `/${db}`; return u.toString(); };

let adminPromise: Promise<FixtureDb> | null = null;
const created: { name: string; fixtures: FixtureDb; sql: InstanceType<typeof SQL>; closed?: boolean }[] = [];
const LIVE_LIMIT = 12;

async function dropStale(a: FixtureDb) {
  // Only databases of test processes that are no longer running.
  const rows = (await a.prepare("SELECT datname FROM pg_database WHERE datname LIKE 'syntila\\_t\\_%'").all()) as { datname: string }[];
  for (const { datname } of rows) {
    const pid = Number(datname.split("_")[2]);
    let alive = false;
    try { process.kill(pid, 0); alive = true; } catch {}
    if (!alive) { try { await a.exec(`DROP DATABASE IF EXISTS ${datname} WITH (FORCE)`); } catch {} }
  }
}

// One admin connection per process; template built once, also across
// concurrent pgD1() calls.
const adminDb = () => (adminPromise ??= (async () => {
  const a = new FixtureDb(BASE_URL);
  await dropStale(a);
  await ensureTemplate(a);
  return a;
})());

async function ensureTemplate(a: FixtureDb) {
  // Parallel test processes: build the template once, under a lock, under a
  // temporary name, then rename it so nobody clones a half-built database.
  await a.exec("SELECT pg_advisory_lock(7331002)");
  try {
    if (!(await a.prepare("SELECT 1 FROM pg_database WHERE datname = ?").get(TEMPLATE))) {
      const building = `${TEMPLATE}_building`;
      await a.exec(`DROP DATABASE IF EXISTS ${building} WITH (FORCE)`);
      await a.exec(`CREATE DATABASE ${building}`);
      const t = new FixtureDb(urlFor(building));
      try { await t.exec(schema); } finally { await t.close(); }
      await a.exec(`ALTER DATABASE ${building} RENAME TO ${TEMPLATE}`);
    }
  } finally {
    await a.exec("SELECT pg_advisory_unlock(7331002)");
  }
}

export interface PgD1TestOptions {
  /** Pool size (default 3); concurrency tests need real parallel connections. */
  max?: number;
}

export async function pgD1(options: PgD1TestOptions = {}) {
  const admin = await adminDb();
  const name = `syntila_t_${process.pid}_${created.length}_${Math.random().toString(36).slice(2, 8)}`;
  await admin.exec(`CREATE DATABASE ${name} TEMPLATE ${TEMPLATE}`);
  const sql = new SQL(urlFor(name), { bigint: true, max: options.max ?? 3, idleTimeout: 2 });
  const fixtures = new FixtureDb(urlFor(name));
  created.push({ name, fixtures, sql });
  // Keep connection usage bounded: databases from earlier tests are closed
  // (not dropped) once more than LIVE_LIMIT exist; they are dropped at exit.
  const live = created.filter((c) => !c.closed);
  for (const old of live.slice(0, Math.max(0, live.length - LIVE_LIMIT))) {
    old.closed = true; void old.fixtures.close(); void old.sql.close({ timeout: 0 }).catch(() => {});
  }
  const db = new PgDb(sql as never);
  return { db, read: dataOf({ SYNTILA_DB: db }).read, sqlite: fixtures, sql, url: urlFor(name) };
}

/**
 * Wraps a test database so the statements it runs (also inside transactions)
 * are recorded as text, with each value shown as `?`. Use the returned `db` as
 * `SYNTILA_DB`; reads and writes still reach the real database.
 */
export function recordStatements(db: unknown): { db: any; statements: string[] } {
  const statements: string[] = [];
  const wrap = (target: any): any =>
    new Proxy(target, {
      apply(t, thisArg, args) {
        if (Array.isArray(args[0])) statements.push((args[0] as string[]).join("?"));
        return Reflect.apply(t, thisArg, args);
      },
      get(t, prop, receiver) {
        if (prop === "begin") return (fn: (conn: unknown) => unknown) => t.begin((conn: unknown) => fn(wrap(conn)));
        return Reflect.get(t, prop, receiver);
      },
    });
  return { db: Object.create(db as object, { sql: { value: wrap((db as any).sql) } }), statements };
}

/** Drops databases created by this process (call from afterAll or rely on exit hook). */
export async function dropTestDatabases() {
  while (created.length) {
    const c = created.pop()!;
    if (!c.closed) { await c.fixtures.close(); await c.sql.close().catch(() => {}); }
    await (await adminPromise)?.exec(`DROP DATABASE IF EXISTS ${c.name} WITH (FORCE)`);
  }
}
process.on("beforeExit", () => { void dropTestDatabases(); });
