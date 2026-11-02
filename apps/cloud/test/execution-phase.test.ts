import { describe, expect, it } from "vitest";
import {
  FAILURE_CATEGORY_MESSAGES,
  deriveRequestExecutionPhase,
  presentExecution,
  type ExecutionAssignmentEvidence,
} from "../src/execution-phase.js";

const T = "2026-10-14T10:00:00.000Z";
const base = (e: ExecutionAssignmentEvidence) => presentExecution(e);

describe("executionPhase", () => {
  it("explains context overflow and allows a confirmed history reset", () => {
    const result = base({
      taskStatus: "failed",
      errorCode: "context_limit_exceeded",
    });
    expect(result.failureCategory).toBe("context_limit_exceeded");
    expect(result.failureCategoryMessage).toContain("Clear AI History");
    expect(result.retry).toEqual({
      allowed: true,
      requiresConfirmation: false,
    });
  });

  it("is submitted when no assignment exists", () => {
    expect(base({ taskStatus: "queued" }).executionPhase).toBe("submitted");
  });
  it("distinguishes Cloud capacity waiting from Service readiness", () => {
    expect(
      base({
        assignmentStatus: "created",
        cloudQueueReason: "workspace_capacity",
      }),
    ).toMatchObject({
      executionPhase: "queued",
      executionPhaseDetail:
        "All Worker slots are busy; starting when one is free",
    });
    expect(
      base({
        assignmentStatus: "created",
        cloudQueueReason: "service_not_ready",
      }),
    ).toMatchObject({ executionPhase: "waiting_for_service" });
  });
  it.each([
    [{ assignmentStatus: "created" }, "waiting_for_service"],
    [{ assignmentStatus: "dispatched", dispatchedAt: T }, "delivering"],
    [
      { assignmentStatus: "acknowledged", dispatchedAt: T, acknowledgedAt: T },
      "delivered",
    ],
    [
      {
        assignmentStatus: "acknowledged",
        acknowledgedAt: T,
        startupStage: "queued_for_slot",
      },
      "queued",
    ],
    [
      {
        assignmentStatus: "acknowledged",
        acknowledgedAt: T,
        startPermitIssuedAt: T,
      },
      "starting",
    ],
    [
      {
        assignmentStatus: "acknowledged",
        acknowledgedAt: T,
        startupStage: "engine_spawned",
      },
      "starting",
    ],
    [{ assignmentStatus: "running", runningAt: T }, "running"],
    [{ assignmentStatus: "completed" }, "completed"],
    [{ assignmentStatus: "cancelled" }, "cancelled"],
    [{ assignmentStatus: "failed" }, "failed"],
    [{ assignmentStatus: "timed_out" }, "failed"],
    [{ assignmentStatus: "revocation_pending" }, "uncertain"],
    [{ assignmentStatus: "reconciling" }, "uncertain"],
  ] as [ExecutionAssignmentEvidence, string][])(
    "%j -> %s",
    (evidence, phase) => {
      expect(base(evidence).executionPhase).toBe(phase);
    },
  );

  it("never reports running before provider start is observed", () => {
    for (const startupStage of [
      "worker_resolved",
      "slot_reserved",
      "engine_initialized",
    ]) {
      expect(
        base({
          assignmentStatus: "acknowledged",
          acknowledgedAt: T,
          startupStage,
        }).executionPhase,
      ).not.toBe("running");
    }
  });
});

