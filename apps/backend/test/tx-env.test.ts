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
  test("data-layer statements, queries and events commit together; fan-out waits for the commit", async () => {
    const { env, sql, delivered } = fixture();
    await inTransaction(env, "test.commit", async (txEnv, tx) => {
      await dataOf(txEnv).read.run`UPDATE spaces SET name = ${"A"} WHERE id = 'S'`;
      // The data layer inside sees the transaction's uncommitted write.
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

  test("statements inside do not wait for the old global writer lock", async () => {
    const { env, sql } = fixture();
    // Hold the global writer lock from another connection.
    const holder = await sql.reserve();
    await holder`BEGIN`;
    await holder.unsafe("SELECT pg_advisory_xact_lock($1)", [0x5359_4e57]);
    try {
      await inTransaction(env, "test.nolock", async (txEnv, tx) => {
        await tx.run`SET LOCAL lock_timeout = '500ms'`;
        await tx.run`UPDATE spaces SET name = 'C' WHERE id = 'S'`;
        await tx.run`UPDATE spaces SET description = 'c' WHERE id = 'S'`;
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

describe("transactions on a small pool", () => {
  test("many parallel transactions on a small pool do not starve each other", async () => {
    const { db } = pgD1({ max: 2 });
    const env = { SYNTILA_DB: db } as any;
    const results = await Promise.all(Array.from({ length: 12 }, (_, i) =>
      inTransaction(env, "test.pool", async (txEnv, tx) => {
        await tx.lock("test.pool", "one");
        return dataOf(txEnv).read.row<{ n: number }>`SELECT ${1}::int + ${i}::int AS n`;
      })));
    expect(results.map((r) => r?.n)).toEqual(Array.from({ length: 12 }, (_, i) => i + 1));
  });
});
