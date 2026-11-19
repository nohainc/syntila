import { describe, expect, it } from "./helpers/vitest-compat";
import { gatewayFixture } from "./helpers/assignment-gateway.js";

const started = { started: true, engineStarted: true, providerStarted: true };

describe("Gateway assignment acknowledgement ordering", () => {
  it("records durable phase events with admission and provider-start evidence", async () => {
    const f = await gatewayFixture("dispatched");
    await f.sqlite.exec("ALTER TABLE work_requests DISABLE TRIGGER trg_work_requests_snapshot_immutable; UPDATE work_requests SET primary_workspace_id='WS' WHERE id='R'; ALTER TABLE work_requests ENABLE TRIGGER trg_work_requests_snapshot_immutable");
    await f.send("assignment.ack", { accepted: true });
    await f.send("assignment.start.ack", started);
    const rows = await f.sqlite.prepare(`SELECT e.payload_json::jsonb->>'status' AS phase FROM realtime_events e
      JOIN outbox o ON o.event_id=e.event_id WHERE e.event_type='step.phase' ORDER BY e.sequence`).all() as { phase: string }[];
    expect(rows.map((row) => row.phase)).toEqual(["delivered", "running"]);
  });
  it("never reverts Running to Acknowledged when acceptance arrives late", async () => {
    const f = await gatewayFixture("dispatched");
    await f.send("assignment.start.ack", started);
    expect((await f.status()).status).toBe("running");
    const stamp = (await f.status()).updated_at;

    await f.send("assignment.ack", { accepted: true });
    await f.send("assignment.ack", { accepted: true });
    expect({ ...(await f.status()) }).toEqual({ status: "running", updated_at: stamp });
    const task = await f.sqlite
      .prepare("SELECT status FROM workflow_tasks WHERE id='T'")
      .get() as { status: string };
    expect(task.status).toBe("running");
  });

  it("accepts in the normal order and tolerates duplicates", async () => {
    const f = await gatewayFixture("dispatched");
    await f.send("assignment.ack", { accepted: true });
    expect((await f.status()).status).toBe("acknowledged");
    const stamp = (await f.status()).updated_at;
    await f.send("assignment.ack", { accepted: true });
    expect((await f.status()).updated_at).toBe(stamp);
    await f.send("assignment.start.ack", started);
    await f.send("assignment.start.ack", started);
    expect((await f.status()).status).toBe("running");
  });

  it("does not let a replayed rejection fail an accepted assignment", async () => {
    const f = await gatewayFixture("running");
    await f.send("assignment.ack", { accepted: false });
    expect((await f.status()).status).toBe("running");
  });

  it("does not move a terminal assignment back to Running", async () => {
    const f = await gatewayFixture("cancelled");
    await f.send("assignment.start.ack", started);
    await f.send("assignment.ack", { accepted: true });
    expect((await f.status()).status).toBe("cancelled");
  });

  it("ignores acknowledgements carrying another attempt's identity", async () => {
    const f = await gatewayFixture("dispatched");
    await f.send("assignment.start.ack", started, { attemptId: "ATT0" });
    await f.send("assignment.ack", { accepted: true }, { attemptId: "ATT0" });
    expect((await f.status()).status).toBe("dispatched");
  });
});
