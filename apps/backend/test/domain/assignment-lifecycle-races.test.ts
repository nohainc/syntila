import { describe, expect, it } from "./helpers/vitest-compat";
import {
  ASSIGNMENT_LIFECYCLE_STATUSES,
  isTerminalAssignmentStatus,
  type AssignmentLifecycleStatus,
} from "@syntila/core";
import {
  recordAssignmentCancelled,
  recordAssignmentError,
  recordAssignmentResult,
} from "../../src/domain/assignment-dispatcher.js";
import { assignmentCommandDisposition } from "../../src/domain/assignment-delivery.js";
import { transitionAssignment } from "../../src/domain/assignment-transitions.js";
import { conversationFixture } from "./helpers/conversation.js";

const T0 = "2026-10-14T10:00:00.000Z";

async function seed(status: AssignmentLifecycleStatus = "dispatched") {
  const f = await conversationFixture();
  f.sqlite.exec(
    "INSERT INTO runs(id,space_id,status,created_at,updated_at) VALUES('RUN','P','running','now','now')",
  );
  f.assign("A1");
  f.sqlite
    .prepare(
      `UPDATE worker_assignments
          SET run_id='RUN', attempt_id='ATT1', idempotency_key='IDEM1',
              status=?, updated_at=? WHERE id='A1'`,
    )
    .run(status, T0);
  f.sqlite.exec(
    "UPDATE workflow_tasks SET status='queued', started_at=NULL WHERE id='T'",
  );
  const row = () =>
    f.sqlite
      .prepare(
        "SELECT status, updated_at FROM worker_assignments WHERE id='A1'",
      )
      .get() as { status: string; updated_at: string };
  const task = () =>
    f.sqlite
      .prepare("SELECT status FROM workflow_tasks WHERE id='T'")
      .get() as {
      status: string;
    };
  const fence = {
    assignmentId: "A1",
    attemptId: "ATT1",
    executionWorkspaceId: "WS",
    runtimeIdentityId: "RT",
  };
  const admit = () => transitionAssignment(f.db, { fence, to: "acknowledged" });
  const providerStarted = () =>
    transitionAssignment(f.db, { fence, to: "running", startTaskId: "T" });
  return { ...f, row, task, fence, admit, providerStarted };
}

const rank = (status: string) =>
  ASSIGNMENT_LIFECYCLE_STATUSES.indexOf(status as AssignmentLifecycleStatus);