describe("failureCategory", () => {
  const failed = (e: ExecutionAssignmentEvidence) =>
    base({ assignmentStatus: "failed", ...e }).failureCategory;

  it("is null unless failed or uncertain", () => {
    expect(base({ assignmentStatus: "running" }).failureCategory).toBeNull();
  });
  it("maps the verified evidence to fixed public categories", () => {
    expect(failed({ errorCode: "timeout" })).toBe("sync_incomplete");
    expect(failed({ errorCode: "timeout", dispatchedAt: T })).toBe(
      "service_unavailable",
    );
    expect(
      failed({
        errorCode: "timeout",
        dispatchedAt: T,
        acknowledgedAt: T,
        startupStage: "queued_for_slot",
      }),
    ).toBe("capacity_exceeded");
    expect(
      failed({
        errorCode: "timeout",
        dispatchedAt: T,
        acknowledgedAt: T,
        startPermitIssuedAt: T,
      }),
    ).toBe("startup_timeout");
    // A wait the Workspace reported for the Thread is never called a slot
    // shortage, and a timeout without a reported wait is not either.
    expect(
      failed({
        errorCode: "timeout",
        dispatchedAt: T,
        acknowledgedAt: T,
        startupStage: "waiting_for_space",
      }),
    ).toBe("thread_busy");
    expect(
      failed({
        errorCode: "timeout",
        dispatchedAt: T,
        acknowledgedAt: T,
        errorJson: JSON.stringify({
          error: {
            code: "timeout",
            details: {
              diagnostic: JSON.stringify({
                component: "workspace_service",
                stage: "space_wait",
              }),
            },
          },
        }),
      }),
    ).toBe("thread_busy");
    expect(
      failed({
        errorCode: "timeout",
        dispatchedAt: T,
        acknowledgedAt: T,
        startupStage: "worker_resolved",
      }),
    ).toBe("startup_timeout");
    expect(
      failed({
        errorCode: "execution_failed",
        dispatchedAt: T,
        acknowledgedAt: T,
      }),
    ).toBe("workspace_start_failed");
    expect(
      failed({
        errorCode: "model_not_supported",
        dispatchedAt: T,
        acknowledgedAt: T,
      }),
    ).toBe("profile_incompatible");
    expect(
      failed({
        errorCode: "space_folder_exists",
        dispatchedAt: T,
        acknowledgedAt: T,
      }),
    ).toBe("space_folder_confirmation_required");
    expect(
      failed({
        errorCode: "cli_not_found",
        dispatchedAt: T,
        acknowledgedAt: T,
      }),
    ).toBe("provider_start_failed");
    expect(
      failed({
        errorCode: "execution_failed",
        dispatchedAt: T,
        acknowledgedAt: T,
        runningAt: T,
      }),
    ).toBe("execution_failed");
    expect(base({ assignmentStatus: "reconciling" }).failureCategory).toBe(
      "state_uncertain",
    );
  });
  it("treats a workspace disconnect as a service problem even after start was granted", () => {
    const errorJson = JSON.stringify({
      error: {
        code: "provider_unavailable",
        details: {
          diagnostic: JSON.stringify({
            component: "cloud",
            stage: "workspace_disconnect",
          }),
        },
      },
    });
    expect(
      failed({
        errorCode: "provider_unavailable",
        dispatchedAt: T,
        acknowledgedAt: T,
        errorJson,
      }),
    ).toBe("service_unavailable");
  });
  it("ignores Service-authored diagnostics", () => {
    const errorJson = JSON.stringify({
      error: {
        details: {
          diagnostic: JSON.stringify({
            component: "service",
            stage: "workspace_disconnect",
          }),
        },
      },
    });
    expect(
      failed({
        errorCode: "execution_failed",
        dispatchedAt: T,
        acknowledgedAt: T,
        errorJson,
      }),
    ).not.toBe("service_unavailable");
  });
  it("only exposes fixed messages", () => {
    const messages = Object.values(FAILURE_CATEGORY_MESSAGES);
    expect(messages).toContain("Workspace Service is offline");
    const p = base({
      assignmentStatus: "failed",
      errorCode: "timeout",
      errorJson: JSON.stringify({
        error: { details: { diagnostic: "secret /Users/me/path" } },
      }),
    });
    expect(JSON.stringify(p)).not.toContain("secret");
  });
});

describe("retry advice", () => {
  const retry = (e: ExecutionAssignmentEvidence) =>
    base({ assignmentStatus: "failed", ...e }).retry;
  it("is safe before any start permit or provider start", () => {
    expect(retry({ dispatchedAt: T })).toEqual({
      allowed: true,
      requiresConfirmation: false,
    });
  });
  it("needs confirmation when the provider may have started", () => {
    expect(retry({ startPermitIssuedAt: T })).toEqual({
      allowed: true,
      requiresConfirmation: true,
    });
    expect(retry({ runningAt: T })?.requiresConfirmation).toBe(true);
    expect(
      retry({
        errorJson: JSON.stringify({
          revocation: { observedStatus: "running" },
        }),
      })?.requiresConfirmation,
    ).toBe(true);
    expect(
      retry({ startupStage: "engine_spawned" })?.requiresConfirmation,
    ).toBe(true);
  });
  it("is not allowed while the stop is unconfirmed", () => {
    expect(base({ assignmentStatus: "reconciling" }).retry).toEqual({
      allowed: false,
      requiresConfirmation: false,
    });
  });
  it("is absent for non-failed steps", () => {
    expect(base({ assignmentStatus: "running" }).retry).toBeNull();
  });
});

describe("request phase", () => {
  it("lets a terminal Work Request win over a stale running step", () => {
    expect(deriveRequestExecutionPhase("completed", ["running"])).toBe(
      "completed",
    );
    expect(deriveRequestExecutionPhase("failed", ["running"])).toBe("failed");
    expect(deriveRequestExecutionPhase("cancelled", ["queued"])).toBe(
      "cancelled",
    );
  });
  it("reports the first unfinished step", () => {
    expect(
      deriveRequestExecutionPhase("running", ["completed", "starting"]),
    ).toBe("starting");
  });
  it("does not report running for a request whose Workflow merely started", () => {
    expect(deriveRequestExecutionPhase("running", ["delivering"])).toBe(
      "delivering",
    );
    expect(deriveRequestExecutionPhase("running", [])).toBe("submitted");
  });
});
