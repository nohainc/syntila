import { describe, expect, it, vi } from "./helpers/vitest-compat";
import { Data, type Tx } from "../../src/platform/data";
import {
  MAX_WORKER_ACTIVITY_HISTORY_PER_ASSIGNMENT,
  pruneWorkerActivityHistory,
} from "../../src/domain/worker-activity-history.js";

describe("Worker Activity history policy", () => {
  it("prunes history beyond the per-assignment bound", async () => {
    const run = vi
      .fn()
      .mockResolvedValueOnce(4)
      .mockResolvedValueOnce(3);
    const data = new Data({} as never);
    data.tx = async (_label, fn) => fn({ run } as unknown as Tx);

    await expect(pruneWorkerActivityHistory({ SYNTILA_DB: {}, SYNTILA_DATA: data })).resolves.toBe(7);
    expect(run).toHaveBeenCalledTimes(2);
    expect(MAX_WORKER_ACTIVITY_HISTORY_PER_ASSIGNMENT).toBe(256);
  });
});
