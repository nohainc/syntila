import { describe, expect, it } from "./helpers/vitest-compat";
import {
  ASSIGNMENT_TERMINAL_EVENT_TYPE,
  MAX_WORKFLOW_SIGNAL_ATTEMPTS,
  signalAssignmentTerminal,
  sweepUnsignaledTerminals,
} from "../../src/domain/assignment-workflow-signal.js";
import { gatewayFixture } from "./helpers/assignment-gateway.js";

type Sent = { instanceId: string; type: string; payload: unknown };
const sweepNow = new Date("2026-10-14T12:00:00.000Z");

function workflowDouble(options: { failFirst?: number } = {}) {
  const sent: Sent[] = [];
  let failures = options.failFirst ?? 0;
  const binding = {
    async get(instanceId: string) {
      return {
        async sendEvent(event: { type: string; payload?: unknown }) {
          if (failures > 0) {
            failures -= 1;
            throw new Error("workflow unavailable");
          }
          sent.push({ instanceId, type: event.type, payload: event.payload });
        },
      };
    },
  };
  return { sent, binding };
}

async function fixture(status: string, options: { failFirst?: number } = {}) {
  const double = workflowDouble(options);
  const f = await gatewayFixture(status, {
    env: { SYNTILA_RUN_WORKFLOW: double.binding },
  });
  f.sqlite
    .prepare("UPDATE runs SET workflow_instance_id = 'wf-1' WHERE id = 'RUN'")
    .run();
  // The shared fixture stamps a fixed historic updated_at; the sweep only
  // considers recently terminal rows, so make this one recent.
  f.sqlite
    .prepare("UPDATE worker_assignments SET updated_at = ? WHERE id = 'A1'")
    .run(new Date().toISOString());
  // The shared fixture uses historical timestamps. Keep outbox age tests
  // independent of the wall clock without weakening the production cutoff.
  f.sqlite
    .prepare("UPDATE worker_assignments SET updated_at = ? WHERE id = 'A1'")
    .run(sweepNow.toISOString());
  const env = {
    SYNTILA_DB: f.db as never,
    SYNTILA_RUN_WORKFLOW: double.binding,
  };
  const row = () =>
    f.sqlite
      .prepare(
        "SELECT workflow_signaled_at AS at, workflow_signal_attempts AS attempts FROM worker_assignments WHERE id='A1'",
      )
      .get() as { at: string | null; attempts: number };
  return { f, env, row, ...double };
}

