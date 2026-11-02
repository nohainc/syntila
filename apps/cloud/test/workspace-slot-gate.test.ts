import { describe, expect, it } from "vitest";
import { gatewayFixture } from "./helpers/assignment-gateway.js";
import { recoverStaleAssignments } from "../src/assignment-dispatcher.js";
import { beginAssignmentRevocation } from "../src/assignment-revocation.js";
import { presentExecution } from "../src/execution-phase.js";
import {
  recordCloudQueueReason,
  recordCloudQueueNotReady,
  assignmentDeadlineViolation,
} from "../src/assignment-delivery.js";

const payload = {
  snapshot: { workerTypeId: "chatgpt" },
  input: { objective: "waits for a free slot" },
};

/** One slot, already held by a running assignment B1. */
async function fullWorkspace(research = false) {
  const f = await gatewayFixture("created", { research });
  f.sqlite.exec(`
    UPDATE execution_workspaces SET parallel_slots = 1 WHERE id = 'WS';
    CREATE TEMP TABLE occupant AS SELECT * FROM worker_assignments WHERE id = 'A1';
    UPDATE occupant SET id = 'B1', attempt_id = 'ATT2', idempotency_key = 'IDEM2', status = 'running';
    INSERT INTO worker_assignments SELECT * FROM occupant;
  `);
  f.sqlite
    .prepare(
      "UPDATE worker_assignments SET command_payload_json = ? WHERE id = 'A1'",
    )
    .run(JSON.stringify(payload));
  return f;
}

describe("Cloud-owned Workspace slots", () => {
  it("starts a separate readiness clock when a capacity queue loses its Service", async () => {
    const f = await fullWorkspace(true);
    try {
      await f.dispatch();
      const now = new Date(Date.now() + 24 * 60 * 60_000).toISOString();
      await recordCloudQueueNotReady(f.db, "WS", "RT", now);
      await recordCloudQueueNotReady(
        f.db,
        "WS",
        "RT",
        new Date(Date.parse(now) + 1000).toISOString(),
      );
      const row = f.sqlite
        .prepare(
          "SELECT cloud_queue_reason AS reason,cloud_queue_since AS since FROM worker_assignments WHERE id='A1'",
        )
        .get()!;
      expect(row).toMatchObject({ reason: "service_not_ready", since: now });
      expect(
        assignmentDeadlineViolation(
          {
            status: "created",
            createdAt: "2026-01-01T00:00:00Z",
            cloudQueueReason: String(row.reason),
            cloudQueueSince: String(row.since),
            workflowId: "research",
            workflowVersion: 2,
          },
          Date.parse(now) + 120_000,
        ),
      ).toMatchObject({ phase: "readiness_wait" });
    } finally {
      f.sqlite.close();
    }
  });
  it("resumes a persisted capacity queue after Gateway restart without duplicate starts", async () => {
    const f = await fullWorkspace(true);
    try {
      await f.dispatch();
      const restarted = f.restart();
      f.sqlite.exec(
        "UPDATE worker_assignments SET status='completed' WHERE id='B1'",
      );
      for (let i = 0; i < 2; i++) {
        await restarted.fetch(
          new Request("https://gateway.internal/flush-queued", {
            method: "POST",
          }),
        );
      }
      expect(
        (await f.outbound(restarted)).filter(
          (m) => m.type === "assignment.start",
        ),
      ).toHaveLength(1);
      expect(f.status().status).toBe("dispatched");
    } finally {
      f.sqlite.close();
    }
  });
  it("keeps a Research branch queued past the normal deadline without holding a slot", async () => {
    const f = await fullWorkspace(true);
    try {
      await f.dispatch();
      const row = () =>
        f.sqlite
          .prepare(
            "SELECT status AS assignmentStatus,cloud_queue_reason AS cloudQueueReason,cloud_queue_since AS cloudQueueSince FROM worker_assignments WHERE id='A1'",
          )
          .get()!;
      expect(presentExecution(row())).toMatchObject({
        executionPhase: "queued",
        executionPhaseDetail:
          "All Worker slots are busy; starting when one is free",
      });
      const since = row().cloudQueueSince;
      await f.dispatch();
      expect(row().cloudQueueSince).toBe(since);
      // The ordinary queue deadline is two minutes. A long-running sibling
      // must not make this queued branch fail after that time.
      f.sqlite
        .prepare(
          "UPDATE worker_assignments SET timeout_ms=?,running_at=? WHERE id='B1'",
        )
        .run(8 * 60 * 60_000, new Date().toISOString());
      await recoverStaleAssignments(f.db, new Date(Date.now() + 10 * 60_000));
      expect(f.status().status).toBe("created");
      expect(
        (await f.outbound()).filter((m) => m.type === "assignment.start"),
      ).toHaveLength(0);
      // Increasing the configured slot total admits the next branch immediately.
      f.sqlite.exec(
        "UPDATE execution_workspaces SET parallel_slots=2 WHERE id='WS'",
      );
      await f.gateway.fetch(
        new Request("https://gateway.internal/flush-queued", {
          method: "POST",
        }),
      );
      expect(
        (await f.outbound()).filter((m) => m.type === "assignment.start"),
      ).toHaveLength(1);
      expect(f.status().status).toBe("dispatched");
    } finally {
      f.sqlite.close();
    }
  });

  it("cancels a capacity-waiting branch without launching it and preserves its wait clock", async () => {
    const f = await fullWorkspace();
    try {
      await f.dispatch();
      await beginAssignmentRevocation(f.db, {
        assignmentId: "A1",
        attemptId: "ATT1",
        intent: {
          status: "cancelled",
          reason: "User cancelled",
          source: "work_cancelled",
        },
      });
      await recordCloudQueueReason(f.db, "A1", "ATT1", "service_not_ready");
      expect(f.status().status).toBe("cancelled");
      f.sqlite.exec(
        "UPDATE worker_assignments SET status='completed' WHERE id='B1'",
      );
      await f.gateway.fetch(
        new Request("https://gateway.internal/flush-queued", {
          method: "POST",
        }),
      );
      expect(
        (await f.outbound()).filter((m) => m.type === "assignment.start"),
      ).toHaveLength(0);
    } finally {
      f.sqlite.close();
    }
  });
  it("keeps work in the Cloud queue while every slot is taken", async () => {
    const f = await fullWorkspace();
    const response = await f.dispatch();
    expect(response.status).toBe(202);
    expect(await response.json()).toMatchObject({
      delivered: false,
      queued: true,
      deliveryState: "waiting_for_slot",
    });
    expect(f.status().status).toBe("created");
    expect(
      (await f.outbound()).filter((m) => m.type === "assignment.start"),
    ).toHaveLength(0);
  });

  it("starts queued work once a slot frees, stamped with the slot total", async () => {
    const f = await fullWorkspace();
    await f.dispatch();
    f.sqlite.exec(
      "UPDATE worker_assignments SET status = 'completed' WHERE id = 'B1'",
    );
    await f.gateway.fetch(
      new Request("https://gateway.internal/flush-queued", { method: "POST" }),
    );
    const started = (await f.outbound()).filter(
      (m) => m.type === "assignment.start",
    );
    expect(started).toHaveLength(1);
    expect(
      (started[0]!.payload.snapshot as Record<string, unknown>)
        .maxConcurrentAssignments,
    ).toBe(1);
    expect(f.status().status).toBe("dispatched");
  });
});
