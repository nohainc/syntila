import { expect, it, vi } from "./helpers/vitest-compat";
import { pgD1, recordStatements } from "./helpers/pg-d1";
import { basicThread, T0 } from "./helpers/seed";
vi.mock("../../src/domain/routes/thread-policy.js", () => ({
  authorizeThreadAccess: vi.fn(async () => ({
    context: { userId: "U" },
    spaceId: "S",
  })),
}));
import { handleRetryWorkRequest } from "../../src/domain/routes/work-lifecycle.js";
import type { SecurityEnv } from "../../src/domain/routes/handlers.js";

it("requires reset approval before reserving or changing a failed request", async () => {
  const f = await pgD1();
  try {
    await f.sqlite.exec(`${basicThread({ user: "U", space: "S", thread: "T" })}
      INSERT INTO work_requests(id, thread_id, requested_by_user_id, mode, workflow_id, workflow_version, workflow_snapshot_json, status, created_at, updated_at)
        VALUES ('R', 'T', 'U', 'stateful', 'chat', 1, '${JSON.stringify({ steps: [{ kind: "implement" }] })}', 'failed', '${T0}', '${T0}');
      INSERT INTO workflow_tasks(id, work_request_id, step_kind, execution_mode, timeout_ms, prompt_profile_version, status, error, created_at, updated_at)
        VALUES ('task-1', 'R', 'implement', 'stateful_thread', 60000, 'v1', 'failed', 'context_limit_exceeded', '${T0}', '${T0}');`);
    const recorded = recordStatements(f.db);
    const response = await handleRetryWorkRequest(
      new Request("https://test/retry", {
        method: "POST",
        body: JSON.stringify({
          stepKind: "implement",
          sessionStrategy: "resume",
        }),
      }),
      { SYNTILA_DB: recorded.db } as unknown as SecurityEnv,
      "R",
    );
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({
      error: "clear_ai_history_required",
    });
    // Nothing was reserved or changed before the user agreed.
    expect(recorded.statements.length).toBeGreaterThan(0);
    expect(recorded.statements.every((text) => /^\s*(SELECT|WITH)/i.test(text))).toBe(true);
    const [{ status }] = [await f.sqlite.prepare("SELECT status FROM workflow_tasks WHERE id = 'task-1'").get() as { status: string }];
    expect(status).toBe("failed");
  } finally {
    await f.sqlite.close();
  }
});
