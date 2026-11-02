import { describe, expect, it, vi } from "vitest";
import {
  BUILTIN_WORKFLOWS,
  BUILTIN_WORKFLOW_CATALOG,
  type BuiltinWorkflowDefinition,
} from "@syntila/core";

const selectionCalls: Record<string, unknown>[] = [];
vi.mock("../src/scheduler.js", () => ({
  selectSpaceExecutionTarget: vi.fn(
    async (_db: unknown, request: Record<string, unknown>) => {
      selectionCalls.push(request);
      return {
        spaceId: request.spaceId,
        workspaceId: "workspace-fixture",
        workspaceRuntimeIdentityId: "workspace-runtime-fixture",
        workspaceSpaceGrantId: "grant-fixture",
        workerId: request.workerId ?? "workspace-worker-fixture",
        workerTypeId: "chatgpt",
        engineVersion: "engine-fixture",
        profileDefinitionId: "chatgpt-codex",
        profileReleaseVersion: 1,
        providerToolName: "codex",
        providerToolVersion: "cli-fixture",
        model: request.model ?? "fixture-model",
        effectivePermissions: ["thread.read"],
        permissionSnapshot: {
          profileDefinitionId: "chatgpt-codex",
          profileReleaseVersion: 1,
          providerToolVersion: "cli-fixture",
        },
        selectionExplanation: { source: "fixture" },
        executionClass: request.executionClass,
        readOnly: request.readOnly,
        threadId: request.threadId,
        workRequestId: request.workRequestId,
      };
    },
  ),
}));

import { recordAssignmentResult } from "../src/assignment-dispatcher.js";
import { SyntilaRunWorkflow } from "../src/workflow.js";

const requestText =
  "  ## Improve Thread\n\n**Keep source** [docs](https://example.com)\n\n```ts\nconst ready = true;\n```\n  ";
const workerBindings = {
  chat: { workerId: "worker-chat", model: "chat-model" },
  direct: { workerId: "worker-direct", model: "work-model" },
  research: { workerId: "worker-research" },
  plan: { workerId: "worker-plan" },
  implement: { workerId: "worker-implement" },
  test: { workerId: "worker-test" },
  verify: { workerId: "worker-verify" },
};

type FixtureAssignment = {
  status: string;
  task_id: string;
  output_json: string | null;
  error_json: string | null;
  workspace_worker_id: string;
  worker_type_id: string;
  engine_version: string;
  model: string;
  permission_snapshot_json: string;
  created_at: string;
};

