import { describe, expect, it } from "./helpers/vitest-compat";
import { gatewayFixture } from "./helpers/assignment-gateway.js";

const started = { started: true, engineStarted: true, providerStarted: true };

describe("Gateway assignment acknowledgement ordering", () => {
  it("never reverts Running to Acknowledged when acceptance arrives late", async () => {
    const f = await gatewayFixture("dispatched");
    await f.send("assignment.start.ack", started);
    expect(f.status().status).toBe("running");
    const stamp = f.status().updated_at;

    await f.send("assignment.ack", { accepted: true });
    await f.send("assignment.ack", { accepted: true });
    expect({ ...f.status() }).toEqual({ status: "running", updated_at: stamp });
    const task = f.sqlite
      .prepare("SELECT status FROM workflow_tasks WHERE id='T'")
      .get() as { status: string };
    expect(task.status).toBe("running");
  });

  it("accepts in the normal order and tolerates duplicates", async () => {
    const f = await gatewayFixture("dispatched");
    await f.send("assignment.ack", { accepted: true });
    expect(f.status().status).toBe("acknowledged");
    const stamp = f.status().updated_at;
    await f.send("assignment.ack", { accepted: true });
    expect(f.status().updated_at).toBe(stamp);
    await f.send("assignment.start.ack", started);
    await f.send("assignment.start.ack", started);
    expect(f.status().status).toBe("running");
  });

  it("does not let a replayed rejection fail an accepted assignment", async () => {
    const f = await gatewayFixture("running");
    await f.send("assignment.ack", { accepted: false });
    expect(f.status().status).toBe("running");
  });

  it("does not move a terminal assignment back to Running", async () => {
    const f = await gatewayFixture("cancelled");
    await f.send("assignment.start.ack", started);
    await f.send("assignment.ack", { accepted: true });
    expect(f.status().status).toBe("cancelled");
  });

  it("ignores acknowledgements carrying another attempt's identity", async () => {
    const f = await gatewayFixture("dispatched");
    await f.send("assignment.start.ack", started, { attemptId: "ATT0" });
    await f.send("assignment.ack", { accepted: true }, { attemptId: "ATT0" });
    expect(f.status().status).toBe("dispatched");
  });
});
