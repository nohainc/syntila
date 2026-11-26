import { describe, expect, it } from "vitest";
import { runWorkerLoad } from "./perf-worker-load.mjs";

describe("real Worker load scheduler", () => {
  it("runs all jobs with bounded concurrency and stable lanes", async () => {
    let active = 0;
    let peak = 0;
    const jobs = [];
    const lanes = new Set();
    await runWorkerLoad(7, 3, async (job, lane) => {
      active++;
      peak = Math.max(peak, active);
      lanes.add(lane);
      await new Promise((resolve) => setTimeout(resolve, 2));
      jobs.push(job);
      active--;
    });
    expect(jobs.sort((a, b) => a - b)).toEqual([0, 1, 2, 3, 4, 5, 6]);
    expect(peak).toBe(3);
    expect([...lanes].sort()).toEqual([0, 1, 2]);
  });
  it("rejects invalid limits before starting any jobs", async () => {
    let calls = 0;
    await expect(
      runWorkerLoad(2, 0, async () => {
        calls++;
      }),
    ).rejects.toThrow(RangeError);
    await expect(
      runWorkerLoad(2, 9, async () => {
        calls++;
      }),
    ).rejects.toThrow(RangeError);
    expect(calls).toBe(0);
  });
  it("drains started work before reporting a failure", async () => {
    const completed = [];
    await expect(
      runWorkerLoad(4, 2, async (job) => {
        if (job === 0) throw new Error("request failed");
        await new Promise((resolve) => setTimeout(resolve, 5));
        completed.push(job);
      }),
    ).rejects.toThrow("request failed");
    expect(completed).toEqual([1]);
  });
});
