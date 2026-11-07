import { expect, it } from "vitest";
import {
  ContextEngine,
  emptyContextState,
  projectContextState,
  type ContextEngineInput,
  type ContextHistoryFact,
  type ContextState,
  selectWorkflowContext,
  type WorkflowExecutionContext,
} from "../src/index.js";
const fact = <T>(value: T, revision = 1, sequence = 1) => ({
  value,
  revision,
  sequence,
});
const state: ContextState = {
  objective: fact("Ship the change"),
  importantDecisions: { d: fact("Use generic Profiles") },
  constraints: { c: fact("Preserve history") },
  currentState: fact("Implementation in progress", 2, 7),
  openIssues: { i: fact("Pending verification", 2, 8) },
  artifacts: { a: fact({ id: "artifact-A", contentDigest: "digest" }, 2, 9) },
  workflowState: fact(
    {
      workflowId: "direct",
      workflowVersion: 2,
      workRequestId: "R",
      status: "running",
      steps: [{ id: "T", kind: "direct", status: "running", attempt: 0 }],
    },
    2,
    10,
  ),
  summary: fact("Validated summary", 1, 4),
};
const history: ContextHistoryFact[] = [
  {
    sequence: 1,
    contextRevision: 1,
    kind: "user_message",
    eventType: "message.user_created",
    actorType: "user",
    actorId: "U",
    text: "First request",
    metadata: {},
  },
  {
    sequence: 2,
    contextRevision: 1,
    kind: "worker_response",
    eventType: "response.completed",
    actorType: "worker",
    actorId: "W",
    text: "Answer",
    metadata: { workerSessionId: "own" },
  },
  {
    sequence: 8,
    contextRevision: 1,
    kind: "worker_response",
    eventType: "response.completed",
    actorType: "worker",
    actorId: "other",
    text: "Late reply",
    metadata: { workerSessionId: "other" },
  },
  {
    sequence: 9,
    contextRevision: 2,
    kind: "user_message",
    eventType: "message.user_created",
    actorType: "user",
    actorId: "U",
    text: "Next request",
    metadata: {},
  },
];
const input: ContextEngineInput = {
  conversationId: "C",
  contextRevision: 2,
  throughSequence: 10,
  history,
  state,
};
const engine = new ContextEngine();
it("assembles bootstrap and stateless components with explicit workflow state", () => {
  const before = JSON.stringify(input);
  const bootstrap = engine.bootstrap(input);
  const stateless = engine.stateless(input);
  expect(bootstrap.kind).toBe("BootstrapContext");
  expect(stateless.kind).toBe("StatelessContext");
  expect(bootstrap.context).toEqual(state);
  expect(stateless.context.workflowState!.value.steps[0]!.status).toBe(
    "running",
  );
  expect(bootstrap.history).toEqual(history);
  expect(bootstrap.recentTurns).toEqual(history);
  expect(engine.bootstrap(input)).toEqual(bootstrap);
  expect(JSON.stringify(input)).toBe(before);
  (bootstrap.context.constraints as Record<string, unknown>).extra = "mutated";
  expect(input.state.constraints).not.toHaveProperty("extra");
});
it("selects changed state, workflow progress, missed turns and late foreign replies for deltas", () => {
  const delta = engine.delta(input, 1, 6, "own");
  expect(delta.kind).toBe("DeltaContext");
  expect(delta.history.map((entry) => entry.sequence)).toEqual([8, 9]);
  expect(delta.context.objective).toBeNull();
  expect(delta.context.importantDecisions).toEqual({});
  expect(delta.context.openIssues.i!.value).toBe("Pending verification");
  expect(delta.context.workflowState).toEqual(state.workflowState);
  expect(engine.delta(input, 2, 10, "own").history).toEqual([]);
});
it("spaces only versioned Syntila facts, never claims inside worker text", () => {
  expect(projectContextState(history)).toEqual(emptyContextState());
  const committed: ContextHistoryFact = {
    sequence: 3,
    contextRevision: 1,
    kind: "context_event",
    eventType: "context.fact_updated",
    actorType: "syntila",
    actorId: null,
    text: null,
    metadata: {
      schemaVersion: 1,
      section: "importantDecisions",
      id: "decision",
      value: "Accepted choice",
    },
  };
  expect(
    projectContextState([committed]).importantDecisions.decision!.value,
  ).toBe("Accepted choice");
  const cleared = projectContextState(
    [
      {
        ...committed,
        metadata: { schemaVersion: 1, section: "objective", value: null },
      },
    ],
    state,
  );
  expect(cleared.objective!.value).toBeNull();
  const delta = engine.delta(
    {
      ...input,
      state: { ...emptyContextState(), objective: cleared.objective },
    },
    1,
    2,
  );
  expect(delta.context.objective!.value).toBeNull();
  expect(() =>
    projectContextState([
      { ...committed, metadata: { ...committed.metadata, id: "__proto__" } },
    ]),
  ).toThrow(/identity/);
});
it("preserves artifact deletions and rejects invalid bounds or future facts", () => {
  const removed = projectContextState([
    {
      ...history[0]!,
      sequence: 10,
      kind: "artifact_event",
      eventType: "artifact.removed",
      artifactId: "A",
    },
  ]);
  expect(removed.artifacts.A!.value).toBeNull();
  expect(() =>
    engine.bootstrap({
      ...input,
      state: { ...state, objective: fact("future", 3) },
    }),
  ).toThrow(/frozen/);
  expect(() =>
    engine.bootstrap({ ...input, history: [{ ...history[0]!, sequence: 11 }] }),
  ).toThrow(/history/);
  expect(() => engine.delta(input, 3, 0)).toThrow(/cursor/);
  expect(() => engine.bootstrap({ ...input, maxBytes: 10 })).toThrow(
    /byte limit/,
  );
  expect(() => engine.stateless({ ...input, throughSequence: -1 })).toThrow(
    /scope/,
  );
});

