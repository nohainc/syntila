import { expect, it } from "./helpers/vitest-compat";
import { BUILTIN_WORKFLOWS } from "@syntila/core";
import { resolveWorkflowStepExecutionConfig } from "../../src/domain/routes/workflow-step-execution-config.js";
it.each(["chat", "direct", "plan_implement"] as const)(
  "snapshots %s execution without guessing Auto model/effort",
  (id) => {
    const workflow = BUILTIN_WORKFLOWS[id];
    expect(
      resolveWorkflowStepExecutionConfig(
        workflow,
        "worker",
        { profileId: "signed", profileReleaseVersion: 3 },
        null,
        null,
      ),
    ).toEqual({
      schemaVersion: 1,
      workerId: "worker",
      profileId: "signed",
      profileReleaseVersion: 3,
      modelId: null,
      effort: null,
      workflowId: id,
      workflowVersion: workflow.version,
    });
  },
);
it.each([
  undefined,
  { profileId: "", profileReleaseVersion: 1 },
  { profileId: "p", profileReleaseVersion: 0 },
  { profileId: "p", profileReleaseVersion: 1.5 },
])("rejects unavailable or invalid Profile evidence", (profile) => {
  expect(() =>
    resolveWorkflowStepExecutionConfig(
      BUILTIN_WORKFLOWS.chat,
      "worker",
      profile,
      null,
      null,
    ),
  ).toThrow("unavailable");
});
