import { conversationFixture } from "./helpers/conversation";
import { expect, it } from "./helpers/vitest-compat";
import {
  recoverStaleAssignments,
  recordAssignmentError,
  recordAssignmentResult,
} from "../../src/domain/assignment-dispatcher.js";

/** The conversation fixture's Space "P", Workspace "WS" and Task "T", plus one assignment. */
async function fixture(
  status: string,
  columns: Record<string, string | number | null> = {},
) {
  const f = await conversationFixture();
  await f.assign("A1");
  await f.start("A1");
  const set = Object.entries({ attempt_id: "attempt-1", ...columns })
    .map(([column]) => `${column} = ?`)
    .join(", ");
  await f.sqlite
    .prepare(`UPDATE worker_assignments SET ${set} WHERE id = 'A1'`)
    .run(...Object.values({ attempt_id: "attempt-1", ...columns }));
  if (status !== "running")
    (await f.sqlite.prepare("UPDATE worker_assignments SET status = ? WHERE id = 'A1'").run(status));
  const assignment = async () =>
    (await f.sqlite
      .prepare(
        "SELECT status, output_json AS output, updated_at AS \"updatedAt\" FROM worker_assignments WHERE id = 'A1'",
      )
      .get()) as { status: string; output: unknown; updatedAt: string };
  const task = async () =>
    (await f.sqlite.prepare("SELECT status, error FROM workflow_tasks WHERE id = 'T'").get()) as {
      status: string;
      error: string | null;
    };
  return { ...f, assignment, task };
}

it("does not rewrite a terminal assignment or accept a stale attempt", async () => {
  const f = await fixture("running");
  // The assignment finished under attempt-2; a late result from attempt-1 arrives.
  (await f.sqlite.exec("UPDATE worker_assignments SET attempt_id = 'attempt-2' WHERE id = 'A1'"));
  await recordAssignmentResult(
    f.db as never,
    "A1",
    {
      assignmentId: "A1",
      status: "completed",
      output: { text: "late" },
      artifactIds: [],
      completedAt: "2026-10-14T12:00:00.000Z",
    },
    "attempt-1",
  );
  expect(await f.assignment()).toMatchObject({ status: "running", output: null });
  expect((await f.task()).status).toBe("running");
});

it("persists timeout as a terminal Cloud outcome", async () => {
  const f = await fixture("running");
  const recorded = await recordAssignmentError(
    f.db as never,
    "A1",
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
  expect(recorded).toBe(true);
  expect((await f.assignment()).status).toBe("timed_out");
  expect(await f.task()).toEqual({
    status: "failed",
    error: "The assignment exceeded its time limit.",
  });
});

it("does not fail an assignment that advanced after the recovery decision", async () => {
  const now = new Date("2026-10-13T12:00:00.000Z");
  const f = await fixture("acknowledged", {
    created_at: "2026-10-13T11:30:00.000Z",
    updated_at: "2026-10-13T11:30:00.000Z",
    queue_wait_timeout_ms: 60_000,
  });
  // The provider-start acknowledgement lands right after the scan read the
  // assignment as still acknowledged and expired.
  const racing = new Proxy(f.db as object, {
    get(target, prop, receiver) {
      const value = Reflect.get(target, prop, receiver);
      if (prop !== "sql") return value;
      return new Proxy(value, {
        async apply(fn, thisArg, args) {
          const rows = await Reflect.apply(fn, thisArg, args);
          if (Array.isArray(args[0]) && args[0].join("?").includes("FROM worker_assignments wa"))
            (await f.sqlite.exec(
              "UPDATE worker_assignments SET status = 'running', running_at = now(), updated_at = now() WHERE id = 'A1' AND status = 'acknowledged'",
            ));
          return rows;
        },
      });
    },
  });
  await recoverStaleAssignments(racing as never, now);
  expect((await f.assignment()).status).toBe("running");
  expect((await f.task()).status).toBe("running");
});

it("measures queue wait from admission, not from assignment creation", async () => {
  const now = new Date("2026-10-13T12:00:00.000Z");
  const columns = {
    // Created long ago (slow dispatch), admitted by the Service 10 s ago.
    created_at: "2026-10-13T11:00:00.000Z",
    updated_at: "2026-10-13T11:59:50.000Z",
    dispatched_at: "2026-10-13T11:59:40.000Z",
    acknowledged_at: "2026-10-13T11:59:50.000Z",
    start_permit_required: 1,
    queue_wait_timeout_ms: 60_000,
  };
  const f = await fixture("acknowledged", columns);
  await recoverStaleAssignments(f.db as never, now);
  expect((await f.assignment()).status).toBe("acknowledged");

  // Control: the same assignment admitted ten minutes ago has waited too long.
  const late = await fixture("acknowledged", {
    ...columns,
    updated_at: "2026-10-13T11:50:00.000Z",
    dispatched_at: "2026-10-13T11:49:50.000Z",
    acknowledged_at: "2026-10-13T11:50:00.000Z",
  });
  await recoverStaleAssignments(late.db as never, now);
  expect((await late.assignment()).status).not.toBe("acknowledged");
});
