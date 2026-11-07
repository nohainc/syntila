import { describe, expect, it } from "vitest";
import {
  BUILTIN_WORKFLOWS,
  BUILTIN_WORKFLOW_CATALOG,
  stepDependencyIds,
  markWorkflowTaskResult,
  planWorkflowTasks,
  readyWorkflowTasks,
  workflowExecutionBatches,
} from "../src/index.js";

describe("Work v1 workflow runner", () => {
  it("plans canonical built-ins into fixed dependency-preserving tasks", () => {
    for (const definition of Object.values(BUILTIN_WORKFLOWS)) {
      const tasks = planWorkflowTasks(definition, `request-${definition.id}`);
      expect(tasks).toHaveLength(definition.steps.length);
      expect(
        workflowExecutionBatches(tasks)
          .flat()
          .map((task) => task.step.kind),
      ).toEqual(definition.steps.map((step) => step.kind));
      for (const task of tasks) {
        // Dependencies are step-instance IDs (the kind for one-per-kind
        // definitions; research-1..n for Research v2).
        expect(task.dependencyTaskIds).toEqual(
          stepDependencyIds(task.step).map(
            (id) => `task-request-${definition.id}-${id}`,
          ),
        );
      }
    }
  });

  it("plans dependent tasks and uses StepKind as the task role", () => {
    const tasks = planWorkflowTasks(
      BUILTIN_WORKFLOW_CATALOG["chat:v2"]!,
      "request-1",
    );
    expect(tasks.map((task) => task.step.kind)).toEqual(["tool_call", "chat"]);
    expect(tasks.map((task) => task.dependencyTaskIds)).toEqual([
      [],
      ["task-request-1-tool"],
    ]);
  });

  it("propagates failure and cancellation to dependent Tasks", () => {
    const tasks = planWorkflowTasks(
      BUILTIN_WORKFLOW_CATALOG["chat:v2"]!,
      "request-failure",
    );
    const first = tasks[0]!;
    const failed = markWorkflowTaskResult(tasks, first.id, "failed");
    expect(
      failed.filter((task) => task.status === "failed").length,
    ).toBeGreaterThan(1);
    const cancelled = markWorkflowTaskResult(tasks, first.id, "cancelled");
    expect(cancelled.some((task) => task.status === "cancelled")).toBe(true);
    expect(readyWorkflowTasks(failed)).toHaveLength(0);
  });
});
