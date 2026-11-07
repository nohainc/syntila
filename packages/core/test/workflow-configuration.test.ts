import { expect, it } from "vitest";
import {
  BUILTIN_WORKFLOW_CATALOG,
  parseUserWorkflowConfiguration,
  resolveUserWorkflowConfiguration,
} from "../src/index.js";
const definition = BUILTIN_WORKFLOW_CATALOG["research:v2"]!;
const input = {
  schemaVersion: 1,
  workflowId: definition.id,
  enabled: true,
  defaults: {},
  stepOverrides: {},
};
it("keeps definitions separate, requires an explicit Worker and overlays steps without mutating preferences", () => {
  const config = parseUserWorkflowConfiguration(definition, {
    ...input,
    defaults: { worker: "offline", model: "m" },
    stepOverrides: { synthesis: { worker: "reviewer", effort: "high" } },
  });
  const effective = resolveUserWorkflowConfiguration(definition, config);
  expect(effective.definition).toBe(definition);
  expect(effective.steps.synthesis).toEqual({
    worker: "reviewer",
    model: "m",
    effort: "high",
  });
  expect(config.stepOverrides.synthesis).toEqual({
    worker: "reviewer",
    effort: "high",
  });
  expect(resolveUserWorkflowConfiguration(definition).enabled).toBe(true);
  expect(resolveUserWorkflowConfiguration(definition).steps.synthesis).toEqual({});
});
it("normalizes Model/Effort Auto and rejects Worker Auto plus invalid identities", () => {
  expect(
    parseUserWorkflowConfiguration(definition, {
      ...input,
      defaults: { worker: "offline", model: "Auto" },
      stepOverrides: { synthesis: { effort: "Auto" } },
    }),
  ).toEqual({
    ...input,
    defaults: { worker: "offline" },
  });
  expect(() =>
    parseUserWorkflowConfiguration(definition, {
      ...input,
      defaults: { worker: "Auto" },
    }),
  ).toThrow(/Worker must be selected explicitly/);
  for (const extra of [
    { userId: "other" },
    { schemaVersion: 3 },
    { stepOverrides: { unknown: {} } },
    { defaults: { worker: 2 } },
    { workflowId: "direct" },
  ]) {
    expect(() =>
      parseUserWorkflowConfiguration(definition, { ...input, ...extra }),
    ).toThrow();
  }
});

it("accepts optional reviewed catalog revisions while keeping legacy selections readable", () => {
  const config = parseUserWorkflowConfiguration(definition, {
    ...input,
    defaults: {
      worker: "worker",
      model: "model",
      catalogRevision: "a".repeat(64),
    },
  });
  expect(
    resolveUserWorkflowConfiguration(definition, config).steps["research-1"]
      ?.catalogRevision,
  ).toBe("a".repeat(64));
  for (const catalogRevision of ["Auto", "unknown", "A".repeat(64)])
    expect(() =>
      parseUserWorkflowConfiguration(definition, {
        ...input,
        defaults: { worker: "worker", catalogRevision },
      }),
    ).toThrow();
});

it("does not inherit another Worker's reviewed catalog revision", () => {
  const configured = parseUserWorkflowConfiguration(definition, {
    ...input,
    defaults: { worker: "one", catalogRevision: "a".repeat(64) },
    stepOverrides: { synthesis: { worker: "two" } },
  });
  expect(
    resolveUserWorkflowConfiguration(definition, configured).steps.synthesis
      ?.catalogRevision,
  ).toBeUndefined();
  expect(
    resolveUserWorkflowConfiguration(definition, configured).steps["research-1"]
      ?.catalogRevision,
  ).toBe("a".repeat(64));
});
it("accepts a per-Step mcpTools list, lets a step replace the default and rejects bad lists", () => {
  const config = parseUserWorkflowConfiguration(definition, {
    ...input,
    defaults: { worker: "w", mcpTools: ["files"] },
    stepOverrides: { synthesis: { mcpTools: [] } },
  });
  const effective = resolveUserWorkflowConfiguration(definition, config);
  expect(effective.steps["research-1"]?.mcpTools).toEqual(["files"]);
  // An empty list is an explicit "none", not "inherit".
  expect(effective.steps.synthesis?.mcpTools).toEqual([]);
  for (const mcpTools of [
    "files",
    ["Files"],
    ["a", "a"],
    ["../x"],
    Array.from({ length: 9 }, (_, i) => `s${i}`),
  ])
    expect(() =>
      parseUserWorkflowConfiguration(definition, {
        ...input,
        defaults: { worker: "w", mcpTools },
      }),
    ).toThrow();
});

it("supports independent role configuration for plan, implement, and verify in Implement workflow", () => {
  const implementDef = BUILTIN_WORKFLOW_CATALOG["plan_implement:v2"]!;
  const parsed = parseUserWorkflowConfiguration(implementDef, {
    schemaVersion: 1,
    workflowId: implementDef.id,
    enabled: true,
    defaults: { worker: "planner-worker", model: "deep-think", effort: "high" },
    stepOverrides: {
      implement: { worker: "coder-worker", model: "fast-code", effort: "medium" },
      verify: { worker: "auditor-worker", model: "strict-auditor", effort: "high" },
    },
  });
  const effective = resolveUserWorkflowConfiguration(implementDef, parsed);
  expect(effective.steps.plan).toEqual({
    worker: "planner-worker",
    model: "deep-think",
    effort: "high",
  });
  expect(effective.steps.implement).toEqual({
    worker: "coder-worker",
    model: "fast-code",
    effort: "medium",
  });
  expect(effective.steps.verify).toEqual({
    worker: "auditor-worker",
    model: "strict-auditor",
    effort: "high",
  });
});
