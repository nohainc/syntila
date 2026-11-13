import { expect, it } from "./helpers/vitest-compat";
import {
  recoverStaleAssignments,
  recordAssignmentError,
  recordAssignmentResult,
} from "../../src/domain/assignment-dispatcher.js";

it("does not rewrite a terminal assignment or accept a stale attempt", async () => {
  let writes = 0;
  const db = {
    prepare() {
      return {
        bind: () => ({
          first: async () => ({
            status: "completed",
            task_id: "task-1",
            attempt_id: "attempt-2",
          }),
          run: async () => {
            writes += 1;
          },
        }),
      };
    },
  };
  await recordAssignmentResult(
    db as never,
    "assignment-1",
    {
      assignmentId: "assignment-1",
      status: "completed",
      output: { text: "late" },
      artifactIds: [],
      completedAt: "2026-10-14T12:00:00.000Z",
    },
    "attempt-1",
  );
  expect(writes).toBe(0);
});

it("persists timeout as a terminal Cloud outcome", async () => {
  const updates: unknown[][] = [];
  const db = {
    prepare(sql: string) {
      return {
        bind: (...values: unknown[]) => ({
          first: async () => ({
            status: "running",
            task_id: "task-1",
            attempt_id: "attempt-1",
          }),
          run: async () => {
            if (sql.includes("UPDATE")) updates.push(values);
          },
        }),
      };
    },
  };
  await recordAssignmentError(
    db as never,
    "assignment-1",
    {
      error: {
        code: "timeout",
        message: "The assignment exceeded its time limit.",
        retryable: true,
      },
      failedAt: "2026-10-14T12:00:00.000Z",
    },
    "attempt-1",
  );
  expect(updates[0]?.[0]).toBe("timed_out");
});

it("does not fail an assignment that advanced after the recovery decision", async () => {
  const now = new Date("2026-10-13T12:00:00.000Z");
  const expired = {
    id: "assignment-late-start",
    attemptId: "attempt-1",
    status: "acknowledged",
    createdAt: "2026-10-13T11:30:00.000Z",
    updatedAt: "2026-10-13T11:30:00.000Z",
    timeoutMs: null,
    queueWaitTimeoutMs: 60_000,
    workspaceStatus: "online",
    workspaceUpdatedAt: now.toISOString(),
    grantExpiresAt: null,
  };
  const writes: string[] = [];
  const db = {
    prepare(sql: string) {
      return {
        all: async () => ({ results: [expired] }),
        bind: () => ({
          all: async () => ({ results: [] }),
          // The provider-start acknowledgement landed after the scan.
          first: async () => ({
            status: "running",
            task_id: "task-1",
            attempt_id: "attempt-1",
            error_json: null,
          }),
          run: async () => {
            if (sql.includes("UPDATE")) writes.push(sql);
            return { meta: { changes: 1 } };
          },
        }),
      };
    },
  };
  await recoverStaleAssignments(db as never, now);
  expect(writes).toHaveLength(0);
});

it("measures queue wait from admission, not from assignment creation", async () => {
  const now = new Date("2026-10-13T12:00:00.000Z");
  const queued = {
    id: "assignment-slow-dispatch",
    attemptId: "attempt-1",
    status: "acknowledged",
    // Created long ago (slow dispatch), admitted by the Service 10 s ago.
    createdAt: "2026-10-13T11:00:00.000Z",
    updatedAt: "2026-10-13T11:59:50.000Z",
    dispatchedAt: "2026-10-13T11:59:40.000Z",
    acknowledgedAt: "2026-10-13T11:59:50.000Z",
    permitRequired: 1,
    permitIssuedAt: null,
    runningAt: null,
    timeoutMs: null,
    queueWaitTimeoutMs: 60_000,
    workspaceStatus: "online",
    workspaceUpdatedAt: now.toISOString(),
    grantExpiresAt: null,
    workRequestStatus: null,
  };
  const writes: string[] = [];
  const db = {
    prepare(sql: string) {
      return {
        all: async () => ({ results: [queued] }),
        bind: () => ({
          all: async () => ({ results: [] }),
          first: async () => null,
          run: async () => {
            if (sql.includes("UPDATE")) writes.push(sql);
            return { meta: { changes: 1 } };
          },
        }),
      };
    },
  };
  await recoverStaleAssignments(db as never, now);
  expect(writes).toHaveLength(0);
});
