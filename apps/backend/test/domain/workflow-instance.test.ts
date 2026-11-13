import { describe, expect, it } from "./helpers/vitest-compat";
import { resolveWorkflowInstanceId } from "../../src/domain/routes/handlers.js";

function envWithWorkflowInstance(existing: string | null) {
  const statements: string[] = [];
  let stored = existing;
  const env = {
    SYNTILA_DB: {
      prepare(sql: string) {
        statements.push(sql);
        return {
          bind(...values: unknown[]) {
            return {
              async first() {
                return sql.startsWith("SELECT workflow_instance_id") && stored
                  ? { workflow_instance_id: stored }
                  : null;
              },
              async run() {
                if (sql.startsWith("UPDATE runs") && stored === null) {
                  stored = String(values[0]);
                }
                return {};
              },
            };
          },
        };
      },
    },
  };
  return { env: env as never, statements };
}

describe("workflow instance persistence", () => {
  it("stores the Cloud Workflow instance ID directly on the Run", async () => {
    const { env, statements } = envWithWorkflowInstance(null);

    await expect(
      resolveWorkflowInstanceId(env, "run-1", "request-1"),
    ).resolves.toBe("workflow-request-1");
    expect(statements).toHaveLength(3);
    expect(statements[1]).toContain("UPDATE runs");
    expect(statements[2]).toContain("SELECT workflow_instance_id");
    expect(statements.join("\n")).not.toContain("run_external_executions");
  });

  it("reuses the instance ID already stored on the Run", async () => {
    const { env, statements } = envWithWorkflowInstance("workflow-existing");

    await expect(
      resolveWorkflowInstanceId(env, "run-1", "request-1"),
    ).resolves.toBe("workflow-existing");
    expect(statements).toHaveLength(1);
  });
});
