import { describe, expect, it } from "vitest";
import { grantStartPermit } from "../src/assignment-start-permit.js";
import {
  beginAssignmentRevocation,
  revokeAssignment,
  type RevocationIntent,
} from "../src/assignment-revocation.js";
import { conversationFixture } from "./helpers/conversation.js";

const T0 = "2026-10-14T10:00:00.000Z";
const NOW = new Date("2026-10-14T10:00:05.000Z");

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

async function seed(status: string, permitRequired = true) {
  const f = await conversationFixture();
  f.sqlite.exec(
    "INSERT INTO runs(id,space_id,status,created_at,updated_at) VALUES('RUN','P','running','now','now')",
  );
  f.assign("A1");
  f.sqlite
    .prepare(
      `UPDATE worker_assignments
          SET run_id='RUN', attempt_id='ATT1', idempotency_key='IDEM1',
              status=?, updated_at=?, start_permit_required=? WHERE id='A1'`,
    )
    .run(status, T0, permitRequired ? 1 : 0);
  f.sqlite.exec(
    "UPDATE workflow_tasks SET status='queued', started_at=NULL WHERE id='T'",
  );
  const row = () =>
    f.sqlite
      .prepare(
        "SELECT status, start_permit_issued_at AS issued FROM worker_assignments WHERE id='A1'",
      )
      .get() as { status: string; issued: string | null };
  const task = () =>
    (
      f.sqlite
        .prepare("SELECT status FROM workflow_tasks WHERE id='T'")
        .get() as { status: string }
    ).status;
  const fence = {
    assignmentId: "A1",
    attemptId: "ATT1",
    executionWorkspaceId: "WS",
    runtimeIdentityId: "RT",
  };
  const permit = () => grantStartPermit(f.db as never, fence, NOW);
  /** A Gateway whose Workspace is unreachable. */
  const offline = {
    SYNTILA_DB: f.db as never,
    SYNTILA_WORKSPACE_GATEWAY: {
      idFromName: (name: string) => name,
      get: () => ({
        fetch: async () =>
          Response.json({ error: "Workspace is offline" }, { status: 503 }),
      }),
    },
  } as never;
  return { ...f, row, task, fence, permit, offline };
}

describe("start permit", () => {
  it("replays the original grant without extending the startup deadline", async () => {
    const f = await seed("acknowledged");
    try {
      const first = await f.permit();
      const replay = await grantStartPermit(
        f.db as never,
        f.fence,
        new Date(NOW.getTime() + 60_000),
      );
      expect(replay).toEqual(first);
      expect(f.row().issued).toBe(NOW.toISOString());
    } finally {
      f.sqlite.close();
    }
  });

  it.each(["revoke", "replace-runtime"])(
    "denies a grant when %s wins between admission and the permit write",
    async (interruption) => {
      for (let iteration = 0; iteration < 3; iteration += 1) {
        const f = await seed("acknowledged");
        const original = f.db.prepare.bind(f.db);
        let interrupted = false;
        const db = {
          prepare(sql: string) {
            if (sql.includes("SET start_permit_issued_at") && !interrupted) {
              interrupted = true;
              if (interruption === "replace-runtime") {
                f.sqlite.exec(
                  "INSERT INTO workspace_runtime_identities(id,workspace_id,credential_token_hash,installation_id,created_at) VALUES('replacement','WS','replacement-hash','replacement-installation','now')",
                );
                f.sqlite.exec(
                  "UPDATE worker_assignments SET runtime_identity_id = 'replacement' WHERE id='A1'",
                );
              } else {
                f.sqlite.exec(
                  "UPDATE worker_assignments SET status = 'revocation_pending' WHERE id='A1'",
                );
              }
            }
            return original(sql);
          },
        };
        try {
          expect(
            await grantStartPermit(db as never, f.fence, NOW),
          ).toMatchObject({ granted: false });
          expect(interrupted).toBe(true);
          expect(f.row().issued).toBeNull();
        } finally {
          f.sqlite.close();
        }
      }
    },
    20000,
  );
  it("grants a short-lived permit while the assignment is Acknowledged", async () => {
    const f = await seed("acknowledged");
    const decision = await f.permit();
    expect(decision).toMatchObject({ granted: true });
    if (!decision.granted) throw new Error("expected a grant");
    expect(decision.permitId).toBe(`permit:A1:ATT1:${NOW.getTime()}`);
    expect(Date.parse(decision.expiresAt)).toBe(NOW.getTime() + 30_000);
    expect(f.row().issued).toBe(NOW.toISOString());
    // A repeated request after a lost grant is granted again.
    expect((await f.permit()).granted).toBe(true);
  });

  it("treats a permit request that overtakes admission as admission evidence", async () => {
    const f = await seed("dispatched");
    expect((await f.permit()).granted).toBe(true);
    expect(f.row().status).toBe("acknowledged");
  });

  it("is denied for every revoked, finished or foreign assignment", async () => {
    const revoking = await seed("running");
    await beginAssignmentRevocation(revoking.db as never, {
      assignmentId: "A1",
      intent: timeoutIntent,
    });
    expect(await revoking.permit()).toEqual({
      granted: false,
      reason: "revoked",
    });

    const finished = await seed("cancelled");
    expect(await finished.permit()).toEqual({
      granted: false,
      reason: "terminal",
    });

    const started = await seed("running");
    expect(await started.permit()).toEqual({
      granted: false,
      reason: "already_started",
    });

    const other = await seed("acknowledged");
    expect(
      await grantStartPermit(
        other.db as never,
        { ...other.fence, attemptId: "OTHER" },
        NOW,
      ),
    ).toEqual({ granted: false, reason: "stale" });
    expect(other.row().issued).toBeNull();
  });
});

