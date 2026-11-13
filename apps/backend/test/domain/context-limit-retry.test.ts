import { expect, it, vi } from "./helpers/vitest-compat";
vi.mock("../../src/domain/routes/thread-policy.js", () => ({
  authorizeThreadAccess: vi.fn(async () => ({
    context: { userId: "U" },
    spaceId: "S",
  })),
}));
import { handleRetryWorkRequest } from "../../src/domain/routes/work-lifecycle.js";
import type { SecurityEnv } from "../../src/domain/routes/handlers.js";

it("requires reset approval before reserving or changing a failed request", async () => {
  const prepare = vi.fn((sql: string) => {
    let row: unknown;
    if (sql.startsWith("SELECT thread_id")) row = { threadId: "T" };
    else if (sql.startsWith("SELECT role")) row = { role: "owner" };
    else if (sql.includes("wr.workflow_id"))
      row = {
        threadId: "T",
        status: "failed",
        workflowSnapshotJson: JSON.stringify({
          steps: [{ kind: "implement" }],
        }),
      };
    else if (sql.includes("wt.status"))
      row = { status: "failed", error: "context_limit_exceeded" };
    else throw new Error(`Unexpected SQL before consent: ${sql}`);
    return { bind: () => ({ first: async () => row }) };
  });
  const response = await handleRetryWorkRequest(
    new Request("https://test/retry", {
      method: "POST",
      body: JSON.stringify({
        stepKind: "implement",
        sessionStrategy: "resume",
      }),
    }),
    { SYNTILA_DB: { prepare } } as unknown as SecurityEnv,
    "R",
  );
  expect(response.status).toBe(409);
  expect(await response.json()).toMatchObject({
    error: "clear_ai_history_required",
  });
  expect(prepare.mock.calls.every(([sql]) => sql.startsWith("SELECT"))).toBe(
    true,
  );
});