describe("assignment terminal workflow signal", () => {
  it("retains the durable outbox when the Workflow binding is temporarily absent", async () => {
    const { env, row, sent } = await fixture("completed");
    expect(
      await signalAssignmentTerminal({ SYNTILA_DB: env.SYNTILA_DB }, "A1"),
    ).toBe("failed");
    expect(row().at).toBeNull();
    expect(await sweepUnsignaledTerminals(env, { now: sweepNow })).toEqual({
      attempted: 1,
      signaled: 1,
    });
    expect(sent).toHaveLength(1);
  });

  it("recovers after event delivery succeeds but persisting its receipt fails", async () => {
    const { env, f, row, sent } = await fixture("completed");
    const prepare = f.db.prepare.bind(f.db);
    const interrupted = {
      ...env,
      SYNTILA_DB: {
        prepare(sql: string) {
          if (sql.includes("SET workflow_signaled_at"))
            throw new Error("simulated restart before receipt");
          return prepare(sql);
        },
      } as unknown as D1Database,
    };
    expect(await signalAssignmentTerminal(interrupted, "A1")).toBe("failed");
    expect(sent).toHaveLength(1);
    expect(row().at).toBeNull();
    expect(await sweepUnsignaledTerminals(env, { now: sweepNow })).toEqual({
      attempted: 1,
      signaled: 1,
    });
    expect(sent).toHaveLength(2);
    expect(sent[1]).toEqual(sent[0]);
    expect(f.status().status).toBe("completed");
    expect(row().at).not.toBeNull();
  });
  it("uses an event type Workflows accepts (no dots)", () => {
    expect(ASSIGNMENT_TERMINAL_EVENT_TYPE).toBe("assignment-terminal");
    expect(ASSIGNMENT_TERMINAL_EVENT_TYPE).not.toContain(".");
  });

  it("sends nothing for an assignment that is not terminal", async () => {
    const { env, sent, row } = await fixture("running");
    expect(await signalAssignmentTerminal(env, "A1")).toBe("not_terminal");
    expect(sent).toHaveLength(0);
    expect(row().at).toBeNull();
  });

  it("signals the run's Workflow instance with assignment and attempt identity", async () => {
    const { env, sent, row } = await fixture("completed");
    expect(await signalAssignmentTerminal(env, "A1")).toBe("signaled");
    expect(sent).toEqual([
      {
        instanceId: "wf-1",
        type: "assignment-terminal",
        payload: expect.objectContaining({
          assignmentId: "A1",
          attemptId: "ATT1",
          runId: "RUN",
          status: "completed",
        }),
      },
    ]);
    expect(row().at).not.toBeNull();
  });

  it("does not signal twice once delivery is recorded", async () => {
    const { env, sent } = await fixture("failed");
    await signalAssignmentTerminal(env, "A1");
    expect(await signalAssignmentTerminal(env, "A1")).toBe("already_signaled");
    expect(sent).toHaveLength(1);
  });

  it("keeps a failed signal in the outbox and the sweep delivers it", async () => {
    const { env, sent, row } = await fixture("completed", { failFirst: 1 });
    expect(await signalAssignmentTerminal(env, "A1")).toBe("failed");
    expect(row()).toMatchObject({ at: null, attempts: 1 });

    const swept = await sweepUnsignaledTerminals(env, { now: sweepNow });
    expect(swept).toEqual({ attempted: 1, signaled: 1 });
    expect(sent).toHaveLength(1);
    expect(row().at).not.toBeNull();
    expect(
      (await sweepUnsignaledTerminals(env, { now: sweepNow })).attempted,
    ).toBe(0);
  });

  it("stops retrying after the attempt limit", async () => {
    const { env, f } = await fixture("completed", { failFirst: 100 });
    for (let i = 0; i < MAX_WORKFLOW_SIGNAL_ATTEMPTS; i += 1) {
      await signalAssignmentTerminal(env, "A1");
    }
    expect(
      (await sweepUnsignaledTerminals(env, { now: sweepNow })).attempted,
    ).toBe(0);
    // The outcome itself is untouched.
    expect(
      (
        f.sqlite
          .prepare("SELECT status FROM worker_assignments WHERE id='A1'")
          .get() as { status: string }
      ).status,
    ).toBe("completed");
  });

  it("ignores terminal rows older than the sweep window", async () => {
    const { env, f } = await fixture("completed");
    f.sqlite
      .prepare(
        "UPDATE worker_assignments SET updated_at = '2020-01-01T00:00:00.000Z' WHERE id='A1'",
      )
      .run();
    expect(
      (await sweepUnsignaledTerminals(env, { now: sweepNow })).attempted,
    ).toBe(0);
  });

  it.each([
    ["2026-10-13T12:00:00.000Z", 1],
    ["2026-10-13T11:59:59.999Z", 0],
  ])("enforces the sweep age boundary for %s", async (updatedAt, attempted) => {
    const { env, f, sent } = await fixture("completed");
    f.sqlite
      .prepare("UPDATE worker_assignments SET updated_at = ? WHERE id = 'A1'")
      .run(updatedAt);
    expect(await sweepUnsignaledTerminals(env, { now: sweepNow })).toEqual({
      attempted,
      signaled: attempted,
    });
    expect(sent).toHaveLength(attempted);
  });

  it("records a run without a Workflow instance as handled", async () => {
    const { env, f, sent, row } = await fixture("cancelled");
    f.sqlite
      .prepare("UPDATE runs SET workflow_instance_id = NULL WHERE id = 'RUN'")
      .run();
    expect(await signalAssignmentTerminal(env, "A1")).toBe("no_instance");
    expect(sent).toHaveLength(0);
    expect(row().at).not.toBeNull();
  });
});

describe("Gateway terminal handling", () => {
  const result = {
    status: "completed",
    summary: "done",
    output: { text: "finished" },
    artifactIds: [],
  };

  it("re-acknowledges a lost terminal acknowledgement after Cloud restart without rewriting the outcome", async () => {
    const { f, sent } = await fixture("running");
    await f.send("assignment.result", result);
    const terminal = f.status();
    await f.outbound(); // First acknowledgement was lost at the Service.
    const restarted = f.restart();
    await f.send(
      "assignment.result",
      { ...result, output: { text: "replayed" } },
      {},
      restarted,
    );
    expect(f.status()).toEqual(terminal);
    expect(
      (await f.outbound(restarted)).filter((m) => m.type === "assignment.ack"),
    ).toHaveLength(1);
    expect(sent).toHaveLength(1);
    expect(
      JSON.parse(
        String(
          f.sqlite
            .prepare("SELECT output_json FROM worker_assignments WHERE id='A1'")
            .get()?.output_json,
        ),
      ),
    ).toMatchObject({ output: { text: "finished" } });
  });

  it("acknowledges the Service, then signals the Workflow", async () => {
    const { f, sent, row } = await fixture("running");
    await f.send("assignment.result", result);
    expect(f.status().status).toBe("completed");
    expect(
      (await f.outbound()).some((message) => message.type === "assignment.ack"),
    ).toBe(true);
    expect(sent).toHaveLength(1);
    expect(row().at).not.toBeNull();
  });

  it("acknowledges the Service even when the Workflow cannot be signalled", async () => {
    const { f, sent, row } = await fixture("running", { failFirst: 100 });
    await f.send("assignment.result", result);
    expect(f.status().status).toBe("completed");
    expect(
      (await f.outbound()).some((message) => message.type === "assignment.ack"),
    ).toBe(true);
    expect(sent).toHaveLength(0);
    expect(row()).toMatchObject({ at: null, attempts: 1 });
  });

  it("does not duplicate the signal for a replayed result", async () => {
    const { f, sent } = await fixture("running");
    await f.send("assignment.result", result);
    await f.send("assignment.result", result);
    expect(sent).toHaveLength(1);
  });
});
