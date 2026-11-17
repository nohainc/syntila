import { expect, test } from "bun:test";
import { createDb } from "../src/db";

const url = new URL(process.env.TEST_DATABASE_URL ?? "postgres://syntila_app:devpass@127.0.0.1:5432/postgres");
const config = (extra: object = {}) => ({
  hostname: url.hostname, port: Number(url.port || 5432), username: decodeURIComponent(url.username),
  database: url.pathname.slice(1), password: decodeURIComponent(url.password), max: 4, ...extra,
});
const show = async (db: Awaited<ReturnType<typeof createDb>>, name: string) => (await db.unsafe(`SHOW ${name}`))[0][name] as string;

test("the API's sessions carry the lock-wait and idle-in-transaction limits; the migration runner's do not", async () => {
  const api = createDb(config());
  const migrate = createDb(config(), "syntila-migrate", false);
  try {
    expect(await show(api, "lock_timeout")).toBe("10s");
    expect(await show(api, "idle_in_transaction_session_timeout")).toBe("30s");
    expect(await show(api, "statement_timeout")).toBe("15s");
    expect(await show(migrate, "lock_timeout")).toBe("0");
    expect(await show(migrate, "idle_in_transaction_session_timeout")).toBe("0");
  } finally { await api.close(); await migrate.close(); }
});

test("a session left idle inside a transaction is terminated and its lock is released", async () => {
  const db = createDb(config({ idleInTransactionMs: 1_000, lockTimeoutMs: 5_000 }));
  try {
    const stuck = await db.reserve();
    await stuck.unsafe("BEGIN");
    await stuck.unsafe("SELECT pg_advisory_xact_lock(424242)");
    // Another session can not take the lock while the first holds it...
    const other = await db.reserve();
    expect((await other.unsafe("SELECT pg_try_advisory_lock(424242) AS ok"))[0].ok).toBe(false);
    // ...but once the idle limit passes, PostgreSQL ends the stuck session.
    await Bun.sleep(1_800);
    expect((await other.unsafe("SELECT pg_try_advisory_lock(424242) AS ok"))[0].ok).toBe(true);
    await other.unsafe("SELECT pg_advisory_unlock(424242)");
    other.release();
    await stuck.unsafe("SELECT 1").then(() => { throw new Error("stuck session should be gone"); }, () => undefined);
  } finally { await db.close(); }
});

test("a statement waiting for a lock gives up after the lock-wait limit", async () => {
  const db = createDb(config({ lockTimeoutMs: 300 }));
  try {
    const holder = await db.reserve();
    await holder.unsafe("BEGIN");
    await holder.unsafe("SELECT pg_advisory_xact_lock(424243)");
    const waiter = await db.reserve();
    await waiter.unsafe("BEGIN");
    const started = performance.now();
    await expect(waiter.unsafe("SELECT pg_advisory_xact_lock(424243)")).rejects.toMatchObject({ errno: "55P03" });
    expect(performance.now() - started).toBeLessThan(2_000);
    await waiter.unsafe("ROLLBACK").catch(() => undefined);
    await holder.unsafe("ROLLBACK");
    waiter.release(); holder.release();
  } finally { await db.close(); }
});
