import { describe, expect, it } from "./helpers/vitest-compat";
import {
  classifyExpiredLease,
  leaseIsCurrent,
  MAX_LEASE_LIFETIME_MS,
  selectNextStatefulRequest,
  THREAD_LEASE_MS,
} from "../../src/domain/thread-coordinator.js";
import { sortThreads } from "../../src/domain/routes/handlers.js";

describe("Thread execution coordinator", () => {
  it("selects exactly one FIFO stateful request and bypasses stateless work", () => {
    expect(
      selectNextStatefulRequest([
        {
          id: "later",
          threadId: "ws-1",
          mode: "stateful",
          status: "queued",
          primaryWorkspaceId: "workspace-1",
          createdAt: "2026-09-24T00:00:02.000Z",
        },
        {
          id: "stateless",
          threadId: "ws-1",
          mode: "stateless",
          status: "queued",
          primaryWorkspaceId: "",
          createdAt: "2026-09-24T00:00:00.000Z",
        },
        {
          id: "first",
          threadId: "ws-1",
          mode: "stateful",
          status: "queued",
          primaryWorkspaceId: "workspace-1",
          createdAt: "2026-09-24T00:00:01.000Z",
        },
      ]),
    ).toMatchObject({ id: "first" });
  });

  it("does not allocate another token for a duplicate enqueue", () => {
    // A duplicate enqueue observes the existing non-queued state and does not
    // allocate another token; the coordinator's enqueue path is idempotent by
    // Work Request ID.
    expect(
      selectNextStatefulRequest([
        {
          id: "request-1",
          threadId: "ws-1",
          mode: "stateful",
          status: "running",
          primaryWorkspaceId: "workspace-1",
          createdAt: "2026-09-24T00:00:00.000Z",
        },
      ]),
    ).toBeNull();
  });

  it("rejects stale fencing tokens and expired leases", () => {
    const expiry = new Date(Date.now() + THREAD_LEASE_MS).toISOString();
    expect(
      leaseIsCurrent(
        { status: "active", fencingToken: 7, expiresAt: expiry },
        7,
      ),
    ).toBe(true);
    expect(
      leaseIsCurrent(
        { status: "active", fencingToken: 7, expiresAt: expiry },
        6,
      ),
    ).toBe(false);
    expect(
      leaseIsCurrent(
        { status: "expired", fencingToken: 7, expiresAt: expiry },
        7,
      ),
    ).toBe(false);
    expect(
      leaseIsCurrent(
        {
          status: "active",
          fencingToken: 7,
          expiresAt: "2026-09-23T00:00:00.000Z",
        },
        7,
        Date.parse("2026-09-24T00:00:00.000Z"),
      ),
    ).toBe(false);
  });

  it("sorts Threads by newest update with deterministic tie-breaking", async () => {
    const ws1 = {
      id: "ws-1",
      name: "Alpha",
      createdAt: "2026-09-24T00:00:01.000Z",
      updatedAt: "2026-09-25T12:00:00.000Z",
    };
    const ws2 = {
      id: "ws-2",
      name: "Beta",
      createdAt: "2026-09-24T00:00:02.000Z",
      updatedAt: "2026-09-26T12:00:00.000Z",
    };
    const ws3 = {
      id: "ws-3",
      name: "Gamma",
      createdAt: "2026-09-24T00:00:03.000Z",
      updatedAt: "2026-09-25T12:00:00.000Z",
    };

    const sorted = sortThreads([ws3, ws1, ws2]);
    expect(sorted.map((w) => w.id)).toEqual(["ws-2", "ws-3", "ws-1"]);

    const withoutUpdates = sortThreads([
      { id: "old", createdAt: "2026-09-24T00:00:01.000Z" },
      { id: "new", createdAt: "2026-09-24T00:00:02.000Z" },
    ]);
    expect(withoutUpdates.map((w) => w.id)).toEqual(["new", "old"]);
  });

  describe("expired lease validation", () => {
    const now = Date.parse("2026-10-27T18:18:40.000Z");
    const minutesAgo = (m: number) => new Date(now - m * 60_000).toISOString();
    const running = (aliveMinutesAgo: number) => ({
      id: "A1",
      attemptId: "T1",
      status: "running",
      engineAliveAt: minutesAgo(aliveMinutesAgo),
      runningAt: minutesAgo(48),
      updatedAt: minutesAgo(48),
    });

    it("keeps a request whose Worker is still alive", () => {
      expect(
        classifyExpiredLease(
          {
            acquiredAt: minutesAgo(48),
            workspaceOnline: true,
            assignments: [running(1)],
          },
          now,
        ),
      ).toEqual({ action: "extend" });
    });

    it("fails and stops a silent Worker", () => {
      expect(
        classifyExpiredLease(
          {
            acquiredAt: minutesAgo(48),
            workspaceOnline: true,
            assignments: [running(20)],
          },
          now,
        ),
      ).toEqual({
        action: "fail",
        reason: "worker_lost",
        revokeAssignmentIds: ["A1"],
      });
    });

    it("does not trust heartbeats from an offline Workspace", () => {
      expect(
        classifyExpiredLease(
          {
            acquiredAt: minutesAgo(48),
            workspaceOnline: false,
            assignments: [running(1)],
          },
          now,
        ).action,
      ).toBe("fail");
    });

    it("stops extending at the maximum lifetime", () => {
      expect(
        classifyExpiredLease(
          {
            acquiredAt: new Date(now - MAX_LEASE_LIFETIME_MS).toISOString(),
            workspaceOnline: true,
            assignments: [running(1)],
          },
          now,
        ),
      ).toMatchObject({ action: "fail", reason: "max_runtime_exceeded" });
    });

    it("settles a finished Worker with its real outcome", () => {
      const done = { ...running(1), status: "completed" };
      expect(
        classifyExpiredLease(
          {
            acquiredAt: minutesAgo(48),
            workspaceOnline: true,
            assignments: [done],
          },
          now,
        ),
      ).toEqual({ action: "complete" });
      expect(
        classifyExpiredLease(
          {
            acquiredAt: minutesAgo(48),
            workspaceOnline: true,
            assignments: [],
          },
          now,
        ),
      ).toMatchObject({ action: "fail", reason: "workflow_lost" });
    });

    it("fails a finished step when later steps can no longer start", () => {
      const done = { ...running(1), status: "completed" };
      expect(
        classifyExpiredLease(
          {
            acquiredAt: minutesAgo(48),
            workspaceOnline: true,
            assignments: [done],
            remainingSteps: 1,
          },
          now,
        ),
      ).toEqual({
        action: "fail",
        reason: "workflow_lost",
        revokeAssignmentIds: [],
      });
    });
  });
});
