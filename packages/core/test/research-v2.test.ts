import { describe, expect, it } from "vitest";
import {
  BUILTIN_WORKFLOWS,
  BUILTIN_WORKFLOW_CATALOG,
  RESEARCH_RESEARCHER_LIMITS,
  RESEARCH_SYNTHESIS_STEP_ID,
  markWorkflowTaskResult,
  normalizeModelIdentity,
  planWorkflowTasks,
  readyWorkflowTasks,
  researchWorkflowV2,
  stepInstanceId,
  validateBuiltinWorkflowDefinition,
  validateResearchModelDiversity,
  validateWorkRequest,
  type WorkRequest,
  configuredWorkflowDefinition,
  parseUserWorkflowConfiguration,
  resolveUserWorkflowConfiguration,
  workflowCatalogEntry,
  workflowExecutionBatches,
  type ModelIdentityCatalog,
} from "../src/index.js";

describe("Research v2 definition", () => {
  it.each([2, 3, 4])(
    "accepts a complete %i-researcher request snapshot and requires every role",
    (count) => {
      const definition = researchWorkflowV2(count);
      const request: WorkRequest = {
        id: "request",
        threadId: "thread",
        requestedByUserId: "user",
        mode: "stateless",
        workflowId: "research",
        workflowVersion: 2,
        workflowSnapshot: definition,
        status: "queued",
        primaryWorkspaceId: "workspace",
        input: {},
        createdAt: "now",
        updatedAt: "now",
        snapshot: {
          schemaVersion: 1,
          originalRequest: "Investigate",
          attachmentReferences: [],
          workflowId: "research",
          workflowVersion: 2,
          workflowSnapshot: definition,
          resolvedBindings: Object.fromEntries(
            definition.steps.map((step) => [
              stepInstanceId(step),
              { workerId: "worker", model: stepInstanceId(step) },
            ]),
          ),
          promptProfileVersions: Object.fromEntries(
            definition.steps.map((step) => [
              step.kind,
              step.promptProfileVersion,
            ]),
          ),
          spaceInstructions: "",
          threadInstructions: "",
          stepAdditionalInstructions: {},
        },
      };
      const policy = { mode: "stateless" as const, primaryWorkspaceId: null };
      expect(() => validateWorkRequest(request, policy)).not.toThrow();
      for (const step of definition.steps) {
        const bindings = { ...request.snapshot!.resolvedBindings };
        delete bindings[stepInstanceId(step)];
        // A kind-level fallback must not mask a missing individual researcher.
        bindings.research = { workerId: "worker" };
        expect(() =>
          validateWorkRequest(
            {
              ...request,
              snapshot: { ...request.snapshot!, resolvedBindings: bindings },
            },
            policy,
          ),
        ).toThrow("missing a resolved Step input");
      }
    },
  );
  it("repeats the research kind under distinct, stable step-instance IDs", () => {
    const definition = researchWorkflowV2(3);
    expect(
      definition.steps.map((step) => [step.kind, stepInstanceId(step)]),
    ).toEqual([
      ["research", "research-1"],
      ["research", "research-2"],
      ["research", "research-3"],
      ["synthesis", "synthesis"],
    ]);
    expect(
      definition.steps.every((step) => step.readWritePolicy === "read_only"),
    ).toBe(true);
    expect(definition.steps.at(-1)!.resultSemantics).toBe("research_synthesis");
    expect(definition.steps[0]!.resultSemantics).toBe("research_report");
  });

  it("defaults to two researchers and keeps the bounds central", () => {
    expect(BUILTIN_WORKFLOW_CATALOG["research:v2"]!.steps).toHaveLength(3);
    expect(RESEARCH_RESEARCHER_LIMITS).toEqual({ min: 2, max: 4, default: 2 });
    expect(() => researchWorkflowV2(1)).toThrow(/2 to 4/);
    expect(() => researchWorkflowV2(5)).toThrow(/2 to 4/);
  });

  it("plans independent researchers in parallel and synthesis after all of them", () => {
    const tasks = planWorkflowTasks(researchWorkflowV2(2), "wr");
    expect(tasks.map((task) => task.id)).toEqual([
      "task-wr-research-1",
      "task-wr-research-2",
      "task-wr-synthesis",
    ]);
    expect(tasks[2]!.dependencyTaskIds).toEqual([
      "task-wr-research-1",
      "task-wr-research-2",
    ]);
    expect(
      workflowExecutionBatches(tasks).map((batch) => batch.map((t) => t.id)),
    ).toEqual([
      ["task-wr-research-1", "task-wr-research-2"],
      ["task-wr-synthesis"],
    ]);
    // Synthesis waits for every researcher.
    const one = markWorkflowTaskResult(
      tasks,
      "task-wr-research-1",
      "completed",
    );
    expect(readyWorkflowTasks(one).map((t) => t.id)).toEqual([
      "task-wr-research-2",
    ]);
    const both = markWorkflowTaskResult(one, "task-wr-research-2", "completed");
    expect(readyWorkflowTasks(both).map((t) => t.id)).toEqual([
      "task-wr-synthesis",
    ]);
    // A failed researcher blocks synthesis but keeps the sibling's result.
    const failed = markWorkflowTaskResult(one, "task-wr-research-2", "failed");
    expect(failed.find((t) => t.id === "task-wr-research-1")!.status).toBe(
      "completed",
    );
    expect(failed.find((t) => t.id === "task-wr-synthesis")!.status).toBe(
      "failed",
    );
  });

  it("keeps historical task IDs and snapshots of v1 definitions unchanged", () => {
    expect(
      planWorkflowTasks(BUILTIN_WORKFLOW_CATALOG["research:v1"]!, "wr").map(
        (t) => t.id,
      ),
    ).toEqual(["task-wr-research"]);
    expect(
      planWorkflowTasks(BUILTIN_WORKFLOWS.full_cycle, "wr").map((t) => t.id),
    ).toEqual([
      "task-wr-research",
      "task-wr-plan",
      "task-wr-implement",
      "task-wr-test",
      "task-wr-verify",
    ]);
    // Research is v2 now; Full Cycle keeps its v1 research step.
    expect(BUILTIN_WORKFLOWS.research.version).toBe(2);
    expect(BUILTIN_WORKFLOWS.full_cycle.steps[0]!.promptProfileVersion).toBe(
      "research:v1",
    );
    for (const definition of Object.values(BUILTIN_WORKFLOW_CATALOG))
      expect(() =>
        validateBuiltinWorkflowDefinition(
          JSON.parse(JSON.stringify(definition)),
        ),
      ).not.toThrow();
  });

  it("preserves accepted binding IDs for historical workflows", () => {
    for (const definition of Object.values(BUILTIN_WORKFLOW_CATALOG).filter(
      (definition) =>
        !(definition.id === "research" && definition.version === 2),
    )) {
      const request: WorkRequest = {
        id: "historical",
        threadId: "thread",
        requestedByUserId: "user",
        mode: "stateless",
        workflowId: definition.id,
        workflowVersion: definition.version,
        workflowSnapshot: definition,
        status: "completed",
        primaryWorkspaceId: null,
        input: {},
        createdAt: "then",
        updatedAt: "then",
        snapshot: {
          schemaVersion: 1,
          originalRequest: "Investigate",
          attachmentReferences: [],
          workflowId: definition.id,
          workflowVersion: definition.version,
          workflowSnapshot: definition,
          resolvedBindings: Object.fromEntries(
            definition.steps.map((step) => [
              definition.id === "direct" ? "direct" : step.kind,
              { workerId: "worker" },
            ]),
          ),
          promptProfileVersions: Object.fromEntries(
            definition.steps.map((step) => [
              step.kind,
              step.promptProfileVersion,
            ]),
          ),
          spaceInstructions: "",
          threadInstructions: "",
          stepAdditionalInstructions: {},
        },
      };
      expect(() =>
        validateWorkRequest(request, {
          mode: "stateless",
          primaryWorkspaceId: null,
        }),
      ).not.toThrow();
    }
  });

  it("accepts any allowed researcher count in a snapshot and rejects tampering", () => {
    for (const count of [2, 3, 4])
      expect(() =>
        validateBuiltinWorkflowDefinition(
          JSON.parse(JSON.stringify(researchWorkflowV2(count))),
        ),
      ).not.toThrow();
    const tampered = JSON.parse(JSON.stringify(researchWorkflowV2(2)));
    tampered.steps[2].dependsOnSteps = ["research-1"]; // synthesis skipping one
    expect(() => validateBuiltinWorkflowDefinition(tampered)).toThrow(
      /canonical/,
    );
    const renamed = JSON.parse(JSON.stringify(researchWorkflowV2(2)));
    renamed.steps[1].id = "research-1"; // duplicate instance ID
    expect(() => validateBuiltinWorkflowDefinition(renamed)).toThrow(
      /canonical/,
    );
    const writable = JSON.parse(JSON.stringify(researchWorkflowV2(2)));
    writable.steps[0].readWritePolicy = "write_thread";
    expect(() => validateBuiltinWorkflowDefinition(writable)).toThrow(
      /canonical/,
    );
  });

  it("declares a graph policy for v2 with the Research composer binding", () => {
    const entry = workflowCatalogEntry(researchWorkflowV2(2));
    expect(entry.executionPolicy.multiStep).toBe(true);
    expect(entry.composerBindingId).toBe("research");
    expect(RESEARCH_SYNTHESIS_STEP_ID).toBe("synthesis");
  });
});

