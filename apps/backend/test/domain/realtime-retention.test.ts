import { pgD1 } from "./helpers/pg-d1";
import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "./helpers/vitest-compat";
import {
  DURABLE_EVENT_RETENTION_DAYS,
  pruneExpiredRealtimeEvents,
} from "../../src/domain/realtime-retention.js";

describe("durable realtime event retention", () => {
  it("removes events older than the 90-day retention window in bounded batches", async () => {
    const now = new Date("2026-10-02T00:00:00.000Z");
    const batchSizes = [1_000, 1_000, 17];
    const run = vi.fn(async () => ({
      meta: { changes: batchSizes.shift() ?? 0 },
    }));
    const bind = vi.fn(() => ({ run }));
    const prepare = vi.fn(() => ({ bind }));
    const db = { prepare } as unknown as D1Database;

    const deleted = await pruneExpiredRealtimeEvents(db, now);

    expect(DURABLE_EVENT_RETENTION_DAYS).toBe(7);
    expect(deleted).toBe(2_017);
    expect(prepare).toHaveBeenCalledWith(
      expect.stringContaining("DELETE FROM realtime_events"),
    );
    expect(bind).toHaveBeenNthCalledWith(1, "2026-09-25T00:00:00.000Z", 1_000);
    expect(run).toHaveBeenCalledTimes(3);
  });

  it("caps each scheduled run to ten thousand deletes", async () => {
    const run = vi.fn(async () => ({ meta: { changes: 1_000 } }));
    const db = {
      prepare: () => ({ bind: () => ({ run }) }),
    } as unknown as D1Database;

    const deleted = await pruneExpiredRealtimeEvents(
      db,
      new Date("2026-10-02T00:00:00.000Z"),
    );

    expect(deleted).toBe(10_000);
    expect(run).toHaveBeenCalledTimes(10);
  });

  it("prunes expired rows without resetting the durable sequence cursor", async () => {
    const database = (pgD1().sqlite as unknown as DatabaseSync);
    database.exec(
      "" /* D1 migration: schema is final in PostgreSQL */,
    );
    database
      .prepare(
        `INSERT INTO realtime_event_cursors (workspace_id, next_sequence)
         VALUES ('workspace-1', 12)`,
      )
      .run();
    const insert = database.prepare(
      `INSERT INTO realtime_events
       (event_id, workspace_id, sequence, event_type, payload_json,
        idempotency_key, occurred_at)
       VALUES (?, 'workspace-1', ?, 'work_request.created', '{}', ?, ?)`,
    );
    insert.run("event-expired", 10, "idem-expired", "2026-09-24T23:59:59.999Z");
    insert.run(
      "event-retained",
      11,
      "idem-retained",
      "2026-09-25T00:00:00.000Z",
    );
    const db = {
      prepare(sql: string) {
        return {
          bind(...values: unknown[]) {
            return {
              async run() {
                const result = database
                  .prepare(sql)
                  .run(...(values as SQLInputValue[]));
                return { meta: { changes: Number(result.changes) } };
              },
            };
          },
        };
      },
    } as unknown as D1Database;

    try {
      const deleted = await pruneExpiredRealtimeEvents(
        db,
        new Date("2026-10-02T00:00:00.000Z"),
      );
      const rows = database
        .prepare("SELECT event_id FROM realtime_events ORDER BY sequence")
        .all() as Array<{ event_id: string }>;
      const cursor = database
        .prepare(
          "SELECT next_sequence FROM realtime_event_cursors WHERE workspace_id = 'workspace-1'",
        )
        .get() as { next_sequence: number };

      expect(deleted).toBe(1);
      expect(rows.map((row) => row.event_id)).toEqual(["event-retained"]);
      expect(cursor.next_sequence).toBe(12);
    } finally {
      database.close();
    }
  });
});
