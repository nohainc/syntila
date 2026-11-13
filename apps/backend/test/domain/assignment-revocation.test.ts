import { describe, expect, it } from "./helpers/vitest-compat";
import { ACTIVE_ASSIGNMENT_STATUS_SQL } from "../../src/domain/assignment-transitions.js";
import { transitionAssignment } from "../../src/domain/assignment-transitions.js";
import {
  cancelTaskAssignment,
  failOrRevokeDispatch,
  recordAssignmentResult,
  recoverStaleAssignments,
} from "../../src/domain/assignment-dispatcher.js";
import { assignmentCommandDisposition } from "../../src/domain/assignment-delivery.js";
import {
  beginAssignmentRevocation,
  deliverRevocation,
  escalateUnconfirmedRevocations,
  finalizeAssignmentRevocation,
  finalizeRevocationsOfRevokedRuntimes,
  revokeAssignment,
  type RevocationIntent,
} from "../../src/domain/assignment-revocation.js";
import { conversationFixture } from "./helpers/conversation.js";

const T0 = "2026-10-14T10:00:00.000Z";

const timeoutIntent: RevocationIntent = {
  status: "timed_out",
  reason: "The assignment exceeded its time limit.",
  source: "execution_deadline",
  failure: {
    error: {
      code: "timeout",
      message: "The assignment exceeded its time limit.",
      retryable: true,
    },
    failedAt: T0,
  },
};
const cancelIntent: RevocationIntent = {
  status: "cancelled",
  reason: "User cancelled",
  source: "manual_cancel",
};

async function seed(status: string) {
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
        "SELECT status, updated_at, error_json FROM worker_assignments WHERE id='A1'",
      )
      .get() as { status: string; updated_at: string; error_json: string };
  const task = () =>
    (
      f.sqlite
        .prepare("SELECT status FROM workflow_tasks WHERE id='T'")
        .get() as { status: string }
    ).status;
  /** A Gateway that either confirms the cancel or is unreachable. */
  const calls: Array<Record<string, unknown>> = [];
  const gateway = (online: boolean) =>
    ({
      SYNTILA_DB: f.db as never,
      SYNTILA_WORKSPACE_GATEWAY: {
        idFromName: (name: string) => name,
        get: () => ({
          fetch: async (_url: string, init: { body: string }) => {
            calls.push(JSON.parse(init.body));
            return online
              ? Response.json({ cancelled: true })
              : Response.json(
                  { error: "Workspace is offline" },
                  { status: 503 },
                );
          },
        }),
      },
    }) as never;
  const fence = {
    assignmentId: "A1",
    attemptId: "ATT1",
    executionWorkspaceId: "WS",
    runtimeIdentityId: "RT",
  };
  const activeCount = () =>
    (
      f.sqlite
        .prepare(
          `SELECT COUNT(*) AS n FROM worker_assignments
            WHERE id='A1' AND status IN (${ACTIVE_ASSIGNMENT_STATUS_SQL})`,
        )
        .get() as { n: number }
    ).n;
  return { ...f, row, task, calls, gateway, fence, activeCount };
}

