import { describe, expect, it } from "./helpers/vitest-compat";
import { startupReportAdvances } from "../../src/domain/assignment-startup.js";
import { gatewayFixture } from "./helpers/assignment-gateway.js";

const startup = (f: Awaited<ReturnType<typeof gatewayFixture>>) =>
  f.sqlite
    .prepare(
      "SELECT status, startup_stage AS stage, startup_detail_json AS detail FROM worker_assignments WHERE id='A1'",
    )
    .get() as { status: string; stage: string | null; detail: string | null };

describe("assignment.startup progress", () => {
  it("never moves the stage backwards", () => {
    expect(startupReportAdvances(null, "worker_resolved")).toBe(true);
    expect(startupReportAdvances("queued_for_slot", "slot_reserved")).toBe(
      true,
    );
    expect(startupReportAdvances("queued_for_slot", "queued_for_slot")).toBe(
      true,
    );
    expect(startupReportAdvances("engine_spawned", "profile_ready")).toBe(
      false,
    );
  });

  it("records the furthest stage for a dispatched assignment", async () => {
    const f = await gatewayFixture("dispatched");
    await f.send("assignment.startup", { stage: "profile_ready" });
    expect(startup(f).stage).toBe("profile_ready");
    await f.send("assignment.startup", {
      stage: "queued_for_slot",
      queuePosition: 2,
      activeSlots: 1,
      slotLimit: 1,
      waitingForSession: false,
      queueWaitTimeoutMs: 120000,
    });
    const row = startup(f);
    expect(row.stage).toBe("queued_for_slot");
    expect(JSON.parse(row.detail ?? "{}")).toMatchObject({
      queuePosition: 2,
      slotLimit: 1,
    });
    // A late, older report is ignored.
    await f.send("assignment.startup", { stage: "worker_resolved" });
    expect(startup(f).stage).toBe("queued_for_slot");
    expect(row.status).toBe("dispatched");
  });

  it("ignores progress once the assignment is running", async () => {
    const f = await gatewayFixture("running");
    await f.send("assignment.startup", { stage: "engine_spawned" });
    expect(startup(f).stage).toBeNull();
  });
});
