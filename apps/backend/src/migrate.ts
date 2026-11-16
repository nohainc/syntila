import { readdir } from "node:fs/promises";
import { join } from "node:path";
import { loadConfig } from "./config";
import { createDb, type Db } from "./db";
import { schemaLock, verifySchemaLock } from "./schema-lock";

const MIGRATIONS_DIR = join(import.meta.dir, "..", "migrations");
const LOCK_KEY = 7_331_001; // arbitrary, stable advisory-lock key
const MIGRATION_NAME = /^\d{4}_[a-z0-9_]+\.sql$/;
/** First-line marker of a migration that must run outside a transaction. */
const NO_TRANSACTION = /^--\s*migrate:no-transaction\b/;

export interface MigrationResult { applied: string[]; current: string[] }
export interface MigrateOptions {
  /** How long one DDL statement may wait for a lock before failing (default 10s). */
  lockTimeout?: string;
  /** Upper bound for one migration statement (default 30min; "0" disables). */
  statementTimeout?: string;
}

/**
 * The one definition of "a migration file". Any other `.sql` file in the
 * directory is a mistake (it would never be applied), so it is an error.
 */
export async function migrationFiles(dir = MIGRATIONS_DIR): Promise<string[]> {
  const sql = (await readdir(dir)).filter((f) => f.endsWith(".sql")).sort();
  const invalid = sql.filter((f) => !MIGRATION_NAME.test(f));
  if (invalid.length) throw new Error(`Migration file names must match NNNN_snake_case.sql: ${invalid.join(", ")}`);
  const numbers = sql.map((f) => f.slice(0, 4));
  const duplicate = numbers.find((n, i) => numbers.indexOf(n) !== i);
  if (duplicate) throw new Error(`Two migrations share the number ${duplicate}`);
  return sql;
}

/**
 * Splits a no-transaction migration into statements. Such files hold simple
 * DDL (one statement per `;` at end of line); function bodies and other
 * text containing semicolons belong in ordinary transactional migrations.
 */
export function splitStatements(text: string): string[] {
  if (/\$\$|\$[a-z_]+\$/i.test(text)) throw new Error("no-transaction migrations cannot contain dollar-quoted bodies");
  return text
    .split("\n").filter((line) => !line.trim().startsWith("--")).join("\n")
    .split(/;\s*(?:\n|$)/).map((s) => s.trim()).filter(Boolean);
}

/**
 * Applies pending forward-only migrations under a session advisory lock so
 * concurrent starts cannot race. Applied files are checksummed; editing an
 * applied migration is an error.
 *
 * Each migration runs in its own transaction, except files whose first line
 * is `-- migrate:no-transaction`: those run statement by statement (needed
 * for `CREATE INDEX CONCURRENTLY`) and must therefore be idempotent
 * (`IF NOT EXISTS`). Invalid indexes left by an interrupted concurrent build
 * are dropped before such a file is retried.
 */
export async function migrate(db: Db, dir = MIGRATIONS_DIR, options: MigrateOptions = {}): Promise<MigrationResult> {
  const files = await migrationFiles(dir);
  const reserved = await db.reserve();
  try {
    await reserved`SELECT pg_advisory_lock(${LOCK_KEY})`;
    await reserved.unsafe(`SET lock_timeout = '${timeout(options.lockTimeout ?? process.env.MIGRATION_LOCK_TIMEOUT ?? "10s")}'`);
    await reserved.unsafe(`SET statement_timeout = '${timeout(options.statementTimeout ?? process.env.MIGRATION_STATEMENT_TIMEOUT ?? "30min")}'`);
    await reserved`CREATE TABLE IF NOT EXISTS schema_migrations (
      version text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())`;
    const rows: { version: string; checksum: string }[] =
      await reserved`SELECT version, checksum FROM schema_migrations`;
    const known = new Map(rows.map((r) => [r.version, r.checksum]));
    const unknown = [...known.keys()].filter((v) => !files.includes(v));
    // Expected after a code rollback: migrations are written so the previous
    // release still works on the newer schema (see migrations/README.md).
    if (unknown.length) console.warn(`Database is ahead of this release by: ${unknown.join(", ")}`);
    const applied: string[] = [];
    for (const file of files) {
      const text = await Bun.file(join(dir, file)).text();
      const checksum = new Bun.CryptoHasher("sha256").update(text).digest("hex");
      const previous = known.get(file);
      if (previous) {
        if (previous !== checksum) throw new Error(`Applied migration ${file} was modified`);
        continue;
      }
      if (NO_TRANSACTION.test(text)) {
        await dropInvalidIndexes(reserved);
        for (const statement of splitStatements(text)) await reserved.unsafe(statement);
        await reserved`INSERT INTO schema_migrations (version, checksum) VALUES (${file}, ${checksum})`;
      } else {
        await reserved.begin(async (tx) => {
          await tx.unsafe(text);
          await tx`INSERT INTO schema_migrations (version, checksum) VALUES (${file}, ${checksum})`;
        });
      }
      applied.push(file);
    }
    return { applied, current: files };
  } finally {
    await reserved`RESET lock_timeout`.catch(() => {});
    await reserved`RESET statement_timeout`.catch(() => {});
    await reserved`SELECT pg_advisory_unlock(${LOCK_KEY})`.catch(() => {});
    reserved.release();
  }
}

