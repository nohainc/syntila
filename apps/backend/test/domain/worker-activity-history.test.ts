import { describe, expect, it, vi } from "./helpers/vitest-compat";
import {
  MAX_WORKER_ACTIVITY_HISTORY_PER_ASSIGNMENT,
  pruneWorkerActivityHistory,
  shouldPersistWorkerActivity,
} from "../../src/domain/worker-activity-history.js";

describe("Worker Activity history policy", () => {
  it("persists lifecycle and tool events but not replaceable status updates", () => {
    expect(
      shouldPersistWorkerActivity({
        activityType: "tool.started",
        activityStatus: "running",
        title: "Running tool",
      }),
    ).toBe(true);
    expect(
      shouldPersistWorkerActivity({
        activityType: "model.status",
        activityStatus: "updated",
        title: "Working",
      }),
    ).toBe(false);
  });

  it("prunes history beyond the per-assignment bound", async () => {
    const run = vi
      .fn()
      .mockResolvedValueOnce({ meta: { changes: 4 } })
      .mockResolvedValueOnce({ meta: { changes: 3 } });
    const db = {
      prepare: vi.fn(() => ({
        bind: vi.fn(() => ({ run })),
      })),
    } as unknown as D1Database;

    await expect(pruneWorkerActivityHistory(db)).resolves.toBe(7);
    expect(db.prepare).toHaveBeenCalledWith(
      expect.stringContaining("ROW_NUMBER() OVER"),
    );
    expect(run).toHaveBeenCalledTimes(2);
    expect(MAX_WORKER_ACTIVITY_HISTORY_PER_ASSIGNMENT).toBe(256);
  });
});
