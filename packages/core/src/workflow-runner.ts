import {
  stepDependencyIds,
  stepInstanceId,
  validateBuiltinWorkflowDefinition,
  type BuiltinWorkflowDefinition,
  type BuiltinWorkflowStep,
} from "./thread.js";

export type WorkflowTaskStatus =
  "queued" | "running" | "waiting" | "completed" | "failed" | "cancelled";

export interface PlannedWorkflowTask {
  readonly id: string;
  readonly workRequestId: string;
  readonly step: BuiltinWorkflowStep;
  readonly dependencyTaskIds: readonly string[];
  readonly status: WorkflowTaskStatus;
  readonly attempt: number;
}

export function planWorkflowTasks(
  version: BuiltinWorkflowDefinition,
  workRequestId: string,
): readonly PlannedWorkflowTask[] {
  validateBuiltinWorkflowDefinition(version);
  if (!workRequestId) throw new Error("workRequestId is required");
  // Keyed by step-instance ID, which equals the kind for definitions that
  // never repeat a kind, so existing task IDs are unchanged.
  const ids = new Map(
    version.steps.map((step) => [
      stepInstanceId(step),
      `task-${workRequestId}-${stepInstanceId(step)}`,
    ]),
  );
  return [...version.steps]
    .sort((left, right) => left.order - right.order)
    .map((step) => ({
      id: ids.get(stepInstanceId(step))!,
      workRequestId,
      step,
      dependencyTaskIds: stepDependencyIds(step).map((dependency) =>
        ids.get(dependency)!,
      ),
      status: "queued" as const,
      attempt: 0,
    }));
}

export function readyWorkflowTasks(
  tasks: readonly PlannedWorkflowTask[],
): readonly PlannedWorkflowTask[] {
  const completed = new Set(
    tasks.filter((task) => task.status === "completed").map((task) => task.id),
  );
  return tasks.filter(
    (task) =>
      task.status === "queued" &&
      task.dependencyTaskIds.every((id) => completed.has(id)),
  );
}

export function workflowExecutionBatches(
  tasks: readonly PlannedWorkflowTask[],
): readonly (readonly PlannedWorkflowTask[])[] {
  const pending: PlannedWorkflowTask[] = tasks.map((task) => ({ ...task }));
  const batches: PlannedWorkflowTask[][] = [];
  while (pending.some((task) => task.status === "queued")) {
    const ready = readyWorkflowTasks(pending);
    if (ready.length === 0)
      throw new Error("Workflow task graph cannot make progress");
    batches.push([...ready]);
    const readyIds = new Set(ready.map((task) => task.id));
    for (let index = 0; index < pending.length; index++) {
      const task = pending[index]!;
      if (readyIds.has(task.id))
        pending[index] = { ...task, status: "completed" };
    }
  }
  return batches;
}

export function markWorkflowTaskResult(
  tasks: readonly PlannedWorkflowTask[],
  taskId: string,
  result: "completed" | "failed" | "waiting" | "cancelled",
): readonly PlannedWorkflowTask[] {
  if (!tasks.some((task) => task.id === taskId))
    throw new Error("Unknown workflow task");
  const next = tasks.map((task) =>
    task.id === taskId
      ? { ...task, status: result, attempt: task.attempt + 1 }
      : task,
  );
  if (result === "failed" || result === "cancelled") {
    const blocked = new Set([taskId]);
    let changed = true;
    while (changed) {
      changed = false;
      for (const task of next) {
        if (
          task.status === "queued" &&
          !blocked.has(task.id) &&
          task.dependencyTaskIds.some((id) => blocked.has(id))
        ) {
          blocked.add(task.id);
          changed = true;
        }
      }
    }
    return next.map((task) =>
      blocked.has(task.id) && task.id !== taskId
        ? { ...task, status: result }
        : task,
    );
  }
  return next;
}
