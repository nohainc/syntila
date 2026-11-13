import { expect, it } from "./helpers/vitest-compat";
import {
  assignmentCommandDisposition,
  assignmentDeadlineViolation,
  classifyStepAssignmentOutcome,
} from "../../src/domain/assignment-delivery.js";

it("classifies redispatch without reopening terminal state", () => {
  expect(assignmentCommandDisposition("created")).toEqual({
    shouldSend: true,
    duplicate: false,
    terminal: false,
    accepted: false,
  });
  expect(assignmentCommandDisposition("dispatched").duplicate).toBe(true);
  expect(assignmentCommandDisposition("running")).toEqual({
    shouldSend: false,
    duplicate: true,
    terminal: false,
    accepted: true,
  });
  expect(assignmentCommandDisposition("completed")).toEqual({
    shouldSend: false,
    duplicate: true,
    terminal: true,
    accepted: true,
  });
});

it("keeps Research capacity waiting separate from readiness and execution deadlines", () => {
  const start = Date.parse("2026-11-01T00:00:00Z");
  const now = start + 24 * 60 * 60_000;
  const waiting = {
    status: "created",
    createdAt: new Date(start).toISOString(),
    cloudQueueReason: "workspace_capacity",
    cloudQueueSince: new Date(start).toISOString(),
    workflowId: "research",
    workflowVersion: 2,
    queueWaitTimeoutMs: 120_000,
  };
  expect(assignmentDeadlineViolation(waiting, now)).toBeNull();
  expect(
    assignmentDeadlineViolation({ ...waiting, workflowId: "direct" }, now),
  ).toMatchObject({ phase: "readiness_wait" });
  expect(
    assignmentDeadlineViolation({ ...waiting, workflowVersion: 1 }, now),
  ).toMatchObject({ phase: "readiness_wait" });
  // Switching to readiness starts that budget once, after the capacity wait.
  const offline = {
    ...waiting,
    cloudQueueReason: "service_not_ready",
    cloudQueueSince: new Date(now).toISOString(),
  };
  expect(assignmentDeadlineViolation(offline, now + 119_999)).toBeNull();
  expect(assignmentDeadlineViolation(offline, now + 120_000)).toMatchObject({
    phase: "readiness_wait",
  });
  expect(
    assignmentDeadlineViolation(
      {
        ...waiting,
        status: "running",
        runningAt: new Date(now).toISOString(),
        timeoutMs: 1000,
      },
      now + 1000,
    ),
  ).toMatchObject({ phase: "provider_execution" });
  expect(
    assignmentDeadlineViolation(
      {
        ...waiting,
        status: "dispatched",
        dispatchedAt: new Date(now).toISOString(),
      },
      now + 30_000,
    ),
  ).toMatchObject({ phase: "command_delivery" });
});
it("measures each deadline from its own event, not from creation", () => {
  const t0 = Date.parse("2026-10-05T14:00:00.000Z");
  const iso = (ms: number) => new Date(t0 + ms).toISOString();
  const base = { createdAt: iso(0) };

  // Delivery counts from the Gateway queueing the command.
  const dispatched = {
    ...base,
    status: "dispatched",
    dispatchedAt: iso(20_000),
  };
  expect(assignmentDeadlineViolation(dispatched, t0 + 49_999)).toBeNull();
  expect(assignmentDeadlineViolation(dispatched, t0 + 50_000)).toMatchObject({
    phase: "command_delivery",
    startedAt: iso(20_000),
  });
  // A persisted assignment that was never handed to the transport (the
  // durable queue for a Service that is not ready) waits up to its queue
  // wait limit, counted from creation, and is then finalized directly.
  expect(
    assignmentDeadlineViolation({ ...base, status: "created" }, t0 + 30_000),
  ).toBeNull();
  expect(
    assignmentDeadlineViolation(
      { ...base, status: "created", queueWaitTimeoutMs: 45_000 },
      t0 + 45_000,
    ),
  ).toMatchObject({ phase: "readiness_wait", limitMs: 45_000 });

  // Queue wait counts from admission and ignores time spent in delivery.
  const queued = {
    ...base,
    status: "acknowledged",
    dispatchedAt: iso(1_000),
    acknowledgedAt: iso(25_000),
    startPermitRequired: true,
    queueWaitTimeoutMs: 60_000,
  };
  expect(assignmentDeadlineViolation(queued, t0 + 84_999)).toBeNull();
  expect(assignmentDeadlineViolation(queued, t0 + 85_000)).toMatchObject({
    phase: "queue_wait",
    limitMs: 60_000,
  });

  // A start permit begins the startup window, independent of queue time.
  const permitted = {
    ...queued,
    startPermitIssuedAt: iso(100_000),
  };
  expect(assignmentDeadlineViolation(permitted, t0 + 129_999)).toBeNull();
  expect(assignmentDeadlineViolation(permitted, t0 + 130_000)).toMatchObject({
    phase: "startup",
    startedAt: iso(100_000),
  });

  // A Service without start permits keeps one combined window from admission.
  const legacy = {
    ...base,
    status: "acknowledged",
    acknowledgedAt: iso(10_000),
    queueWaitTimeoutMs: 5_000,
  };
  expect(assignmentDeadlineViolation(legacy, t0 + 39_999)).toBeNull();
  expect(assignmentDeadlineViolation(legacy, t0 + 40_000)).toMatchObject({
    phase: "queue_wait",
    limitMs: 30_000,
  });

  // Provider execution counts from provider start, not from creation or from
  // any later unrelated update to the row.
  const running = {
    ...base,
    status: "running",
    updatedAt: iso(500_000),
    runningAt: iso(60_000),
    timeoutMs: 120_000,
  };
  expect(assignmentDeadlineViolation(running, t0 + 179_999)).toBeNull();
  expect(assignmentDeadlineViolation(running, t0 + 180_000)).toMatchObject({
    phase: "provider_execution",
  });
  for (const status of ["completed", "failed", "cancelled", "reconciling"]) {
    expect(
      assignmentDeadlineViolation({ ...base, status }, t0 + 900_000),
    ).toBeNull();
  }
});

