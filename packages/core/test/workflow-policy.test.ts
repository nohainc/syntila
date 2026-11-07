import { expect, it } from "vitest";
import {
  BUILTIN_WORKFLOW_CATALOG,
  MANUAL_WORKFLOW_POLICY,
  CONVERSATION_WORKFLOWS,
  workflowCatalogEntry,
} from "../src/index.js";

it("allows independent manual choices for Chat and Work without continuation", () => {
  for (const id of ["chat", "work"]) {
    expect(CONVERSATION_WORKFLOWS[id]!.executionPolicy).toEqual(
      MANUAL_WORKFLOW_POLICY,
    );
  }
  expect(
    workflowCatalogEntry(BUILTIN_WORKFLOW_CATALOG["chat:v1"]!)
      .composerBindingId,
  ).toBe("chat");
  expect(
    workflowCatalogEntry(BUILTIN_WORKFLOW_CATALOG["direct:v2"]!)
      .composerBindingId,
  ).toBe("direct");
  expect(MANUAL_WORKFLOW_POLICY).toEqual({
    userSelectsWorker: true,
    userSelectsModel: true,
    userSelectsEffort: true,
    multiStep: false,
    multiWorker: false,
    automaticContinuation: false,
    requiresApprovalBetweenSteps: false,
  });
});

it("spaces graph policy and per-Step selection without altering execution snapshots", () => {
  const original = BUILTIN_WORKFLOW_CATALOG["research:v2"]!;
  const snapshot = JSON.stringify(original);
  const projected = workflowCatalogEntry(original);
  expect(projected.executionPolicy).toMatchObject({
    multiStep: true,
    multiWorker: true,
    automaticContinuation: true,
    requiresApprovalBetweenSteps: false,
  });
  expect(projected.composerBindingId).toBe("research");
  expect(JSON.stringify(original)).toBe(snapshot);
  expect(original).not.toHaveProperty("executionPolicy");
});

it("uses configured role selections for Research v2 rather than composer overrides", () => {
  expect(
    workflowCatalogEntry(BUILTIN_WORKFLOW_CATALOG["research:v2"]!)
      .executionPolicy,
  ).toMatchObject({
    multiStep: true,
    userSelectsWorker: false,
    userSelectsModel: false,
    userSelectsEffort: false,
  });
  expect(
    workflowCatalogEntry(BUILTIN_WORKFLOW_CATALOG["research:v1"]!)
      .executionPolicy,
  ).toEqual(MANUAL_WORKFLOW_POLICY);
});

it("requires explicit policy for every catalog version and future graph", () => {
  for (const definition of Object.values(BUILTIN_WORKFLOW_CATALOG)) {
    expect(() => workflowCatalogEntry(definition)).not.toThrow();
  }
  expect(() =>
    workflowCatalogEntry({
      ...BUILTIN_WORKFLOW_CATALOG["direct:v2"]!,
      version: 99,
    }),
  ).toThrow(/not defined/);
  expect(() =>
    workflowCatalogEntry({
      ...BUILTIN_WORKFLOW_CATALOG["direct:v2"]!,
      steps: BUILTIN_WORKFLOW_CATALOG["research:v2"]!.steps,
    }),
  ).toThrow(/does not match/);
});