describe("revocation with start fencing", () => {
  it("finalizes at once, without the Service, when no permit was ever issued", async () => {
    const f = await seed("acknowledged");
    const result = await revokeAssignment(f.offline, {
      assignmentId: "A1",
      attemptId: "ATT1",
      intent: timeoutIntent,
    });
    // The Workspace never answered, yet the outcome is certain: it must
    // obtain a permit to launch, and none can be granted any more.
    expect(result).toMatchObject({
      outcome: "finalized",
      fenced: true,
      confirmed: true,
      permitIssued: false,
    });
    expect(f.row().status).toBe("timed_out");
    expect(f.task()).toBe("failed");
    // The queued command can no longer start.
    expect(await f.permit()).toEqual({ granted: false, reason: "terminal" });
  });

  it("fences an assignment that was dispatched but never admitted", async () => {
    const f = await seed("dispatched");
    const result = await beginAssignmentRevocation(f.db as never, {
      assignmentId: "A1",
      attemptId: "ATT1",
      intent: timeoutIntent,
    });
    expect(result).toMatchObject({ outcome: "finalized", fenced: true });
    expect(f.row().status).toBe("timed_out");
  });

  it("waits for the Service once a permit was issued", async () => {
    const f = await seed("acknowledged");
    expect((await f.permit()).granted).toBe(true);
    const result = await revokeAssignment(f.offline, {
      assignmentId: "A1",
      attemptId: "ATT1",
      intent: timeoutIntent,
    });
    expect(result).toMatchObject({
      outcome: "pending",
      permitIssued: true,
      confirmed: false,
    });
    expect(f.row().status).toBe("revocation_pending");
    expect(f.task()).toBe("queued");
  });

  it("never fences a Service that does not use permits", async () => {
    const f = await seed("acknowledged", false);
    const result = await revokeAssignment(f.offline, {
      assignmentId: "A1",
      attemptId: "ATT1",
      intent: timeoutIntent,
    });
    expect(result).toMatchObject({ outcome: "pending", confirmed: false });
    expect(f.row().status).toBe("revocation_pending");
  });

  it("never fences an assignment that was already running", async () => {
    const f = await seed("running");
    const result = await revokeAssignment(f.offline, {
      assignmentId: "A1",
      attemptId: "ATT1",
      intent: timeoutIntent,
    });
    expect(result).toMatchObject({ outcome: "pending", confirmed: false });
    expect(f.row().status).toBe("revocation_pending");
  });

  it("lets only one of a racing grant and revocation win", async () => {
    for (const order of ["grant-first", "revoke-first"] as const) {
      const f = await seed("acknowledged");
      const grant = () => f.permit();
      const revoke = () =>
        beginAssignmentRevocation(f.db as never, {
          assignmentId: "A1",
          attemptId: "ATT1",
          intent: timeoutIntent,
        });
      const [first, second] =
        order === "grant-first"
          ? await Promise.all([grant(), revoke()])
          : await Promise.all([revoke(), grant()]);
      const granted = (order === "grant-first" ? first : second) as Awaited<
        ReturnType<typeof grant>
      >;
      const revoked = (order === "grant-first" ? second : first) as Awaited<
        ReturnType<typeof revoke>
      >;
      // Invariant, whatever the interleaving: a fenced finalization and a
      // granted permit never both happen.
      expect(Boolean(granted.granted) && Boolean(revoked.fenced)).toBe(false);
      if (!granted.granted) {
        expect(f.row().issued).toBeNull();
      } else {
        expect(f.row().issued).not.toBeNull();
        expect(f.row().status).toBe("revocation_pending");
      }
    }
  });
});