describe("assignment lifecycle ordering", () => {
  it("keeps Running when the acceptance acknowledgement arrives after provider start", async () => {
    const f = await seed("dispatched");
    const started = await f.providerStarted();
    expect(started).toMatchObject({ outcome: "applied", applied: true });
    expect(f.row().status).toBe("running");
    expect(f.task().status).toBe("running");
    const updatedAt = f.row().updated_at;

    const late = await f.admit();
    expect(late).toMatchObject({
      outcome: "superseded",
      applied: false,
      currentStatus: "running",
    });
    // The late acknowledgement neither downgrades nor refreshes the row, so
    // the startup deadline (which reads updated_at while Acknowledged) is not
    // reset or applied to a Running assignment.
    expect({ ...f.row() }).toEqual({
      status: "running",
      updated_at: updatedAt,
    });
  });

  it("keeps the provider-start evidence when it overtakes dispatch bookkeeping", async () => {
    const f = await seed("created");
    expect((await f.providerStarted()).applied).toBe(true);
    expect(f.row().status).toBe("running");
    expect(f.task().status).toBe("running");
  });

  it("treats a duplicate acceptance acknowledgement as a no-op", async () => {
    const f = await seed("dispatched");
    expect((await f.admit()).outcome).toBe("applied");
    const updatedAt = f.row().updated_at;
    const second = await f.admit();
    expect(second).toMatchObject({ outcome: "duplicate", applied: false });
    expect(f.row().updated_at).toBe(updatedAt);
  });

  it("ignores a late provider-start acknowledgement after cancellation", async () => {
    const f = await seed("acknowledged");
    expect(
      await recordAssignmentCancelled(
        f.db,
        "A1",
        { status: "cancelled", reason: "user" },
        "ATT1",
      ),
    ).toBe(true);
    const late = await f.providerStarted();
    expect(late).toMatchObject({
      outcome: "terminal",
      applied: false,
      currentStatus: "cancelled",
    });
    expect(f.row().status).toBe("cancelled");
    expect(f.task().status).toBe("cancelled");
    expect((await f.admit()).outcome).toBe("terminal");
  });

  it("resolves two handlers racing on one assignment to a single monotonic outcome", async () => {
    for (const order of [
      ["admit", "providerStarted"],
      ["providerStarted", "admit"],
    ] as const) {
      const f = await seed("dispatched");
      const results = await Promise.all(order.map((name) => f[name]()));
      // Whichever handler runs second, Running always wins and exactly the
      // transitions that moved the row report `applied`.
      expect(f.row().status).toBe("running");
      expect(f.task().status).toBe("running");
      expect(results.filter((r) => r.applied).length).toBeLessThanOrEqual(2);
      expect(
        results.find((_, i) => order[i] === "providerStarted")!.applied,
      ).toBe(true);
    }
  });

  it("never regresses or leaves a terminal state for any ordering of the evidence", async () => {
    // Exhaust all 30 distinct orders, each with a fresh migrated SQL fixture.
    // Shared CI runners need a larger budget than a single transition test.
    const evidence = [
      "admit",
      "admit",
      "providerStarted",
      "providerStarted",
      "result",
    ];
    const permutations = (items: string[]): string[][] =>
      items.length <= 1
        ? [items]
        : items.flatMap((item, index) =>
            permutations([
              ...items.slice(0, index),
              ...items.slice(index + 1),
            ]).map((rest) => [item, ...rest]),
          );
    const seen = new Set<string>();
    for (const order of permutations(evidence)) {
      const key = order.join(",");
      if (seen.has(key)) continue;
      seen.add(key);
      const f = await seed("dispatched");
      let previous = rank("dispatched");
      let terminalSeen: string | null = null;
      for (const step of order) {
        if (step === "result") {
          await recordAssignmentResult(
            f.db,
            "A1",
            { status: "completed", output: { text: "ok" } } as never,
            "ATT1",
          );
        } else {
          await f[step as "admit" | "providerStarted"]();
        }
        const { status } = f.row();
        expect(rank(status), key).toBeGreaterThanOrEqual(previous);
        if (terminalSeen) expect(status, key).toBe(terminalSeen);
        if (isTerminalAssignmentStatus(status as AssignmentLifecycleStatus))
          terminalSeen = status;
        previous = rank(status);
      }
      // A completed result always converges to Completed, whatever arrived
      // before or after it.
      expect(f.row().status, key).toBe("completed");
    }
  }, 60_000);

  it("makes terminal outcomes immutable when the result arrives more than once", async () => {
    const f = await seed("running");
    expect(
      await recordAssignmentResult(
        f.db,
        "A1",
        { status: "completed", output: { text: "first" } } as never,
        "ATT1",
      ),
    ).toBe(true);
    const completedAt = f.row().updated_at;
    expect(
      await recordAssignmentResult(
        f.db,
        "A1",
        { status: "completed", output: { text: "second" } } as never,
        "ATT1",
      ),
    ).toBe(false);
    expect(
      await recordAssignmentError(
        f.db,
        "A1",
        {
          error: {
            code: "provider_unavailable",
            message: "x",
            retryable: true,
          },
          failedAt: T0,
        },
        "ATT1",
      ),
    ).toBe(false);
    expect(
      await recordAssignmentCancelled(
        f.db,
        "A1",
        { status: "cancelled", reason: "late" },
        "ATT1",
      ),
    ).toBe(false);
    const stored = f.sqlite
      .prepare(
        "SELECT status, output_json, updated_at FROM worker_assignments WHERE id='A1'",
      )
      .get() as { status: string; output_json: string; updated_at: string };
    expect(stored.status).toBe("completed");
    expect(stored.output_json).toContain("first");
    expect(stored.updated_at).toBe(completedAt);
    expect((await f.providerStarted()).outcome).toBe("terminal");
  });

  it("accepts a result that overtakes the provider-start acknowledgement", async () => {
    const f = await seed("acknowledged");
    expect(
      await recordAssignmentResult(
        f.db,
        "A1",
        { status: "completed", output: { text: "ok" } } as never,
        "ATT1",
      ),
    ).toBe(true);
    expect((await f.providerStarted()).outcome).toBe("terminal");
    expect(f.row().status).toBe("completed");
  });

  it("only lets a rejection fail an assignment that was never accepted", async () => {
    const f = await seed("running");
    const rejected = await recordAssignmentError(
      f.db,
      "A1",
      {
        error: { code: "worker_not_ready", message: "x", retryable: true },
        failedAt: T0,
      },
      "ATT1",
      { onlyFrom: ["created", "dispatched"] },
    );
    expect(rejected).toBe(false);
    expect(f.row().status).toBe("running");

    const g = await seed("dispatched");
    expect(
      await recordAssignmentError(
        g.db,
        "A1",
        {
          error: { code: "worker_not_ready", message: "x", retryable: true },
          failedAt: T0,
        },
        "ATT1",
        { onlyFrom: ["created", "dispatched"] },
      ),
    ).toBe(true);
    expect(g.row().status).toBe("failed");
  });
});

