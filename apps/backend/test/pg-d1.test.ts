import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { SQL } from "bun";
import { PgD1Database, PgD1Error, translatePlaceholders } from "../src/platform/pg-d1";
import { pgD1 } from "./domain/helpers/pg-d1";

let sql: InstanceType<typeof SQL>;
let db: PgD1Database;
beforeAll(async () => {
  sql = pgD1().sql;
  db = new PgD1Database(sql);
  await sql.unsafe(`DROP TABLE IF EXISTS d1t_child, d1t;
    CREATE TABLE d1t (id text PRIMARY KEY, n bigint NOT NULL DEFAULT 0, flag smallint NOT NULL DEFAULT 0 CHECK (flag IN (0,1)),
      at timestamptz, body text, data bytea);
    CREATE TABLE d1t_child (id text PRIMARY KEY, parent_id text NOT NULL REFERENCES d1t(id));`);
});
afterAll(async () => { await sql.unsafe("DROP TABLE IF EXISTS d1t_child, d1t"); });

describe("placeholder translation", () => {
  test("numbered, bare, and ignored inside literals and comments", () => {
    expect(translatePlaceholders("SELECT * FROM t WHERE a = ?1 AND b = ?2 OR c = ?1")).toBe("SELECT * FROM t WHERE a = $1 AND b = $2 OR c = $1");
    expect(translatePlaceholders("INSERT INTO t VALUES (?, ?, '?', \"x?\") -- ?\n")).toBe("INSERT INTO t VALUES ($1, $2, '?', \"x?\") \n");
    expect(translatePlaceholders("SELECT 'it''s ?' , ?")).toBe("SELECT 'it''s ?' , $1");
  });
  test("camelCase aliases keep their case; snake_case and keywords are untouched", () => {
    expect(translatePlaceholders("SELECT w.id AS runtimeId, w.workspace_id AS executionWorkspaceId FROM t w ORDER BY runtimeId"))
      .toBe('SELECT w.id AS "runtimeId", w.workspace_id AS "executionWorkspaceId" FROM t w ORDER BY "runtimeId"');
    expect(translatePlaceholders("SELECT COUNT(*) AS n, 'camelCase' AS label, jsonb_build_object('aB', 1)")).toBe("SELECT COUNT(*) AS n, 'camelCase' AS label, jsonb_build_object('aB', 1)");
  });
});

describe("D1 API on PostgreSQL", () => {
  test("run/first/all with type normalisation", async () => {
    const r = await db.prepare("INSERT INTO d1t (id, n, flag, at, body) VALUES (?1, ?2, ?3, ?4, ?5)").bind("a", 42, true, "2026-01-02T03:04:05.678Z", "x").run();
    expect(r.meta.changes).toBe(1);
    const row = await db.prepare("SELECT * FROM d1t WHERE id = ?").bind("a").first<any>();
    expect(row).toMatchObject({ id: "a", n: 42, flag: 1, at: "2026-01-02T03:04:05.678Z", body: "x" });
    expect(await db.prepare("SELECT count(*) AS c FROM d1t").first("c")).toBe(1);
    expect(await db.prepare("SELECT * FROM d1t WHERE id = ?").bind("missing").first()).toBeNull();
    const all = await db.prepare("SELECT id FROM d1t WHERE at > ?1").bind("2025-12-31T00:00:00.000Z").all<{ id: string }>();
    expect(all.results).toEqual([{ id: "a" }]);
    expect(await db.prepare("SELECT id, n FROM d1t").raw()).toEqual([["a", 42]]);
    const upd = await db.prepare("UPDATE d1t SET n = n + 1 WHERE id = ?1 RETURNING n").bind("a").all<{ n: number }>();
    expect(upd.results[0]!.n).toBe(43);
    expect(upd.meta.changes).toBe(1);
  });

  test("JSON text bound to a jsonb cast is parsed once", async () => {
    const r = await db.prepare("SELECT jsonb_typeof(?1::jsonb) AS t, (?1::jsonb ->> 'a') AS a").bind('{"a":"x"}').first<any>();
    expect(r).toEqual({ t: "object", a: "x" });
  });

  test("undefined bindings are rejected like D1", () => {
    expect(() => db.prepare("SELECT ?").bind(undefined)).toThrow(/undefined/);
  });

  test("batch is atomic", async () => {
    await expect(db.batch([
      db.prepare("INSERT INTO d1t (id) VALUES (?)").bind("b"),
      db.prepare("INSERT INTO d1t_child (id, parent_id) VALUES (?, ?)").bind("c1", "nope"),
    ])).rejects.toBeInstanceOf(PgD1Error);
    expect(await db.prepare("SELECT id FROM d1t WHERE id = 'b'").first()).toBeNull();
    const res = await db.batch([
      db.prepare("INSERT INTO d1t (id) VALUES (?)").bind("b"),
      db.prepare("INSERT INTO d1t_child (id, parent_id) VALUES (?, ?)").bind("c1", "b"),
      db.prepare("SELECT count(*) AS c FROM d1t_child"),
    ]);
    expect(res.map((r) => r.meta.changes)).toEqual([1, 1, 0]);
    expect(res[2]!.results[0]).toEqual({ c: 1 });
  });

  test("constraint errors carry D1-style messages and PostgreSQL details", async () => {
    const dup = await db.prepare("INSERT INTO d1t (id) VALUES ('a')").run().catch((e) => e);
    expect(dup).toBeInstanceOf(PgD1Error);
    expect(dup.message).toStartWith("UNIQUE constraint failed: d1t_pkey");
    expect(dup.code).toBe("23505");
    const chk = await db.prepare("UPDATE d1t SET flag = 5 WHERE id = 'a'").run().catch((e) => e);
    expect(chk.message).toStartWith("CHECK constraint failed");
  });

  test("concurrent read-modify-write statements serialise like D1 (no lost updates, retries succeed)", async () => {
    await db.prepare("INSERT INTO d1t (id, n) VALUES ('ctr', 0)").run();
    // Conditional increment that relies on single-writer semantics.
    await Promise.all(Array.from({ length: 40 }, () =>
      db.prepare("UPDATE d1t SET n = (SELECT n FROM d1t WHERE id = 'ctr') + 1 WHERE id = 'ctr'").run()));
    expect(await db.prepare("SELECT n FROM d1t WHERE id = 'ctr'").first("n")).toBe(40);
  });

  test("bytea round trip", async () => {
    const bytes = new Uint8Array([1, 2, 3]).buffer;
    await db.prepare("UPDATE d1t SET data = ? WHERE id = 'a'").bind(bytes).run();
    const got = await db.prepare("SELECT data FROM d1t WHERE id = 'a'").first<ArrayBuffer>("data");
    expect(new Uint8Array(got!)).toEqual(new Uint8Array([1, 2, 3]));
  });
});