describe("safe assignment revocation", () => {
  it("revokes a queued assignment past its deadline instead of failing it", async () => {
    const f = await seed("acknowledged");
    const result = await revokeAssignment(f.gateway(false), {
      assignmentId: "A1",
      attemptId: "ATT1",
      intent: timeoutIntent,
    });
    // The Service never answered, so Cloud cannot say the work stopped.
    expect(result).toMatchObject({ outcome: "pending", confirmed: false });
    expect(f.row().status).toBe("revocation_pending");
    expect(f.task()).toBe("queued");
    expect(f.activeCount()).toBe(1);
    expect(JSON.parse(f.row().error_json).revocation).toMatchObject({
      status: "timed_out",
      observedStatus: "acknowledged",
      commandId: "revoke:A1:ATT1",
    });
    // The cancel went out over the existing Gateway path, with a stable id.
    expect(f.calls).toHaveLength(1);
    expect((f.calls[0]!.payload as { commandId: string }).commandId).toBe(
      "revoke:A1:ATT1",
    );
  });

  it("cannot be redelivered as a start command once revocation began", async () => {
    const f = await seed("dispatched");
    await beginAssignmentRevocation(f.db as never, {
      assignmentId: "A1",
      intent: timeoutIntent,
    });
    for (const status of ["revocation_pending", "reconciling"]) {
      const disposition = assignmentCommandDisposition(status);
      expect(disposition.shouldSend).toBe(false);
      expect(disposition.terminal).toBe(false);
    }
  });

  it("ignores late admission and provider-start evidence for a revoked assignment", async () => {
    const f = await seed("dispatched");
    await beginAssignmentRevocation(f.db as never, {
      assignmentId: "A1",
      intent: timeoutIntent,
    });
    const stamp = f.row().updated_at;
    const admit = await transitionAssignment(f.db as never, {
      fence: f.fence,
      to: "acknowledged",
    });
    const started = await transitionAssignment(f.db as never, {
      fence: f.fence,
      to: "running",
      startTaskId: "T",
    });
    expect(admit).toMatchObject({ outcome: "superseded", applied: false });
    expect(started).toMatchObject({ outcome: "superseded", applied: false });
    expect(f.row().status).toBe("revocation_pending");
    expect(f.row().updated_at).toBe(stamp);
    expect(f.task()).toBe("queued");
  });

  it("writes the intended outcome only once the Service confirms the stop", async () => {
    for (const [intent, expectedStatus, expectedTask] of [
      [timeoutIntent, "timed_out", "failed"],
      [cancelIntent, "cancelled", "cancelled"],
      [
        {
          status: "failed",
          reason: "Workspace did not acknowledge",
          source: "startup_deadline",
          failure: {
            error: {
              code: "provider_unavailable",
              message: "x",
              retryable: true,
            },
            failedAt: T0,
          },
        } satisfies RevocationIntent,
        "failed",
        "failed",
      ],
    ] as const) {
      const f = await seed("running");
      const result = await revokeAssignment(f.gateway(true), {
        assignmentId: "A1",
        attemptId: "ATT1",
        intent,
      });
      expect(result).toMatchObject({ outcome: "pending", confirmed: true });
      expect(f.row().status).toBe(expectedStatus);
      expect(f.task()).toBe(expectedTask);
      expect(f.activeCount()).toBe(0);
    }
  });

  it("finalizes a never-delivered assignment immediately without contacting the Workspace", async () => {
    const f = await seed("created");
    const result = await revokeAssignment(f.gateway(true), {
      assignmentId: "A1",
      attemptId: "ATT1",
      intent: cancelIntent,
    });
    expect(result).toMatchObject({ outcome: "finalized", confirmed: true });
    expect(f.row().status).toBe("cancelled");
    expect(f.calls).toHaveLength(0);
  });

  it("keeps the first intent when revocations repeat or conflict", async () => {
    const f = await seed("running");
    expect(
      (
        await beginAssignmentRevocation(f.db as never, {
          assignmentId: "A1",
          intent: cancelIntent,
        })
      ).outcome,
    ).toBe("pending");
    const before = f.row();
    const second = await beginAssignmentRevocation(f.db as never, {
      assignmentId: "A1",
      intent: timeoutIntent,
    });
    expect(second.outcome).toBe("already_revoking");
    expect({ ...f.row() }).toEqual({ ...before });
    expect(JSON.parse(f.row().error_json).revocation.status).toBe("cancelled");
  });

  it("does not revoke an assignment that progressed after the decision", async () => {
    const f = await seed("running");
    const result = await beginAssignmentRevocation(f.db as never, {
      assignmentId: "A1",
      intent: timeoutIntent,
      onlyFrom: ["acknowledged"],
    });
    expect(result).toMatchObject({
      outcome: "superseded",
      currentStatus: "running",
    });
    expect(f.row().status).toBe("running");
  });

  it("rejects a revocation aimed at another attempt", async () => {
    const f = await seed("running");
    const result = await beginAssignmentRevocation(f.db as never, {
      assignmentId: "A1",
      attemptId: "OTHER",
      intent: timeoutIntent,
    });
    expect(result.outcome).toBe("stale");
    expect(f.row().status).toBe("running");
  });

  it("leaves a terminal assignment untouched", async () => {
    const f = await seed("completed");
    const result = await beginAssignmentRevocation(f.db as never, {
      assignmentId: "A1",
      intent: cancelIntent,
    });
    expect(result.outcome).toBe("terminal");
    expect(f.row().status).toBe("completed");
  });

  it("shows an unconfirmed revocation as reconciling while it keeps holding capacity", async () => {
    const f = await seed("running");
    await revokeAssignment(f.gateway(false), {
      assignmentId: "A1",
      attemptId: "ATT1",
      intent: timeoutIntent,
    });
    const soon = new Date(Date.parse(f.row().updated_at) + 5_000);
    expect(
      await escalateUnconfirmedRevocations(f.db as never, 20_000, soon),
    ).toEqual([]);
    const later = new Date(Date.parse(f.row().updated_at) + 60_000);
    expect(
      await escalateUnconfirmedRevocations(f.db as never, 20_000, later),
    ).toEqual(["A1"]);
    expect(f.row().status).toBe("reconciling");
    expect(f.activeCount()).toBe(1);
    expect(f.task()).toBe("queued");
    // Escalation happens once; the intent survives it.
    expect(
      await escalateUnconfirmedRevocations(f.db as never, 0, later),
    ).toEqual([]);
    // Later confirmation still resolves it, with the original intent.
    expect(await deliverRevocation(f.gateway(true), "A1")).toBe(true);
    expect(f.row().status).toBe("timed_out");
  });

  it("accepts a result that beats the stop", async () => {
    const f = await seed("running");
    await beginAssignmentRevocation(f.db as never, {
      assignmentId: "A1",
      intent: timeoutIntent,
    });
    const recorded = await recordAssignmentResult(
      f.db as never,
      "A1",
      {
        assignmentId: "A1",
        status: "completed",
        output: { text: "finished first" },
        artifactIds: [],
        completedAt: T0,
      },
      "ATT1",
    );
    expect(recorded).toBe(true);
    expect(f.row().status).toBe("completed");
    expect(f.task()).toBe("completed");
    // Nothing can reopen it afterwards.
    expect(
      await finalizeAssignmentRevocation(f.db as never, "A1", "ATT1"),
    ).toBe("terminal");
  });

  it("a dispatch failure after delivery is a revocation, but before delivery a plain failure", async () => {
    const failure = {
      error: {
        code: "provider_unavailable" as const,
        message: "Workspace Gateway dispatch did not accept the assignment",
        retryable: true,
      },
      failedAt: T0,
    };
    const undelivered = await seed("created");
    await failOrRevokeDispatch(
      undelivered.gateway(false),
      "A1",
      "ATT1",
      failure,
    );
    expect(undelivered.row().status).toBe("failed");

    // The Gateway persisted `dispatched` and then its response was lost.
    const ambiguous = await seed("dispatched");
    await failOrRevokeDispatch(ambiguous.gateway(false), "A1", "ATT1", failure);
    expect(ambiguous.row().status).toBe("revocation_pending");
    expect(ambiguous.task()).toBe("queued");
  });
});

