import { describe, expect, test } from "bun:test";
import { PgD1Error, translatePlaceholders } from "./domain/helpers/fixture-sql";
import { pgD1 } from "./domain/helpers/pg-d1";

/** The fixture bridge's SQL and value conventions (test-only; the application never uses them). */
describe("placeholder translation", () => {
  test("numbered, bare, and ignored inside literals and comments", () => {
    expect(translatePlaceholders("SELECT * FROM t WHERE a = ?1 AND b = ?2 OR c = ?1")).toBe("SELECT * FROM t WHERE a = $1 AND b = $2 OR c = $1");
    expect(translatePlaceholders("INSERT INTO t VALUES (?, ?, '?', \"x?\") -- ?\n")).toBe("INSERT INTO t VALUES ($1, $2, '?', \"x?\") \n");
    expect(translatePlaceholders("SELECT 'it''s ?' , ?")).toBe("SELECT 'it''s ?' , $1");
  });
  test("camelCase aliases keep their case; snake_case and keywords are untouched", () => {
    expect(translatePlaceholders("SELECT w.id AS runtimeId, w.worker_id AS executionWorkerId FROM t w ORDER BY runtimeId"))
      .toBe('SELECT w.id AS "runtimeId", w.worker_id AS "executionWorkerId" FROM t w ORDER BY "runtimeId"');
    expect(translatePlaceholders("SELECT COUNT(*) AS n, 'camelCase' AS label, jsonb_build_object('aB', 1)")).toBe("SELECT COUNT(*) AS n, 'camelCase' AS label, jsonb_build_object('aB', 1)");
  });
});

describe("values through the synchronous bridge", async () => {
  const { sqlite } = await pgD1();
  await sqlite.exec(`CREATE TABLE fx (id text PRIMARY KEY, n bigint NOT NULL DEFAULT 0, flag boolean NOT NULL DEFAULT false,
    at timestamptz, doc jsonb, parent text REFERENCES fx(id))`);

  test("bigint, boolean and timestamp come back as number, 1/0 and ISO text", async () => {
    await sqlite.prepare("INSERT INTO fx (id, n, flag, at) VALUES (?1, ?2, ?3, ?4)").run("a", 42, true, "2026-01-02T03:04:05.678Z");
    expect(await sqlite.prepare("SELECT n, flag, at FROM fx WHERE id = ?").get("a")).toEqual({ n: 42, flag: 1, at: "2026-01-02T03:04:05.678Z" });
    expect(await sqlite.prepare("SELECT * FROM fx WHERE id = ?").get("missing")).toBeUndefined();
  });

  test("JSON text bound to a jsonb column is stored as the document and read back as text", async () => {
    await sqlite.prepare("INSERT INTO fx (id, doc) VALUES (?1, ?2)").run("j", '{"a":"x"}');
    expect(await sqlite.prepare("SELECT doc ->> 'a' AS a, jsonb_typeof(doc) AS t FROM fx WHERE id = ?").get("j")).toEqual({ a: "x", t: "object" });
    expect(JSON.parse(((await sqlite.prepare("SELECT doc FROM fx WHERE id = ?").get("j")) as { doc: string }).doc)).toEqual({ a: "x" });
    await expect(sqlite.prepare("INSERT INTO fx (id, doc) VALUES (?1, ?2)").run("bad", "{nope")).rejects.toThrow();
  });

  test("camelCase aliases come back in their original case", async () => {
    expect(await sqlite.prepare("SELECT n AS rowCount FROM fx WHERE id = ?").get("a")).toEqual({ rowCount: 42 });
  });

  test("constraint failures carry a readable prefix and the PostgreSQL fields", async () => {
    const failure = async (fn: () => Promise<unknown>) => { try { await fn(); } catch (e) { return e as PgD1Error; } throw new Error("expected a failure"); };
    expect((await failure(() => sqlite.prepare("INSERT INTO fx (id) VALUES (?)").run("a"))).message).toContain("UNIQUE constraint failed");
    expect((await failure(() => sqlite.prepare("INSERT INTO fx (id, parent) VALUES (?, ?)").run("c", "nope"))).message).toContain("FOREIGN KEY constraint failed");
    expect((await failure(() => sqlite.prepare("INSERT INTO fx (id, n) VALUES (?, ?)").run("d", null))).message).toContain("NOT NULL constraint failed");
    expect((await failure(() => sqlite.prepare("INSERT INTO fx (id) VALUES (?)").run("a"))).code).toBe("23505");
  });
});
