/**
 * Concurrency (claude/concurrency-plan.md): a Free requester has one
 * execution slot. Parallel dispatches without the global writer lock must
 * admit exactly one assignment; the others wait.
 */
import { expect, it, vi } from "./helpers/vitest-compat";
import { dispatchTaskAssignment } from "../../src/domain/assignment-dispatcher.js";
import { PgD1Database } from "./helpers/pg-d1-adapter";
import { conversationFixture } from "./helpers/conversation.js";

const scheduler = vi.hoisted(() => ({ selectSpaceExecutionTarget: vi.fn() }));
vi.mock("../../src/domain/scheduler.js", () => scheduler);

it("admits one assignment for parallel dispatches of a Free requester", async () => {
  const f = await conversationFixture();
  f.sqlite.exec(`
    INSERT INTO runs(id,space_id,status,created_at,updated_at) VALUES('RUN','P','running','now','now');
    INSERT INTO workflow_tasks(id,work_request_id,step_instance_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at)
    SELECT 'T' || n, 'R', 'step-' || n, 'chat', 'stateless_read', 1000, 'chat:v1', 'running', 'now', 'now' FROM generate_series(2, 6) n;`);
  scheduler.selectSpaceExecutionTarget.mockResolvedValue({
    spaceId: "P", workspaceId: "WS", workspaceRuntimeIdentityId: "RT", workspaceSpaceGrantId: null,
    workerId: "worker-a", workerTypeId: "chatgpt", engineVersion: "1.3.0", model: null,
    maxConcurrentAssignments: 10, effectivePermissions: ["repository:read"],
    permissionSnapshot: { profileDefinitionId: "chatgpt-codex", profileReleaseVersion: 3 },
    selectionExplanation: {}, executionClass: "stateless_read", readOnly: true,
  });
  const db = new PgD1Database((f.db as unknown as { sql: any }).sql);
  const env = {
    SYNTILA_DB: db,
    SYNTILA_WORKSPACE_GATEWAY: { idFromName: () => "WS", get: () => ({ fetch: async () => Response.json({}) }) },
  } as any;
  const tasks = ["T", "T2", "T3", "T4", "T5", "T6"];
  await Promise.allSettled(tasks.map((taskId) =>
    dispatchTaskAssignment(env, {
      workspaceId: "WS", runId: "RUN", taskId,
      task: { id: taskId, spaceId: "P", requestedByUserId: "U", role: "collaborator", objective: "x", workRequestId: "R", sessionPolicy: "stateless" },
    } as any)));
  const live = f.sqlite.prepare(
    "SELECT count(*)::int AS n FROM worker_assignments WHERE requested_by_user_id = 'U' AND status NOT IN ('completed','failed','cancelled','timed_out')",
  ).get() as { n: number };
  expect(live.n).toBe(1);
});
