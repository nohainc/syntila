import { describe, expect, it } from "./helpers/vitest-compat";
import {
  ASSIGNMENT_RECONCILIATION_INTERVAL_MS,
  LONG_RUN_RECONCILIATION_INTERVAL_MS,
  nextWakeupMs,
  providerExecutionOverrun,
} from "../../src/domain/workflow.js";

const t0 = Date.parse("2026-10-14T12:00:00.000Z");
const iso = (offsetMs: number) => new Date(t0 + offsetMs).toISOString();

const base = { createdAt: iso(0), updatedAt: iso(0) };

describe("Workflow terminal wait", () => {
  it("reconciles a running assignment at the reconciliation interval", () => {
    const row = { ...base, status: "running", runningAt: iso(0) };
    expect(nextWakeupMs(row, 600_000, t0 + 1_000)).toBe(
      ASSIGNMENT_RECONCILIATION_INTERVAL_MS,
    );
  });

  it("re-reads a long run less often to stay inside the Workflow step budget", () => {
    const row = { ...base, status: "running", runningAt: iso(0) };
    expect(nextWakeupMs(row, 8 * 3_600_000, t0 + 11 * 60_000)).toBe(
      LONG_RUN_RECONCILIATION_INTERVAL_MS,
    );
  });

  it("wakes exactly at a short phase deadline instead of up to 30 s late", () => {
    // command_delivery allows 30 s from dispatch; 25 s have passed.
    const row = { ...base, status: "dispatched", dispatchedAt: iso(0) };
    expect(nextWakeupMs(row, 600_000, t0 + 25_000)).toBe(5_000);
  });

  it("never waits less than a second, even past a deadline", () => {
    const row = { ...base, status: "dispatched", dispatchedAt: iso(0) };
    expect(nextWakeupMs(row, 600_000, t0 + 90_000)).toBe(1_000);
  });

  it("falls back to the interval when the row is unknown", () => {
    expect(nextWakeupMs(null, 600_000, t0)).toBe(
      ASSIGNMENT_RECONCILIATION_INTERVAL_MS,
    );
  });

  it("gives the Service its own timeout window before Cloud calls an overrun", () => {
    const row = { ...base, status: "running", runningAt: iso(0) };
    expect(providerExecutionOverrun(row, 60_000, t0 + 60_000)).toBe(false);
    expect(providerExecutionOverrun(row, 60_000, t0 + 60_000 + 119_000)).toBe(
      false,
    );
    expect(providerExecutionOverrun(row, 60_000, t0 + 60_000 + 120_000)).toBe(
      true,
    );
  });
});
