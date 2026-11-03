import { readdirSync, readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { describe, expect, it } from "vitest";
import {
  BUILTIN_WORKFLOW_CATALOG,
  researchWorkflowV2,
  type StepResult,
} from "@syntila/core";
import { prepareWorkerStepExecution } from "../src/execution-engine.js";
import { workStepSessionKey } from "../src/work-session-key.js";
import {
  MAX_RESEARCH_SYNTHESIS_PROMPT_CHARS,
  ResearchContextOverflowError,
  renderResearchV2Prompt,
} from "../src/workflow-prompts.js";

const dir = new URL("../migrations-v8/", import.meta.url);
const migrations = readdirSync(dir)
  .filter((name) => name.endsWith(".sql"))
  .sort();

describe("migration 0099: step-instance identity", () => {
  it("preserves existing tasks, dependencies and Step Runs, and admits repeated kinds", () => {
    const db = new DatabaseSync(":memory:");
    for (const name of migrations.filter((n) => n < "0099"))
      db.exec(readFileSync(new URL(name, dir), "utf8"));
    db.exec(`PRAGMA foreign_keys = OFF;
      INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('U','u@t','U','now','now');
      INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('S','U','S','now','now');
      INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('W','S','T','active','U','now','now');
      INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at,ai_context_generation)
        VALUES('R','W','U','stateless','plan_implement',1,'{}','completed','{}','now','now',0);
      INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,attempt,created_at,updated_at)
        VALUES('task-R-plan','R','plan','stateless_read',1000,'plan:v1','completed',1,'now','now'),
              ('task-R-implement','R','implement','stateful_thread',1000,'implement:v1','completed',1,'now','now');
      INSERT INTO workflow_task_dependencies VALUES('task-R-implement','task-R-plan');
      PRAGMA foreign_keys = ON;`);
    db.exec(
      readFileSync(new URL("0099_workflow_step_instances.sql", dir), "utf8"),
    );
    expect(
      db
        .prepare(
          "SELECT id, step_kind, step_id FROM workflow_tasks ORDER BY id",
        )
        .all(),
    ).toEqual([
      { id: "task-R-implement", step_kind: "implement", step_id: "implement" },
      { id: "task-R-plan", step_kind: "plan", step_id: "plan" },
    ]);
    expect(
      db.prepare("SELECT COUNT(*) AS n FROM workflow_task_dependencies").get(),
    ).toEqual({ n: 1 });
    // Two research instances and a synthesis step now coexist in one request.
    db.exec(`PRAGMA foreign_keys = OFF;
      INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,attempt,created_at,updated_at,step_instance_id)
        VALUES('task-R-research-1','R','research','stateless_read',1000,'research:v2','queued',0,'now','now','research-1'),
              ('task-R-research-2','R','research','stateless_read',1000,'research:v2','queued',0,'now','now','research-2'),
              ('task-R-synthesis','R','synthesis','stateless_read',1000,'synthesis:v1','queued',0,'now','now','synthesis');`);
    expect(() =>
      db.exec(
        "INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,attempt,created_at,updated_at,step_instance_id) VALUES('dup','R','research','stateless_read',1000,'research:v2','queued',0,'now','now','research-1')",
      ),
    ).toThrow(/UNIQUE/);
    db.close();
  });
});

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
