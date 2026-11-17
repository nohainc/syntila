import type { FixtureDb } from "./helpers/fixture-db";
import { pgD1 } from "./helpers/pg-d1";
import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "./helpers/vitest-compat";
import { Data, drainTxStats, type Tx } from "../../src/platform/data";
import {
  DURABLE_EVENT_RETENTION_DAYS,
  pruneExpiredRealtimeEvents,
} from "../../src/domain/realtime-retention.js";

describe("durable realtime event retention", () => {
  it("removes events older than the 90-day retention window in bounded batches", async () => {
    const now = new Date("2026-10-02T00:00:00.000Z");
    const batchSizes = [1_000, 1_000, 17];
    const run = vi.fn(async () => batchSizes.shift() ?? 0);
    const data = new Data({} as never);
    data.tx = async (_label, fn) => fn({ run } as unknown as Tx);

    const deleted = await pruneExpiredRealtimeEvents({ SYNTILA_DB: {}, SYNTILA_DATA: data }, now);

    expect(DURABLE_EVENT_RETENTION_DAYS).toBe(7);
    expect(deleted).toBe(2_017);
    expect(run).toHaveBeenNthCalledWith(1, expect.anything(), "2026-09-25T00:00:00.000Z", 1_000);
    expect(run).toHaveBeenCalledTimes(3);
  });

  it("caps each scheduled run to ten thousand deletes", async () => {
    const run = vi.fn(async () => 1_000);
    const data = new Data({} as never);
    data.tx = async (_label, fn) => fn({ run } as unknown as Tx);

    const deleted = await pruneExpiredRealtimeEvents(
      { SYNTILA_DB: {}, SYNTILA_DATA: data },
      new Date("2026-10-02T00:00:00.000Z"),
    );

    expect(deleted).toBe(10_000);
    expect(run).toHaveBeenCalledTimes(10);
  });

  it("prunes expired rows without resetting the durable sequence cursor", async () => {
    const fixture = await pgD1();
    const database = (fixture.sqlite as unknown as FixtureDb);
    await database.exec(
      "" /* D1 migration: schema is final in PostgreSQL */,
    );
    await database
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
    await insert.run("event-expired", 10, "idem-expired", "2026-09-24T23:59:59.999Z");
    await insert.run(
      "event-retained",
      11,
      "idem-retained",
      "2026-09-25T00:00:00.000Z",
    );
    try {
      drainTxStats();
      const deleted = await pruneExpiredRealtimeEvents(
        { SYNTILA_DB: fixture.db },
        new Date("2026-10-02T00:00:00.000Z"),
      );
      const rows = (await database
        .prepare("SELECT event_id FROM realtime_events ORDER BY sequence")
        .all()) as Array<{ event_id: string }>;
      const cursor = (await database
        .prepare(
          "SELECT next_sequence FROM realtime_event_cursors WHERE workspace_id = 'workspace-1'",
        )
        .get()) as { next_sequence: number };

      expect(deleted).toBe(1);
      expect(drainTxStats().some((stat) => stat.label === "retention.realtime" && stat.count === 1)).toBe(true);
      expect(rows.map((row) => row.event_id)).toEqual(["event-retained"]);
      expect(cursor.next_sequence).toBe(12);
    } finally {
      await database.close();
    }
  });
});