describe("stale-assignment recovery revokes before it concludes", () => {
  const NOW = new Date("2026-10-14T12:00:00.000Z");

  async function overdue(status: string) {
    const f = await seed(status);
    f.sqlite
      .prepare(
        `UPDATE worker_assignments
            SET timeout_ms=60000, queue_wait_timeout_ms=60000,
                created_at='2026-10-14T11:00:00.000Z',
                updated_at='2026-10-14T11:00:00.000Z' WHERE id='A1'`,
      )
      .run();
    return f;
  }

  it("moves an overdue running assignment to revocation_pending, not timed_out", async () => {
    const f = await overdue("running");
    expect(await recoverStaleAssignments(f.db as never, NOW)).toBe(1);
    expect(f.row().status).toBe("revocation_pending");
    expect(f.task()).toBe("queued");
    expect(JSON.parse(f.row().error_json).revocation.source).toBe(
      "execution_deadline",
    );
  });

  it("completes the timeout when the Service confirms during recovery", async () => {
    const f = await overdue("acknowledged");
    expect(
      await recoverStaleAssignments(f.db as never, NOW, f.gateway(true)),
    ).toBe(1);
    expect(f.row().status).toBe("timed_out");
    expect(f.activeCount()).toBe(0);
  });

  it("re-sends the cancel on every pass until the Service confirms", async () => {
    const f = await overdue("running");
    await recoverStaleAssignments(f.db as never, NOW, f.gateway(false));
    expect(f.calls).toHaveLength(1);
    // Second pass: already revoking, so no new revocation but another cancel.
    expect(
      await recoverStaleAssignments(f.db as never, NOW, f.gateway(false)),
    ).toBe(0);
    expect(f.calls).toHaveLength(2);
    expect(f.row().status).toBe("revocation_pending");
    // Service back online: the same pass now resolves it.
    await recoverStaleAssignments(f.db as never, NOW, f.gateway(true));
    expect(f.row().status).toBe("timed_out");
  });

  it("revokes work whose Work Request was cancelled with a cancelled intent", async () => {
    const f = await seed("running");
    f.sqlite.exec("UPDATE work_requests SET status='cancelled' WHERE id='R'");
    await recoverStaleAssignments(f.db as never, NOW, f.gateway(true));
    expect(f.row().status).toBe("cancelled");
  });

  it("revokes a disconnected Workspace's assignment and an expired lease instead of concluding they failed", async () => {
    const disconnected = await seed("running");
    disconnected.sqlite.exec(
      `UPDATE execution_workspaces SET status='offline', updated_at='2026-10-14T11:00:00.000Z' WHERE id='WS'`,
    );
    disconnected.sqlite
      .prepare(
        "UPDATE worker_assignments SET timeout_ms=900000, updated_at='2026-10-14T11:00:00.000Z' WHERE id='A1'",
      )
      .run();
    await recoverStaleAssignments(disconnected.db as never, NOW);
    expect(disconnected.row().status).toBe("revocation_pending");
    expect(JSON.parse(disconnected.row().error_json).revocation.source).toBe(
      "workspace_disconnected",
    );

    const leased = await seed("running");
    leased.sqlite.exec(
      `INSERT INTO workspace_space_grants(id,space_id,workspace_id,granted_by_user_id,created_at,updated_at,expires_at)
       VALUES('G','P','WS','U','now','now','2026-10-14T11:59:59.000Z')`,
    );
    leased.sqlite
      .prepare(
        "UPDATE worker_assignments SET workspace_space_grant_id='G', timeout_ms=900000, updated_at=? WHERE id='A1'",
      )
      .run(NOW.toISOString());
    await recoverStaleAssignments(leased.db as never, NOW);
    expect(leased.row().status).toBe("revocation_pending");
    expect(JSON.parse(leased.row().error_json).revocation.source).toBe(
      "grant_expired",
    );
  });

  it("does not revoke an assignment that is healthy", async () => {
    const f = await seed("running");
    f.sqlite
      .prepare(
        "UPDATE worker_assignments SET timeout_ms=900000, updated_at=? WHERE id='A1'",
      )
      .run(NOW.toISOString());
    expect(await recoverStaleAssignments(f.db as never, NOW)).toBe(0);
    expect(f.row().status).toBe("running");
  });
});