it("falls back to row timestamps for assignments from before phase stamps", () => {
  const t0 = Date.parse("2026-10-05T14:00:00.000Z");
  expect(
    assignmentDeadlineViolation(
      {
        status: "acknowledged",
        createdAt: new Date(t0 - 600_000).toISOString(),
        updatedAt: new Date(t0).toISOString(),
        queueWaitTimeoutMs: 1_000,
      },
      t0 + 29_999,
    ),
  ).toBeNull();
});

it("never replays a step after an ambiguous or side-effecting failure", () => {
  const failed = (extra: Record<string, unknown>) =>
    classifyStepAssignmentOutcome({
      status: "timed_out",
      hasOutput: false,
      revokedAfter: null,
      ...extra,
    });
  // A queued assignment that never started and was confirmed stopped is safe
  // to retry as a new attempt.
  expect(failed({ revokedAfter: "acknowledged" })).toMatchObject({
    kind: "failed",
    retryable: true,
  });
  expect(failed({ revokedAfter: "dispatched" })).toMatchObject({
    retryable: true,
  });
  // The provider had started: the stop is confirmed but effects may remain.
  expect(failed({ revokedAfter: "running" })).toMatchObject({
    kind: "failed",
    retryable: false,
  });
  // The stop is not confirmed: the process may still be alive.
  for (const status of ["revocation_pending", "reconciling"]) {
    expect(failed({ status, revokedAfter: "acknowledged" })).toMatchObject({
      kind: "failed",
      retryable: false,
    });
  }
  // Outcomes the Service reported itself keep their existing behavior.
  expect(
    failed({ status: "failed", errorMessage: "Engine crashed" }),
  ).toMatchObject({ message: "Engine crashed", retryable: true });
  expect(
    classifyStepAssignmentOutcome({
      status: "completed",
      hasOutput: true,
      revokedAfter: "running",
    }),
  ).toEqual({ kind: "completed" });
  expect(
    classifyStepAssignmentOutcome({
      status: "cancelled",
      hasOutput: false,
      revokedAfter: null,
    }),
  ).toEqual({ kind: "cancelled" });
});
