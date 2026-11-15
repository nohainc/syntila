import { describe, expect, test } from "bun:test";
import { Data, drainTxStats } from "../src/platform/data";
import { pgD1 } from "./domain/helpers/pg-d1";

const fresh = () => {
  const { sql } = pgD1({ max: 8 });
  return new Data(sql);
};

describe("data layer values", () => {
  test("rows come back as plain JS values", async () => {
    const data = fresh();
    const row = await data.read.row<Record<string, unknown>>`
      SELECT 7::int8 AS n, true AS b, '2026-01-02T03:04:05.678Z'::timestamptz AS at,
             ${{ b: 1, a: [1, "x"] }}::jsonb AS doc, NULL::text AS empty`;
    expect(row).toEqual({ n: 7, b: true, at: "2026-01-02T03:04:05.678Z", doc: { b: 1, a: [1, "x"] }, empty: null });
  });

  test("undefined parameters are rejected", async () => {
    const data = fresh();
    await expect(data.read.rows`SELECT ${undefined} AS x`).rejects.toThrow("undefined");
  });

  test("lists work for IN and multi-row inserts", async () => {
    const data = fresh();
    await data.read.run`CREATE TEMP TABLE IF NOT EXISTS t (id text, n int)`;
    const rows = [{ id: "a", n: 1 }, { id: "b", n: 2 }, { id: "c", n: 3 }];
    await data.tx("test.insert", async (tx) => {
      await tx.run`CREATE TEMP TABLE IF NOT EXISTS t2 (id text, n int)`;
      expect(await tx.run`INSERT INTO t2 ${tx.list(rows)}`).toBe(3);
      expect((await tx.rows<{ id: string }>`SELECT id FROM t2 WHERE id IN ${tx.list(["a", "c"])} ORDER BY id`).map((r) => r.id)).toEqual(["a", "c"]);
    });
  });
});

describe("data layer transactions", () => {
  test("commit runs afterCommit; rollback discards writes and afterCommit", async () => {
    const data = fresh();
    await data.read.run`CREATE TABLE IF NOT EXISTS tx_probe (id text PRIMARY KEY)`;
    const ran: string[] = [];
    await data.tx("test.commit", async (tx) => {
      await tx.run`INSERT INTO tx_probe VALUES ('ok')`;
      tx.afterCommit(() => ran.push("ok"));
    });
    await expect(data.tx("test.rollback", async (tx) => {
      await tx.run`INSERT INTO tx_probe VALUES ('no')`;
      tx.afterCommit(() => ran.push("no"));
      throw new Error("boom");
    })).rejects.toThrow("boom");
    expect(ran).toEqual(["ok"]);
    expect((await data.read.rows<{ id: string }>`SELECT id FROM tx_probe ORDER BY id`).map((r) => r.id)).toEqual(["ok"]);
  });

  test("a deadlock retries the whole transaction", async () => {
    const data = fresh();
    await data.read.run`CREATE TABLE IF NOT EXISTS dl (id int PRIMARY KEY, n int NOT NULL)`;
    await data.read.run`INSERT INTO dl VALUES (1, 0), (2, 0)`;
    drainTxStats();
    let bothIn!: () => void;
    let arrived = 0;
    const gate = new Promise<void>((r) => (bothIn = r));
    // Opposite lock order on the first attempt: PostgreSQL kills one with
    // a deadlock error; the retry then runs alone and succeeds.
    const run = (first: number, second: number, label: string) => data.tx(label, async (tx) => {
      await tx.run`UPDATE dl SET n = n + 1 WHERE id = ${first}`;
      if (++arrived <= 2) { if (arrived === 2) bothIn(); await gate; }
      await tx.run`UPDATE dl SET n = n + 1 WHERE id = ${second}`;
    });
    await Promise.all([run(1, 2, "test.dl.a"), run(2, 1, "test.dl.b")]);
    expect(await data.read.rows`SELECT id, n FROM dl ORDER BY id`).toEqual([{ id: 1, n: 2 }, { id: 2, n: 2 }]);
    const stats = drainTxStats().filter((s) => s.label.startsWith("test.dl"));
    expect(stats.reduce((sum, s) => sum + s.retries, 0)).toBeGreaterThanOrEqual(1);
    expect(stats.every((s) => s.failures === 0)).toBe(true);
  });

  test("tx.lock orders writers of one key and leaves other keys free", async () => {
    const data = fresh();
    let release!: () => void;
    const held = new Promise<void>((r) => (release = r));
    let inside!: () => void;
    const entered = new Promise<void>((r) => (inside = r));
    const holder = data.tx("test.lock.hold", async (tx) => { await tx.lock("test.scope", "A"); inside(); await held; });
    await entered;
    // A different key does not wait.
    await data.tx("test.lock.other", async (tx) => {
      await tx.run`SET LOCAL lock_timeout = '500ms'`;
      await tx.lock("test.scope", "B");
    });
    // The same key waits until the holder commits.
    await expect(data.tx("test.lock.same", async (tx) => {
      await tx.run`SET LOCAL lock_timeout = '300ms'`;
      await tx.lock("test.scope", "A");
    })).rejects.toThrow();
    release();
    await holder;
  });
});

describe("database health sample", () => {
  test("reports lock waits and transaction ages", async () => {
    const { sampleDbHealth } = await import("../src/platform/db-health");
    const { sql } = pgD1({ max: 6 });
    const data = new Data(sql);
    await data.read.run`CREATE TABLE IF NOT EXISTS hl (id int PRIMARY KEY)`;
    await data.read.run`INSERT INTO hl VALUES (1)`;
    let release!: () => void;
    const held = new Promise<void>((r) => (release = r));
    let inside!: () => void;
    const entered = new Promise<void>((r) => (inside = r));
    const holder = data.tx("test.health.hold", async (tx) => { await tx.run`UPDATE hl SET id = 1 WHERE id = 1`; inside(); await held; });
    await entered;
    const waiter = data.tx("test.health.wait", async (tx) => { await tx.run`UPDATE hl SET id = 1 WHERE id = 1`; });
    await Bun.sleep(300);
    const health = await sampleDbHealth(sql);
    release();
    await Promise.all([holder, waiter]);
    expect(health.lockWaiting).toBeGreaterThanOrEqual(1);
    expect(health.oldestTransactionMs).toBeGreaterThan(200);
    expect(health.deadlocks).toBe(0);
    expect(typeof health.connections).toBe("object");
  });
});

test("an unquoted camelCase result name is an error", async () => {
  const data = fresh();
  await expect(data.read.rows`SELECT 1 AS threadId`).rejects.toThrow('AS "threadId"');
  expect(() => data.read.raw("x AS spaceId")).toThrow('AS "spaceId"');
  expect(await data.read.row`SELECT 1 AS "threadId", 2 AS plain_name`).toEqual({ threadId: 1, plain_name: 2 });
});