function createAcceptanceRun(
  definition: BuiltinWorkflowDefinition,
  options: {
    cancelAfterFirstStep?: boolean;
    /**
     * When the Service's result reaches Cloud: `during_dispatch` (before the
     * Workflow looks), `event` (the Workflow suspends and the terminal event
     * wakes it) or `lost_event` (the wake-up is lost and the reconciliation
     * timeout finds the durable state).
     */
    completion?: "during_dispatch" | "event" | "lost_event";
  } = {},
) {
  const completion = options.completion ?? "during_dispatch";
  const pendingCompletions: Array<() => Promise<void>> = [];
  const waits: { name: string; options: unknown }[] = [];
  const sleeps: string[] = [];
  selectionCalls.length = 0;
  const gatewayCalls: Record<string, unknown>[] = [];
  const taskWrites: { sql: string; values: unknown[] }[] = [];
  const assignments = new Map<string, FixtureAssignment>();
  let cancellationChecks = 0;
  const dbObject = {
    prepare(sql: string) {
      let values: unknown[] = [];
      const statement = {
        bind(...next: unknown[]) {
          values = next;
          return statement;
        },
        async first<T>() {
          if (sql.includes("INSERT INTO worker_assignments")) {
            await statement.run();
            return { id: values[0] } as T;
          }
          if (sql.includes("SELECT wr.input_json")) {
            return {
              inputJson: JSON.stringify({ originalRequest: requestText }),
              snapshotJson: JSON.stringify({
                originalRequest: requestText,
                resolvedBindings: workerBindings,
              }),
            } as T;
          }
          if (sql.includes("SELECT mode FROM work_requests"))
            return { mode: "stateless" } as T;
          if (sql.includes("SELECT wr.thread_id AS threadId")) {
            return {
              threadId: "thread-fixture",
              requesterUserId: "user-fixture",
              workRequestStatus: "running",
              cancelRequestedAt: null,
              spaceId: "space-fixture",
            } as T;
          }
          if (
            sql.includes(
              "SELECT status, task_id, attempt_id FROM worker_assignments",
            )
          ) {
            const row = assignments.get(String(values[0]));
            return row
              ? ({ status: row.status, task_id: row.task_id } as T)
              : null;
          }
          if (sql.includes("FROM worker_assignments wa WHERE wa.id")) {
            const row = assignments.get(String(values[0]));
            if (!row) return null;
            return {
              assignmentId: values[0],
              status: row.status,
              outputJson: row.output_json,
              errorJson: row.error_json,
              workerId: row.workspace_worker_id,
              workerTypeId: row.worker_type_id,
              engineVersion: row.engine_version,
              model: row.model,
              permissionSnapshotJson: row.permission_snapshot_json,
              startedAt: row.created_at,
            } as T;
          }
          if (sql.includes("SELECT owner_user_id FROM execution_workspaces"))
            return { owner_user_id: "workspace-owner-fixture" } as T;
          if (sql.includes("cancel_requested_at AS cancelRequestedAt")) {
            cancellationChecks += 1;
            return {
              cancelRequestedAt:
                options.cancelAfterFirstStep && cancellationChecks > 0
                  ? "2026-10-01T00:00:00.000Z"
                  : null,
            } as T;
          }
          return null;
        },
        async all<T>() {
          return { results: [] as T[] };
        },
        async run() {
          taskWrites.push({ sql, values });
          if (sql.includes("INSERT INTO worker_assignments")) {
            assignments.set(String(values[0]), {
              status: "created",
              task_id: String(values[5]),
              workspace_worker_id: String(values[10]),
              worker_type_id: String(values[9]),
              engine_version: String(values[11]),
              model: String(values[12]),
              permission_snapshot_json: String(values[15]),
              created_at: String(values[20]),
              output_json: null,
              error_json: null,
            });
          } else if (
            sql.includes("UPDATE worker_assignments SET status = 'dispatched'")
          ) {
            const row = assignments.get(String(values[1]));
            if (row?.status === "created") row.status = "dispatched";
          } else if (
            sql.includes("UPDATE worker_assignments SET status = 'completed'")
          ) {
            const row = assignments.get(String(values[2]));
            if (row) {
              row.status = "completed";
              row.output_json = String(values[0]);
            }
          } else if (
            sql.includes("UPDATE worker_assignments SET status = 'failed'")
          ) {
            const row = assignments.get(String(values[2]));
            if (row) {
              row.status = "failed";
              row.error_json = String(values[0]);
            }
          }
          return { success: true };
        },
      };
      return statement;
    },
    async batch(statements: { run: () => Promise<unknown> }[]) {
      for (const statement of statements) await statement.run();
      return [];
    },
  };
  const database = dbObject as unknown as D1Database;
  const gatewayStub = {
    async fetch(input: RequestInfo | URL, init?: RequestInit) {
      const url = String(input);
      if (url.endsWith("/status")) {
        return Response.json({
          online: true,
          workspaceRuntimeId: "workspace-runtime-fixture",
          executionWorkspaceId: "workspace-fixture",
        });
      }
      const envelope = JSON.parse(String(init?.body)) as Record<
        string,
        unknown
      >;
      gatewayCalls.push(envelope);
      const assignmentId = String(envelope.assignmentId);
      const snapshot = (
        envelope.payload as { snapshot: Record<string, unknown> }
      ).snapshot;
      // The fixture represents the Service's explicit startup acknowledgement
      // before the provider result arrives. Cloud must not infer Running from
      // a dispatch alone.
      const row = assignments.get(assignmentId);
      if (row) row.status = "running";
      const finish = () =>
        recordAssignmentResult(database, assignmentId, {
          text: `completed ${String(snapshot.role)}`,
        } as never).then(() => undefined);
      if (completion === "during_dispatch") await finish();
      else pendingCompletions.push(finish);
      return Response.json({ accepted: true });
    },
  };
  const gateway = {
    idFromName: (name: string) => name,
    get: () => gatewayStub,
  } as unknown as DurableObjectNamespace;
  const instance = new SyntilaRunWorkflow(
    {} as never,
    { SYNTILA_DB: database, SYNTILA_WORKSPACE_GATEWAY: gateway } as never,
  );
  const step = {
    do: async <T>(
      _name: string,
      _config: unknown,
      callback: () => Promise<T>,
    ) => callback(),
    sleep: async (name: string) => {
      sleeps.push(name);
    },
    waitForEvent: async (name: string, config: unknown) => {
      waits.push({ name, options: config });
      await pendingCompletions.shift()?.();
      // A lost event: the result is durable in D1 but the wake-up never
      // arrives, so the wait ends by timeout, which Workflows throws.
      if (completion === "lost_event") throw new Error("Execution timed out");
      return {
        type: "assignment-terminal",
        payload: {},
        timestamp: new Date(),
      };
    },
  } as unknown as import("cloudflare:workers").WorkflowStep;
  return { instance, step, taskWrites, gatewayCalls, waits, sleeps };
}

// Research v2 (repeated step instances) is a catalog contract only until its
// Cloud execution phase lands; it is not a selectable current version yet.
const workflowCases = Object.entries(BUILTIN_WORKFLOW_CATALOG)
  .filter(([reference]) => reference !== "research:v2")
  .map(([, definition]) => definition);

