import { readdir } from "node:fs/promises";
import { join } from "node:path";
import { loadConfig } from "./config";
import { createDb, type Db } from "./db";

const MIGRATIONS_DIR = join(import.meta.dir, "..", "migrations");
const LOCK_KEY = 7_331_001; // arbitrary, stable advisory-lock key

export interface MigrationResult { applied: string[]; current: string[] }

/**
 * Applies pending forward-only migrations, each in its own transaction,
 * under a session advisory lock so concurrent starts cannot race.
 * Applied files are checksummed; editing an applied migration is an error.
 */
export async function migrate(db: Db, dir = MIGRATIONS_DIR): Promise<MigrationResult> {
  const files = (await readdir(dir)).filter((f) => /^\d{4}_[a-z0-9_]+\.sql$/.test(f)).sort();
  const reserved = await db.reserve();
  try {
    await reserved`SELECT pg_advisory_lock(${LOCK_KEY})`;
    await reserved`CREATE TABLE IF NOT EXISTS schema_migrations (
      version text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())`;
    const rows: { version: string; checksum: string }[] =
      await reserved`SELECT version, checksum FROM schema_migrations`;
    const known = new Map(rows.map((r) => [r.version, r.checksum]));
    const applied: string[] = [];
    for (const file of files) {
      const text = await Bun.file(join(dir, file)).text();
      const checksum = new Bun.CryptoHasher("sha256").update(text).digest("hex");
      const previous = known.get(file);
      if (previous) {
        if (previous !== checksum) throw new Error(`Applied migration ${file} was modified`);
        continue;
      }
      await reserved.begin(async (tx) => {
        await tx.unsafe(text);
        await tx`INSERT INTO schema_migrations (version, checksum) VALUES (${file}, ${checksum})`;
      });
      applied.push(file);
    }
    return { applied, current: files };
  } finally {
    await reserved`SELECT pg_advisory_unlock(${LOCK_KEY})`.catch(() => {});
    reserved.release();
  }
}

export async function pendingMigrations(db: Db, dir = MIGRATIONS_DIR): Promise<string[]> {
  const files = (await readdir(dir)).filter((f) => f.endsWith(".sql")).sort();
  const exists = await db`SELECT to_regclass('schema_migrations') IS NOT NULL AS ok`;
  if (!exists[0].ok) return files;
  const rows: { version: string }[] = await db`SELECT version FROM schema_migrations`;
  const done = new Set(rows.map((r) => r.version));
  return files.filter((f) => !done.has(f));
}

if (import.meta.main) {
  const config = await loadConfig();
  const db = createDb({ ...config.db, max: 1 }, "syntila-migrate");
  try {
    // PostgreSQL may still be starting (boot, restart): wait up to 60 s.
    for (let attempt = 1; ; attempt++) {
      try { await db`SELECT 1`; break; } catch (e) {
        if (attempt >= 30) throw e;
        console.log(`PostgreSQL not reachable yet (attempt ${attempt}), retrying`);
        await Bun.sleep(2000);
      }
    }
    const result = await migrate(db);
    console.log(result.applied.length ? `Applied: ${result.applied.join(", ")}` : "Schema is up to date");
  } finally {
    await db.close();
  }
}