describe("user cancellation", () => {
  it("reports cancelled only when the Workspace confirms the process stopped", async () => {
    const f = await seed("running");
    expect(
      await cancelTaskAssignment(
        f.gateway(false),
        "WS",
        "A1",
        "User cancelled",
      ),
    ).toEqual({ cancelled: false });
    // Unconfirmed: still revoking, still holding capacity, task untouched.
    expect(f.row().status).toBe("revocation_pending");
    expect(f.task()).toBe("queued");
    expect(f.activeCount()).toBe(1);
    // A retry resends the cancel and succeeds once the Workspace answers.
    expect(
      await cancelTaskAssignment(f.gateway(true), "WS", "A1", "User cancelled"),
    ).toEqual({ cancelled: true });
    expect(f.row().status).toBe("cancelled");
    expect(f.task()).toBe("cancelled");
  });
  it("finalizes a pending revocation whose runtime identity was revoked", async () => {
    const f = await seed("running");
    await beginAssignmentRevocation(f.db as never, {
      assignmentId: "A1",
      attemptId: "ATT1",
      intent: cancelIntent,
    });
    expect(f.row().status).toBe("revocation_pending");
    // The owning runtime is still current: nothing to finalize.
    expect(
      await finalizeRevocationsOfRevokedRuntimes(f.db as never, "WS"),
    ).toEqual([]);
    expect(f.row().status).toBe("revocation_pending");
    // The Workspace re-registers; the old identity is revoked and can never
    // acknowledge a cancel again.
    f.sqlite.exec(
      "UPDATE workspace_runtime_identities SET revoked_at='now' WHERE id='RT'",
    );
    expect(
      await finalizeRevocationsOfRevokedRuntimes(f.db as never, "WS"),
    ).toEqual(["A1"]);
    expect(f.row().status).toBe("cancelled");
    expect(f.activeCount()).toBe(0);
  });

  it("finalizes through deliverRevocation without messaging the Gateway", async () => {
    const f = await seed("running");
    await beginAssignmentRevocation(f.db as never, {
      assignmentId: "A1",
      attemptId: "ATT1",
      intent: cancelIntent,
    });
    f.sqlite.exec(
      "UPDATE workspace_runtime_identities SET revoked_at='now' WHERE id='RT'",
    );
    expect(await deliverRevocation(f.gateway(false), "A1")).toBe(true);
    expect(f.row().status).toBe("cancelled");
    expect(f.calls).toHaveLength(0);
  });
});