it("separates conversation facts and selects only transitive prerequisite results", () => {
  const workflow: WorkflowExecutionContext = {
    schemaVersion: 1,
    workflowRunId: "workflow-run-R",
    workflowId: "plan_implement",
    workflowVersion: 2,
    workRequestId: "R",
    status: "running",
    activeStepId: "verify",
    environment: null,
    artifacts: [],
    steps: [
      {
        id: "implement",
        kind: "implement",
        status: "completed",
        attempt: 1,
        workerId: "ChatGPT",
        dependsOn: [],
        result: "Implemented change",
      },
      {
        id: "verify",
        kind: "verify",
        status: "running",
        attempt: 1,
        workerId: "Gemini",
        dependsOn: ["implement"],
        result: null,
      },
      {
        id: "fix",
        kind: "implement",
        status: "queued",
        attempt: 0,
        workerId: "ChatGPT",
        dependsOn: ["verify"],
        result: "Must not leak",
      },
      {
        id: "unrelated",
        kind: "research",
        status: "completed",
        attempt: 1,
        workerId: "other",
        dependsOn: [],
        result: "Unrelated output",
      },
    ],
  };
  const selected = selectWorkflowContext(workflow);
  expect(selected.prerequisiteResults).toEqual([
    { stepId: "implement", workerId: "ChatGPT", text: "Implemented change" },
  ]);
  expect(selected.steps.find((step) => step.id === "fix")?.result).toBeNull();
  expect(
    selected.steps.find((step) => step.id === "unrelated")?.result,
  ).toBeNull();
  const document = new ContextEngine().bootstrap({
    ...input,
    workflowExecution: workflow,
  });
  expect(document.conversationContext).not.toHaveProperty("workflowState");
  expect(document.workflowExecutionContext?.activeStepId).toBe("verify");
  const delta = new ContextEngine().delta(
    { ...input, workflowExecution: workflow },
    2,
    10,
  );
  expect(delta.workflowExecutionContext?.prerequisiteResults).toEqual(
    selected.prerequisiteResults,
  );
  const fixer = selectWorkflowContext({
    ...workflow,
    activeStepId: "fix",
    steps: workflow.steps.map((step) =>
      step.id === "verify"
        ? {
            ...step,
            status: "completed",
            result: "Verification found an issue",
          }
        : step,
    ),
  });
  expect(fixer.prerequisiteResults.map((result) => result.stepId)).toEqual([
    "implement",
    "verify",
  ]);
  expect(workflow.steps[2]?.result).toBe("Must not leak");
  expect(() =>
    selectWorkflowContext({ ...workflow, activeStepId: "foreign" }),
  ).toThrow(/Invalid/);
  expect(() =>
    selectWorkflowContext({
      ...workflow,
      steps: workflow.steps.map((step) =>
        step.id === "implement" ? { ...step, dependsOn: ["verify"] } : step,
      ),
    }),
  ).toThrow(/Cyclic/);
  expect(() =>
    selectWorkflowContext({
      ...workflow,
      steps: workflow.steps.map((step) =>
        step.id === "verify" ? { ...step, dependsOn: ["missing"] } : step,
      ),
    }),
  ).toThrow(/Unknown/);
});