describe("Research model diversity", () => {
  const catalogs: Record<string, ModelIdentityCatalog> = {
    codex: {
      models: ["gpt-5.5", "gpt-5.5-mini"],
      aliases: { latest: "gpt-5.5", "gpt-5.5-2026-09-01": "gpt-5.5" },
    },
    codex2: { models: ["gpt-5.5"] },
    claude: { models: ["claude-opus-5-5"], allowsCustomModels: true },
  };
  const catalogFor = (id: string) => catalogs[id];
  const role = (
    n: number,
    workerId: string,
    model?: string,
    effort?: string,
  ) => ({
    role: `Researcher ${n}`,
    workerId,
    model,
    reasoningEffort: effort,
  });

  it("accepts two explicit, different models (providers may match)", () => {
    expect(
      validateResearchModelDiversity(
        [role(1, "codex", "gpt-5.5"), role(2, "codex", "gpt-5.5-mini")],
        catalogFor,
      ),
    ).toEqual([]);
  });

  it("rejects effort-only, Worker-only and alias-only differences", () => {
    const codes = (
      selections: Parameters<typeof validateResearchModelDiversity>[0],
    ) =>
      validateResearchModelDiversity(selections, catalogFor).map((i) => i.code);
    expect(
      codes([
        role(1, "codex", "gpt-5.5", "low"),
        role(2, "codex", "gpt-5.5", "high"),
      ]),
    ).toEqual(["duplicate_model"]);
    expect(
      codes([role(1, "codex", "gpt-5.5"), role(2, "codex2", "gpt-5.5")]),
    ).toEqual(["duplicate_model"]);
    expect(
      codes([
        role(1, "codex", "latest"),
        role(2, "codex", "GPT-5.5-2026-09-01"),
      ]),
    ).toEqual(["duplicate_model"]);
  });

  it("rejects Auto, unavailable models and Workers, and too few researchers", () => {
    const issues = validateResearchModelDiversity(
      [role(1, "codex"), role(2, "codex", "not-a-model"), role(3, "gone", "x")],
      catalogFor,
    );
    expect(issues.map((i) => i.code)).toEqual([
      "model_unresolved",
      "model_unavailable",
      "worker_unavailable",
    ]);
    expect(issues[0]!.message).toMatch(/Auto cannot prove/);
    expect(
      validateResearchModelDiversity(
        [role(1, "codex", "gpt-5.5")],
        catalogFor,
      ).map((i) => i.code),
    ).toEqual(["insufficient_researchers"]);
    expect(
      validateResearchModelDiversity(
        Array.from({ length: 5 }, (_, i) => role(i + 1, "claude", `m-${i}`)),
        catalogFor,
      ).map((i) => i.code),
    ).toEqual(["too_many_researchers"]);
  });

  it("normalizes identity from the catalog; custom IDs only where allowed", () => {
    expect(normalizeModelIdentity("Latest", catalogs.codex)).toBe("gpt-5.5");
    expect(normalizeModelIdentity("custom-x", catalogs.codex)).toBeNull();
    expect(normalizeModelIdentity(" Custom-X ", catalogs.claude)).toBe(
      "custom-x",
    );
    expect(normalizeModelIdentity("", catalogs.claude)).toBeNull();
    expect(normalizeModelIdentity("gpt-5.5", undefined)).toBeNull();
  });
});