function timeout(value: string): string {
  if (!/^\d+\s*(ms|s|min|h)?$/.test(value)) throw new Error(`Invalid timeout: ${value}`);
  return value;
}

/** An interrupted CREATE INDEX CONCURRENTLY leaves an unusable index behind. */
async function dropInvalidIndexes(conn: { unsafe: (sql: string) => Promise<any> }): Promise<void> {
  const rows: { name: string }[] = await conn.unsafe(
    `SELECT quote_ident(c.relname) AS name FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
     WHERE NOT i.indisvalid AND c.relnamespace = 'public'::regnamespace`);
  for (const row of rows) await conn.unsafe(`DROP INDEX CONCURRENTLY IF EXISTS ${row.name}`);
}

export async function pendingMigrations(db: Db, dir = MIGRATIONS_DIR): Promise<string[]> {
  const files = await migrationFiles(dir);
  const exists = await db`SELECT to_regclass('schema_migrations') IS NOT NULL AS ok`;
  if (!exists[0].ok) return files;
  const rows: { version: string }[] = await db`SELECT version FROM schema_migrations`;
  const done = new Set(rows.map((r) => r.version));
  return files.filter((f) => !done.has(f));
}

const USAGE = `Usage: migrate [--dry-run | --verify | --print-lock]
  (no flag)     apply pending migrations
  --dry-run     list pending migrations and exit (exit code 3 if any are pending)
  --verify      compare the live schema with migrations/schema.lock (exit code 4 on drift)
  --print-lock  print the live schema in schema.lock format`;

// `import.meta.main` alone is not enough: in the bundled server.js this
// module is part of the entry bundle, so it is true there as well. Only run
// the command line when the migrate script itself is what was started.
if (import.meta.main && /(^|[\\/])migrate\.(ts|js)$/.test(Bun.main)) {
  const flag = Bun.argv[2];
  if (flag && !["--dry-run", "--verify", "--print-lock"].includes(flag)) { console.error(USAGE); process.exit(2); }
  const config = await loadConfig();
  const db = createDb({ ...config.db, max: 2 }, "syntila-migrate", false);
  let exitCode = 0;
  try {
    // PostgreSQL may still be starting (boot, restart): wait up to 60 s.
    for (let attempt = 1; ; attempt++) {
      try { await db`SELECT 1`; break; } catch (e) {
        if (attempt >= 30) throw e;
        console.log(`PostgreSQL not reachable yet (attempt ${attempt}), retrying`);
        await Bun.sleep(2000);
      }
    }
    if (flag === "--dry-run") {
      const pending = await pendingMigrations(db);
      console.log(pending.length ? `Pending: ${pending.join(", ")}` : "Schema is up to date");
      if (pending.length) exitCode = 3;
    } else if (flag === "--print-lock") {
      process.stdout.write(await schemaLock(db));
    } else if (flag === "--verify") {
      const drift = await verifySchemaLock(db, join(MIGRATIONS_DIR, "schema.lock"));
      if (drift.length) { console.error(`Schema drift (${drift.length} lines):\n${drift.join("\n")}`); exitCode = 4; }
      else console.log("Schema matches migrations/schema.lock");
    } else {
      const result = await migrate(db);
      console.log(result.applied.length ? `Applied: ${result.applied.join(", ")}` : "Schema is up to date");
    }
  } finally {
    await db.close();
  }
  // Never process.exit() here: let the process end on its own.
  process.exitCode = exitCode;
}
