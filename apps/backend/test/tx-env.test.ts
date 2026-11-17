import { describe, expect, test } from "bun:test";
import { pgD1 } from "./domain/helpers/pg-d1";
import { inTransaction } from "../src/platform/tx-env";
import { dataOf } from "../src/platform/data";
import { createEventPublisher } from "../src/domain/event-publisher";

function fixture() {
  const { db, sql, sqlite } = pgD1({ max: 6 });
  sqlite.exec(`
    INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES ('u', 'u@t', 'u', now(), now());
    INSERT INTO spaces (id, owner_user_id, name, created_at, updated_at) VALUES ('S', 'u', 'S', now(), now());
    INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at) VALUES ('m', 'S', 'u', 'owner', now(), now());`);
  const delivered: string[] = [];
  const gateway = {
    getByName: (name: string) => ({
      fetch: async (r: Request) => {
        delivered.push(
          `${name}:${((await r.json()) as { type: string }).type}`,
        );
        return new Response("ok");
      },
    }),
  };
  const env = { SYNTILA_DB: db, SYNTILA_REALTIME_GATEWAY: gateway } as any;
  return { env, sql, sqlite, delivered };
}

const publish = (env: any, mutate?: (tx: any) => Promise<unknown>) =>
  createEventPublisher(env).publish({
    type: "space.updated",
    spaceId: "S",
    stream: { kind: "space", id: "S" },
    payload: { entityId: "S" },
    mutate,
  });

describe("inTransaction", () => {
  test("adapter statements, data-layer queries and events commit together; fan-out waits for the commit", async () => {
    const { env, sql, delivered } = fixture();
    await inTransaction(env, "test.commit", async (txEnv, tx) => {
      await txEnv.SYNTILA_DB.prepare(
        "UPDATE spaces SET name = ?1 WHERE id = 'S'",
      )
        .bind("A")
        .run();
      // The data layer inside sees the adapter's uncommitted write.
      expect(
        (
          await dataOf(txEnv).read.row<{
            name: string;
          }>`SELECT name FROM spaces WHERE id = 'S'`
        )?.name,
      ).toBe("A");
      await publish(txEnv, (t) =>
        t.run`UPDATE spaces SET description = 'd' WHERE id = 'S'`,
      );
      // Nested inTransaction joins the open transaction.
      await inTransaction(txEnv, "test.nested", async (_e, inner) =>
        expect(inner).toBe(tx),
      );
      // Nothing is visible outside yet, and nobody was told.
      const [outside] = await sql`SELECT name FROM spaces WHERE id = 'S'`;
      expect(outside.name).toBe("S");
      expect(delivered).toEqual([]);
    });
    const [row] =
      await sql`SELECT name, description FROM spaces WHERE id = 'S'`;
    expect(row).toEqual({ name: "A", description: "d" });
    expect(
      Number((await sql`SELECT count(*) AS n FROM realtime_events`)[0].n),
    ).toBe(1);
    expect(delivered).toEqual(["user:u:space.updated"]);
  });

  test("a rollback keeps neither the writes nor the event, and nobody is told", async () => {
    const { env, sql, delivered } = fixture();
    await expect(
      inTransaction(env, "test.rollback", async (txEnv) => {
        await publish(txEnv, (t) =>
          t.run`UPDATE spaces SET name = 'B' WHERE id = 'S'`,
        );
        throw new Error("boom");
      }),
    ).rejects.toThrow("boom");
    const [row] = await sql`SELECT name FROM spaces WHERE id = 'S'`;
    expect(row.name).toBe("S");
    expect(
      Number((await sql`SELECT count(*) AS n FROM realtime_events`)[0].n),
    ).toBe(0);
    expect(delivered).toEqual([]);
  });

  test("statements inside never take the global writer lock", async () => {
    const { env, sql } = fixture();
    // Hold the global writer lock from another connection.
    const holder = await sql.reserve();
    await holder`BEGIN`;
    await holder.unsafe("SELECT pg_advisory_xact_lock($1)", [0x5359_4e57]);
    try {
      await inTransaction(env, "test.nolock", async (txEnv, tx) => {
        await tx.run`SET LOCAL lock_timeout = '500ms'`;
        await txEnv.SYNTILA_DB.batch([
          txEnv.SYNTILA_DB.prepare(
            "UPDATE spaces SET name = 'C' WHERE id = 'S'",
          ),
          txEnv.SYNTILA_DB.prepare(
            "UPDATE spaces SET description = 'c' WHERE id = 'S'",
          ),
        ]);
      });
    } finally {
      await holder`ROLLBACK`;
      holder.release();
    }
    const [row] =
      await sql`SELECT name, description FROM spaces WHERE id = 'S'`;
    expect(row).toEqual({ name: "C", description: "c" });
  });
});

describe("adapter statements inside a transaction", () => {
  test("a statement the type probe cannot prepare still runs, and the transaction stays usable", async () => {
    const { env, sql } = fixture();
    await inTransaction(env, "test.probe", async (txEnv) => {
      // $1 is used as text and as a number: PREPARE fails with inconsistent types.
      const row = await txEnv.SYNTILA_DB.prepare("SELECT ?1::text AS a, length(?1::text) AS b")
        .bind("abc")
        .first<{ a: string; b: number }>();
      expect(row).toEqual({ a: "abc", b: 3 });
      await txEnv.SYNTILA_DB.prepare("UPDATE spaces SET name = 'P' WHERE id = 'S'").run();
    });
    const [row] = await sql`SELECT name FROM spaces WHERE id = 'S'`;
    expect(row.name).toBe("P");
  });

  test("many parallel transactions on a small pool do not starve each other", async () => {
    const { db } = pgD1({ max: 2 });
    const env = { SYNTILA_DB: db } as any;
    const results = await Promise.all(Array.from({ length: 12 }, (_, i) =>
      inTransaction(env, "test.pool", async (txEnv, tx) => {
        await tx.lock("test.pool", "one");
        // A fresh statement text each time forces a type probe inside the transaction.
        return txEnv.SYNTILA_DB.prepare(`SELECT ?1::int + ${i} AS n`).bind(1).first<{ n: number }>();
      })));
    expect(results.map((r) => r?.n)).toEqual(Array.from({ length: 12 }, (_, i) => i + 1));
  });
});