describe("Research configuration contract", () => {
  const v2 = (extra: object = {}) => ({
    schemaVersion: 2,
    workflowId: "research",
    enabled: true,
    researcherCount: 3,
    defaults: { worker: "w" },
    stepOverrides: {
      "research-1": { model: "a" },
      "research-2": { model: "b" },
      "research-3": { model: "c" },
      synthesis: { model: "a", effort: "high" },
    },
    ...extra,
  });

  it("parses per-role selections and resolves them by step instance", () => {
    const parsed = parseUserWorkflowConfiguration(
      BUILTIN_WORKFLOWS.research,
      v2(),
    );
    expect(parsed.researcherCount).toBe(3);
    const definition = configuredWorkflowDefinition(
      BUILTIN_WORKFLOWS.research,
      parsed,
    );
    expect(definition.steps).toHaveLength(4);
    const effective = resolveUserWorkflowConfiguration(definition, parsed);
    expect(effective.steps["research-2"]).toEqual({ worker: "w", model: "b" });
    expect(effective.steps.synthesis).toEqual({
      worker: "w",
      model: "a",
      effort: "high",
    });
  });

  it("rejects bad counts, unknown roles and version 2 outside Research", () => {
    expect(() =>
      parseUserWorkflowConfiguration(
        BUILTIN_WORKFLOWS.research,
        v2({ researcherCount: 1 }),
      ),
    ).toThrow(/2 to 4/);
    expect(() =>
      parseUserWorkflowConfiguration(
        BUILTIN_WORKFLOWS.research,
        v2({ researcherCount: 2 }), // research-3 no longer exists
      ),
    ).toThrow(/Unknown configuration field/);
    expect(() =>
      parseUserWorkflowConfiguration(BUILTIN_WORKFLOWS.chat, {
        ...v2(),
        workflowId: "chat",
      }),
    ).toThrow(/Invalid configuration version/);
  });

  it("keeps version 1 Research configuration readable (defaults only)", () => {
    const parsed = parseUserWorkflowConfiguration(BUILTIN_WORKFLOWS.research, {
      schemaVersion: 1,
      workflowId: "research",
      enabled: true,
      defaults: { worker: "w", model: "a" },
      stepOverrides: { research: { effort: "low" } },
    });
    expect(parsed.schemaVersion).toBe(1);
    // A v1 configuration yields the default two researchers on one model, so
    // acceptance rejects it until roles are configured (no silent duplicate).
    expect(
      configuredWorkflowDefinition(BUILTIN_WORKFLOWS.research, parsed).steps,
    ).toHaveLength(3);
  });
});
