import { readdirSync, readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { describe, expect, it } from "./helpers/vitest-compat";
import {
  BUILTIN_WORKFLOW_CATALOG,
  researchWorkflowV2,
  type StepResult,
} from "@syntila/core";
import { prepareWorkerStepExecution } from "../../src/domain/execution-engine.js";
import { workStepSessionKey } from "../../src/domain/work-session-key.js";
import {
  MAX_RESEARCH_SYNTHESIS_PROMPT_CHARS,
  ResearchContextOverflowError,
  renderResearchV2Prompt,
} from "../../src/domain/workflow-prompts.js";


describe("Research v2 execution isolation", () => {
  const definition = researchWorkflowV2(2);
  const scope = {
    spaceId: "S",
    spaceName: "Space",
    requesterUserId: "U",
    threadId: "T",
    workRequestId: "R",
    workSessionGeneration: 0,
  };
  const execution = (index: number) =>
    prepareWorkerStepExecution({
      taskId: `task-R-${definition.steps[index]!.id}`,
      step: definition.steps[index]!,
      bindingId: "research",
      binding: { workerId: "w", model: index === 1 ? "model-b" : "model-a" },
      prompt: "p",
      workerInput: {},
      scope,
      retry: {},
    } as never);

  it("gives every researcher and the synthesis its own fresh session", () => {
    const keys = [0, 1, 2].map((index) => execution(index).task.sessionKey);
    expect(new Set(keys).size).toBe(3);
    // Synthesis reuses a researcher's model but never its session.
    expect(execution(2).task.model).toBe(execution(0).task.model);
    expect(execution(2).task.sessionKey).not.toBe(execution(0).task.sessionKey);
    // Every Research v2 execution is read-only through the permission path.
    expect([0, 1, 2].map((i) => execution(i).task.readOnly)).toEqual([
      true,
      true,
      true,
    ]);
    expect([0, 1, 2].map((i) => execution(i).task.executionClass)).toEqual([
      "stateless_read",
      "stateless_read",
      "stateless_read",
    ]);
  });

  it("keeps the v1 Research session key unchanged", () => {
    const v1 = prepareWorkerStepExecution({
      taskId: "task-R-research",
      step: BUILTIN_WORKFLOW_CATALOG["research:v1"]!.steps[0]!,
      bindingId: "research",
      binding: {},
      prompt: "p",
      workerInput: {},
      scope,
      retry: {},
    } as never);
    expect(v1.task.sessionKey).toBe(
      workStepSessionKey({
        workBindingId: "research",
        threadId: "T",
        workRequestId: "R",
        stepKind: "research",
        workSessionGeneration: 0,
      }),
    );
  });
});

describe("Research v2 prompts", () => {
  const definition = researchWorkflowV2(2);
  const base = {
    originalRequest: "Which queue should we use?",
    spaceInstructions: "Prefer managed services.",
    attachments: [
      { kind: "file" as const, name: "notes.md", content: "Budget is small." },
    ],
  };
  const report = (text: string, model: string): StepResult => ({
    text,
    status: "completed",
    startedAt: "t",
    completedAt: "t",
    workerId: "w",
    workerTypeId: "x",
    engineVersion: null,
    profileDefinitionId: null,
    profileReleaseVersion: null,
    providerToolVersion: null,
    model,
  });

  it("gives every researcher the identical request and accepted context", () => {
    const [one, two] = [0, 1].map((index) =>
      renderResearchV2Prompt(definition, definition.steps[index]!, {
        ...base,
        stepResults: { "research-1": report("sibling answer", "model-a") },
      }),
    );
    expect(one).toBe(two);
    expect(one).toContain("Budget is small.");
    expect(one).toContain("Prefer managed services.");
    expect(one).not.toContain("sibling answer");
    expect(one).toContain("unverified historical conclusions");
    expect(one).toContain("historyCoverage");
    expect(one).toContain(
      "Do not request permission escalation or repeat a denied action",
    );
    expect(one).toMatch(/Never claim web access/);
  });

  it("passes every report, attributed, and fails clearly instead of truncating", () => {
    const synthesis = definition.steps[2]!;
    const prompt = renderResearchV2Prompt(definition, synthesis, {
      ...base,
      stepResults: {
        "research-1": report("Use SQS.", "model-a"),
        "research-2": report("Use Kafka.", "model-b"),
      },
    });
    expect(prompt).toContain("Use SQS.");
    expect(prompt).toContain("Use Kafka.");
    expect(prompt).toContain("model: model-b");
    expect(prompt).toMatch(/Do not decide by majority vote/);
    expect(prompt).toContain("Budget is small.");
    expect(() =>
      renderResearchV2Prompt(definition, synthesis, {
        ...base,
        stepResults: { "research-1": report("Use SQS.", "model-a") },
      }),
    ).toThrow(/research-2 report is unavailable/);
    const long = "x".repeat(MAX_RESEARCH_SYNTHESIS_PROMPT_CHARS);
    expect(() =>
      renderResearchV2Prompt(definition, synthesis, {
        ...base,
        stepResults: {
          "research-1": report(long, "model-a"),
          "research-2": report("short", "model-b"),
        },
      }),
    ).toThrow(ResearchContextOverflowError);
  });

  it("rejects oversized accepted context instead of silently truncating it", () => {
    for (const step of [definition.steps[0]!, definition.steps[2]!]) {
      expect(() =>
        renderResearchV2Prompt(definition, step, {
          ...base,
          originalRequest: "x".repeat(20_001),
        }),
      ).toThrow(ResearchContextOverflowError);
      expect(() =>
        renderResearchV2Prompt(definition, step, {
          ...base,
          attachments: [{ name: "notes", content: "x".repeat(12_001) }],
        }),
      ).toThrow(ResearchContextOverflowError);
    }
  });
});