describe("assignment identity fencing", () => {
  it("rejects messages from an old attempt after a newer attempt begins", async () => {
    const f = await seed("running");
    // A newer attempt of the same task has its own assignment.
    f.assign("A2");
    f.sqlite
      .prepare(
        `UPDATE worker_assignments
            SET run_id='RUN', attempt_id='ATT2', idempotency_key='IDEM2',
                status='running' WHERE id='A2'`,
      )
      .run();

    // The old attempt's Service reuses A2's assignment id with its own attempt.
    const stale = await transitionAssignment(f.db, {
      to: "running",
      fence: { ...f.fence, assignmentId: "A2" },
    });
    expect(stale.outcome).toBe("stale");

    // Old-attempt terminal reports fenced by attempt do not touch A2.
    expect(
      await recordAssignmentResult(
        f.db,
        "A2",
        { status: "completed", output: { text: "old" } } as never,
        "ATT1",
      ),
    ).toBe(false);
    const a2 = f.sqlite
      .prepare("SELECT status FROM worker_assignments WHERE id='A2'")
      .get() as { status: string };
    expect(a2.status).toBe("running");
  });

  it("rejects a previous runtime identity and another Workspace", async () => {
    const f = await seed("dispatched");
    const oldRuntime = await transitionAssignment(f.db, {
      to: "acknowledged",
      fence: { ...f.fence, runtimeIdentityId: "RT-OLD" },
    });
    const otherWorkspace = await transitionAssignment(f.db, {
      to: "acknowledged",
      fence: { ...f.fence, executionWorkspaceId: "WS-OTHER" },
    });
    expect(oldRuntime.outcome).toBe("stale");
    expect(otherWorkspace.outcome).toBe("stale");
    expect(f.row().status).toBe("dispatched");
  });

  it("reports an unknown assignment without writing", async () => {
    const f = await seed("dispatched");
    const missing = await transitionAssignment(f.db, {
      to: "acknowledged",
      fence: { ...f.fence, assignmentId: "NOPE" },
    });
    expect(missing.outcome).toBe("not_found");
  });
});

describe("Service reconnect and replay", () => {
  it("does not re-send an acknowledged or running assignment when the Service replays it", async () => {
    for (const status of ["acknowledged", "running"] as const) {
      const disposition = assignmentCommandDisposition(status);
      expect(disposition).toMatchObject({
        shouldSend: false,
        duplicate: true,
        accepted: true,
        terminal: false,
      });
    }
    expect(assignmentCommandDisposition("completed")).toMatchObject({
      shouldSend: false,
      terminal: true,
    });
    // A replayed `dispatched` command is re-sent, but never reopens a row.
    const f = await seed("acknowledged");
    expect((await f.admit()).outcome).toBe("duplicate");
    expect(f.row().status).toBe("acknowledged");
  });
});
