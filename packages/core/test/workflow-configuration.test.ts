import { expect, it } from "vitest";
import {
  BUILTIN_WORKFLOW_CATALOG,
  parseUserWorkflowConfiguration,
  resolveUserWorkflowConfiguration,
} from "../src/index.js";
const definition = Object.values(BUILTIN_WORKFLOW_CATALOG).find(
  (d) => d.id === "full_cycle",
)!;
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
    stepOverrides: { verify: { worker: "reviewer", effort: "high" } },
  });
  const effective = resolveUserWorkflowConfiguration(definition, config);
  expect(effective.definition).toBe(definition);
  expect(effective.steps.verify).toEqual({
    worker: "reviewer",
    model: "m",
    effort: "high",
  });
  expect(config.stepOverrides.verify).toEqual({
    worker: "reviewer",
    effort: "high",
  });
  expect(resolveUserWorkflowConfiguration(definition).enabled).toBe(true);
  expect(resolveUserWorkflowConfiguration(definition).steps.verify).toEqual({});
});
it("normalizes Model/Effort Auto and rejects Worker Auto plus invalid identities", () => {
  expect(
    parseUserWorkflowConfiguration(definition, {
      ...input,
      defaults: { worker: "offline", model: "Auto" },
      stepOverrides: { verify: { effort: "Auto" } },
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
    { schemaVersion: 2 },
    { stepOverrides: { unknown: {} } },
    { defaults: { worker: 2 } },
    { workflowId: "chat" },
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
    resolveUserWorkflowConfiguration(definition, config).steps.implement
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
    stepOverrides: { verify: { worker: "two" } },
  });
  expect(
    resolveUserWorkflowConfiguration(definition, configured).steps.verify
      ?.catalogRevision,
  ).toBeUndefined();
  expect(
    resolveUserWorkflowConfiguration(definition, configured).steps.implement
      ?.catalogRevision,
  ).toBe("a".repeat(64));
});
it("accepts a per-Step mcpTools list, lets a step replace the default and rejects bad lists", () => {
  const config = parseUserWorkflowConfiguration(definition, {
    ...input,
    defaults: { worker: "w", mcpTools: ["files"] },
    stepOverrides: { verify: { mcpTools: [] } },
  });
  const effective = resolveUserWorkflowConfiguration(definition, config);
  expect(effective.steps.implement?.mcpTools).toEqual(["files"]);
  // An empty list is an explicit "none", not "inherit".
  expect(effective.steps.verify?.mcpTools).toEqual([]);
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