describe("Work v1 acceptance through the shared assignment dispatcher", () => {
  it.each(workflowCases)(
    "executes the real $name Workflow snapshot through Workspace Gateway fixtures",
    async (definition) => {
      const { instance, step, taskWrites, gatewayCalls } =
        createAcceptanceRun(definition);
      const result = await instance.run(
        {
          payload: {
            runId: "run-v8-acceptance",
            goalId: "goal-v8-acceptance",
            idempotencyKey: `key-${definition.id}`,
            workRequestId: "request-v8-acceptance",
            organizationId: "workspace-fixture",
            builtinWorkflow: definition,
          },
        } as never,
        step,
      );

      expect(result.status).toBe("completed");
      expect(selectionCalls).toHaveLength(definition.steps.length);
      expect(gatewayCalls).toHaveLength(definition.steps.length);
      expect(selectionCalls.map((call) => call.readOnly)).toEqual(
        definition.steps.map((step) => step.readWritePolicy === "read_only"),
      );
      expect(selectionCalls.map((call) => call.executionClass)).toEqual(
        definition.steps.map((step) => step.executionMode),
      );
      expect(selectionCalls.map((call) => call.workBindingId)).toEqual(
        definition.steps.map((item) =>
          definition.id === "direct" ? "direct" : item.kind,
        ),
      );
      expect(selectionCalls.map((call) => call.workerId)).toEqual(
        definition.steps.map(
          (item) =>
            workerBindings[
              definition.id === "direct"
                ? "direct"
                : (item.kind as keyof typeof workerBindings)
            ].workerId,
        ),
      );
      if (definition.id === "chat" || definition.id === "direct") {
        const binding = workerBindings[definition.id];
        expect(selectionCalls[0]).toMatchObject({
          workBindingId: definition.id,
          workerId: binding.workerId,
          model: binding.model,
        });
      }
      for (const [index, envelope] of gatewayCalls.entries()) {
        const payload = envelope.payload as {
          snapshot: Record<string, unknown>;
        };
        const assignment = payload.snapshot;
        expect(assignment).toMatchObject({
          role: definition.steps[index]!.kind,
          requestedByUserId: "user-fixture",
          spaceId: "space-fixture",
          workRequestId: "request-v8-acceptance",
          sessionPolicy: "durable_session",
          readOnly: definition.steps[index]!.readWritePolicy === "read_only",
          executionClass: definition.steps[index]!.executionMode,
        });
        const prompt = String(assignment.objective);
        for (const inputKind of definition.steps[index]!.inputsFrom) {
          const label =
            inputKind === "implement"
              ? "Implementation"
              : inputKind[0]!.toUpperCase() + inputKind.slice(1);
          expect(prompt).toContain(`${label} result:\ncompleted ${inputKind}`);
        }
        if (definition.steps[index]!.kind === "verify") {
          expect(prompt).toContain("fresh isolated assignment");
          expect(assignment.readOnly).toBe(true);
        }
      }
      expect(
        taskWrites.filter(({ sql }) =>
          sql.includes("UPDATE workflow_tasks SET status"),
        ),
      ).toHaveLength(definition.steps.length * 3);
    },
  );

  it("stops downstream steps when cancellation is recorded after an assignment completes", async () => {
    const { instance, step, gatewayCalls } = createAcceptanceRun(
      BUILTIN_WORKFLOWS.plan_implement,
      { cancelAfterFirstStep: true },
    );
    const result = await instance.run(
      {
        payload: {
          runId: "run-v8-acceptance",
          goalId: "goal-v8-acceptance",
          idempotencyKey: "key-cancel",
          workRequestId: "request-v8-acceptance",
          organizationId: "workspace-fixture",
          builtinWorkflow: BUILTIN_WORKFLOWS.plan_implement,
        },
      } as never,
      step,
    );
    expect(result.status).toBe("cancelled");
    expect(gatewayCalls).toHaveLength(1);
  });
  it.each(["event", "lost_event"] as const)(
    "waits for a terminal notification instead of polling (%s)",
    async (completion) => {
      const definition = BUILTIN_WORKFLOWS.plan_implement;
      const { instance, step, waits, sleeps } = createAcceptanceRun(
        definition,
        { completion },
      );
      const result = await instance.run(
        {
          payload: {
            runId: "run-v8-acceptance",
            goalId: "goal-v8-acceptance",
            idempotencyKey: `key-${completion}`,
            workRequestId: "request-v8-acceptance",
            organizationId: "workspace-fixture",
            builtinWorkflow: definition,
          },
        } as never,
        step,
      );
      expect(result.status).toBe("completed");
      // One suspension per step; no two-second status sleeps at all.
      expect(waits).toHaveLength(definition.steps.length);
      expect(sleeps).toEqual([]);
      for (const wait of waits) {
        expect(wait.options).toMatchObject({
          type: "assignment-terminal",
          timeout: expect.stringMatching(/^\d+ seconds$/),
        });
      }
    },
  );
});
