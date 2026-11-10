import { describe, expect, it, vi } from "vitest";
import {
  BUILTIN_WORKFLOWS,
  BUILTIN_WORKFLOW_CATALOG,
  researchWorkflowV2,
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

import {
  recordAssignmentError,
  recordAssignmentResult,
} from "../src/assignment-dispatcher.js";
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
  // Research v2 roles: researchers on different models, separate synthesis.
  "research-1": { workerId: "worker-research", model: "model-a" },
  "research-2": { workerId: "worker-research", model: "model-b" },
  synthesis: { workerId: "worker-synthesis", model: "model-a" },
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
    /** Tasks whose provider run fails (by task-ID suffix). */
    failTaskSuffix?: string;
    /** Persisted task rows a retry run reads (step_id AS kind, ...). */
    persistedTasks?: Array<Record<string, unknown>>;
    parallelSlots?: number;
    manualCompletion?: boolean;
    /** Request carries `input.toolCall`; `toolReply` is the gateway's answer. */
    toolReply?: Record<string, unknown>;
  } = {},
) {
  const completion = options.completion ?? "during_dispatch";
  const pendingCompletions: Array<() => Promise<void>> = [];
  const pendingStarts: Array<() => void> = [];
  const wakeWaiters: Array<() => void> = [];
  const startedTasks: string[] = [];
  const completedTasks: string[] = [];
  let active = 0;
  let peakActive = 0;
  const waits: { name: string; options: unknown }[] = [];
  const sleeps: string[] = [];
  selectionCalls.length = 0;
  const gatewayCalls: Record<string, unknown>[] = [];
  const toolCalls: Record<string, unknown>[] = [];
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
              inputJson: JSON.stringify({
                originalRequest: requestText,
                ...(options.toolReply
                  ? {
                      toolCall: {
                        executionWorkspaceId: "workspace-fixture",
                        serverId: "echo",
                        tool: "echo",
                        toolDefinitionHash: "a".repeat(64),
                        arguments: { text: "hi" },
                      },
                    }
                  : {}),
              }),
              snapshotJson: JSON.stringify({
                originalRequest: requestText,
                resolvedBindings: workerBindings,
              }),
            } as T;
          }
          if (sql.includes("workspace_space_grants g")) return { ok: 1 } as T;
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
          return {
            results: (sql.includes("FROM workflow_tasks WHERE work_request_id")
              ? (options.persistedTasks ?? [])
              : []) as T[],
          };
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
      if (url.endsWith("/flush-queued")) return Response.json({});
      if (url.endsWith("/status")) {
        return Response.json({
          online: true,
          workspaceRuntimeId: "workspace-runtime-fixture",
          executionWorkspaceId: "workspace-fixture",
        });
      }
      if (url.endsWith("/mcp-tool-call")) {
        toolCalls.push(JSON.parse(String(init?.body)));
        return Response.json(options.toolReply ?? {});
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
      const complete = () =>
        options.failTaskSuffix &&
        String(snapshot.taskId).endsWith(options.failTaskSuffix)
          ? recordAssignmentError(database, assignmentId, {
              error: {
                code: "execution_failed",
                message: "provider failed",
                retryable: true,
              },
              failedAt: new Date().toISOString(),
            } as never).then(() => undefined)
          : recordAssignmentResult(database, assignmentId, {
              text: `completed ${String(snapshot.role)}`,
            } as never).then(() => undefined);
      const finish = async () => {
        await complete();
        active -= 1;
        completedTasks.push(String(snapshot.taskId));
        pendingStarts.shift()?.();
        for (const wake of wakeWaiters.splice(0)) wake();
      };
      const start = () => {
        if (row) row.status = "running";
        active += 1;
        peakActive = Math.max(peakActive, active);
        startedTasks.push(String(snapshot.taskId));
        pendingCompletions.push(finish);
      };
      if (active < (options.parallelSlots ?? Infinity)) start();
      else pendingStarts.push(start);
      if (completion === "during_dispatch" && !options.manualCompletion)
        await pendingCompletions.shift()?.();
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
      if (options.manualCompletion)
        await new Promise<void>((resolve) => wakeWaiters.push(resolve));
      else await pendingCompletions.shift()?.();
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
  return {
    instance,
    step,
    taskWrites,
    gatewayCalls,
    toolCalls,
    waits,
    sleeps,
    startedTasks,
    completedTasks,
    peakActive: () => peakActive,
    finishNext: async () => {
      const finish = pendingCompletions.shift();
      if (!finish) throw new Error("No running provider execution");
      await finish();
    },
  };
}

// Every catalog definition, including Research v2 with repeated step instances.
// Tool-call workflows have no Worker for every step; the tool step has its own
// coverage in mcp-tool-step.test.ts.
const workflowCases = Object.values(BUILTIN_WORKFLOW_CATALOG).filter(
  (definition) => definition.steps.every((step) => step.kind !== "tool_call"),
);

describe("Chat with tool (chat:v2) through the Workflow loop", () => {
  const run = (f: ReturnType<typeof createAcceptanceRun>) =>
    f.instance.run(
      {
        payload: {
          runId: "run-v8-acceptance",
          goalId: "goal-v8-acceptance",
          idempotencyKey: "key-chat-v2",
          workRequestId: "request-v8-acceptance",
          organizationId: "workspace-fixture",
          builtinWorkflow: BUILTIN_WORKFLOW_CATALOG["chat:v2"]!,
        },
      } as never,
      f.step,
    );

  it("calls the tool once, then gives its recorded result to the chat prompt as untrusted data", async () => {
    const f = createAcceptanceRun(BUILTIN_WORKFLOW_CATALOG["chat:v2"]!, {
      toolReply: {
        state: "completed",
        code: "completed",
        result: { content: [{ type: "text", text: "TOOL-RESULT-MARKER" }] },
      },
    });
    const result = await run(f);
    expect(result.status).toBe("completed");
    expect(f.toolCalls).toHaveLength(1);
    expect(f.toolCalls[0]).toMatchObject({ serverId: "echo", tool: "echo" });
    // Only the chat step reaches a Worker.
    expect(f.gatewayCalls).toHaveLength(1);
    const prompt = String(
      (f.gatewayCalls[0]!.payload as { snapshot: Record<string, unknown> })
        .snapshot.objective,
    );
    expect(prompt).toContain("TOOL-RESULT-MARKER");
    expect(prompt).toMatch(/untrusted/i);
  });

  it("stops without a chat answer when the tool outcome is unknown", async () => {
    const f = createAcceptanceRun(BUILTIN_WORKFLOW_CATALOG["chat:v2"]!, {
      toolReply: { state: "unknown", code: "result_timeout" },
    });
    const result = await run(f);
    expect(result.status).not.toBe("completed");
    expect(f.toolCalls).toHaveLength(1);
    expect(f.gatewayCalls).toHaveLength(0);
  });
});

describe("Work v1 acceptance through the shared assignment dispatcher", () => {
  it.each([1, 2])(
    "runs researchers within %i slots and synthesizes only after all reports",
    async (parallelSlots) => {
      const f = createAcceptanceRun(BUILTIN_WORKFLOW_CATALOG["research:v2"]!, {
        parallelSlots,
        manualCompletion: true,
      });
      const running = f.instance.run(
        {
          payload: {
            runId: "run-v8-acceptance",
            goalId: "goal-v8-acceptance",
            idempotencyKey: "research-capacity",
            workRequestId: "request-v8-acceptance",
            organizationId: "workspace-fixture",
            builtinWorkflow: BUILTIN_WORKFLOW_CATALOG["research:v2"]!,
          },
        } as never,
        f.step,
      );
      await vi.waitFor(() => expect(f.gatewayCalls).toHaveLength(2));
      expect(f.startedTasks).toHaveLength(parallelSlots);
      await f.finishNext();
      await vi.waitFor(() =>
        expect(
          f.taskWrites.some(
            (write) =>
              write.sql.includes("UPDATE workflow_tasks SET") &&
              write.values[0] === "completed" &&
              write.values[5] === f.completedTasks[0],
          ),
        ).toBe(true),
      );
      // Its report is durable while the other researcher is still executing.
      expect(f.gatewayCalls).toHaveLength(2);
      await f.finishNext();
      await vi.waitFor(() => expect(f.gatewayCalls).toHaveLength(3));
      expect(f.completedTasks).toHaveLength(2);
      expect(f.startedTasks.at(-1)).toMatch(/-synthesis$/);
      await f.finishNext();
      expect((await running).status).toBe("completed");
      expect(f.peakActive()).toBe(parallelSlots);
    },
  );
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
      const bindingIdOf = (item: (typeof definition.steps)[number]) =>
        definition.id === "direct"
          ? "direct"
          : ((item.id ?? item.kind) as keyof typeof workerBindings);
      expect(selectionCalls.map((call) => call.workBindingId)).toEqual(
        definition.steps.map(bindingIdOf),
      );
      expect(selectionCalls.map((call) => call.workerId)).toEqual(
        definition.steps.map(
          (item) => workerBindings[bindingIdOf(item)].workerId,
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
        const current = definition.steps[index]!;
        if (definition.id === "research" && definition.version === 2) {
          // Researchers see no sibling output; synthesis gets every report,
          // separately delimited and attributed to its model.
          if (current.kind === "research") {
            expect(prompt).not.toContain("RESEARCH REPORT");
            expect(prompt).toContain("Sources and tools used");
          } else {
            expect(prompt).toContain(
              "<<<RESEARCH REPORT 1 | step: research-1 | model: model-a>>>",
            );
            expect(prompt).toContain(
              "<<<RESEARCH REPORT 2 | step: research-2 | model: model-b>>>",
            );
            expect(prompt).toContain("untrusted evidence");
          }
          expect(assignment.readOnly).toBe(true);
          continue;
        }
        for (const inputKind of current.inputsFrom) {
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

  it("keeps a successful researcher's report and never synthesizes when a sibling fails", async () => {
    const definition = BUILTIN_WORKFLOW_CATALOG["research:v2"]!;
    const { instance, step, gatewayCalls, taskWrites } = createAcceptanceRun(
      definition,
      { failTaskSuffix: "-research-2" },
    );
    const result = await instance.run(
      {
        payload: {
          runId: "run-v8-acceptance",
          goalId: "goal-v8-acceptance",
          idempotencyKey: "key-research-branch-failure",
          workRequestId: "request-v8-acceptance",
          organizationId: "workspace-fixture",
          builtinWorkflow: definition,
        },
      } as never,
      step,
    );
    expect(result.status).toBe("failed");
    // Both researchers ran; synthesis was never dispatched.
    expect(
      gatewayCalls.map(
        (call) =>
          (call.payload as { snapshot: { taskId: string } }).snapshot.taskId,
      ),
    ).toEqual([
      "task-request-v8-acceptance-research-1",
      "task-request-v8-acceptance-research-2",
    ]);
    // Researcher 1's completed report is persisted despite the failure.
    expect(
      taskWrites.some(
        ({ sql, values }) =>
          sql.includes("UPDATE workflow_tasks SET status") &&
          values.includes("completed") &&
          values.includes("task-request-v8-acceptance-research-1"),
      ),
    ).toBe(true);
  });

  it("retries only the selected researcher when another researcher also failed", async () => {
    const definition = researchWorkflowV2(3);
    const { instance, step, gatewayCalls } = createAcceptanceRun(definition, {
      persistedTasks: [
        { kind: "research-1", status: "failed", attempt: 1, outputJson: null },
        { kind: "research-2", status: "failed", attempt: 1, outputJson: null },
        {
          kind: "research-3",
          status: "completed",
          attempt: 1,
          outputJson: JSON.stringify({
            text: "Report",
            status: "completed",
            startedAt: "s",
            completedAt: "c",
          }),
        },
        { kind: "synthesis", status: "queued", attempt: 0, outputJson: null },
      ],
    });
    const result = await instance.run(
      {
        payload: {
          runId: "run-targeted",
          goalId: "goal-v8-acceptance",
          idempotencyKey: "key-targeted",
          workRequestId: "request-v8-acceptance",
          organizationId: "workspace-fixture",
          builtinWorkflow: definition,
          retryStepKind: "research-1",
        },
      } as never,
      step,
    );
    expect(result.status).toBe("failed");
    expect(gatewayCalls).toHaveLength(1);
    expect(
      String(
        (gatewayCalls[0]!.payload as { snapshot: Record<string, unknown> })
          .snapshot.taskId,
      ),
    ).toMatch(/-research-1$/);
  });

  it("synthesizes only the successful reports on a user-requested partial synthesis, and names what is missing", async () => {
    const definition = BUILTIN_WORKFLOW_CATALOG["research:v2"]!;
    const report = JSON.stringify({
      text: "Use SQS.",
      status: "completed",
      model: "model-a",
      startedAt: "s",
      completedAt: "c",
    });
    const { instance, step, gatewayCalls } = createAcceptanceRun(definition, {
      persistedTasks: [
        {
          kind: "research-1",
          status: "completed",
          attempt: 1,
          outputJson: report,
        },
        { kind: "research-2", status: "failed", attempt: 1, outputJson: null },
        { kind: "synthesis", status: "queued", attempt: 0, outputJson: null },
      ],
    });
    const result = await instance.run(
      {
        payload: {
          runId: "run-partial",
          goalId: "goal-v8-acceptance",
          idempotencyKey: "key-partial",
          workRequestId: "request-v8-acceptance",
          organizationId: "workspace-fixture",
          builtinWorkflow: definition,
          retryStepKind: "synthesis",
          partialSynthesis: true,
        },
      } as never,
      step,
    );
    expect(result.status).toBe("completed");
    // The failed researcher is not re-run; only synthesis is dispatched.
    expect(gatewayCalls).toHaveLength(1);
    const snapshot = (
      gatewayCalls[0]!.payload as { snapshot: Record<string, unknown> }
    ).snapshot;
    expect(String(snapshot.taskId)).toMatch(/-synthesis$/);
    const prompt = String(snapshot.objective);
    expect(prompt).toContain("INCOMPLETE INVESTIGATION");
    expect(prompt).toContain("1 of 2 researchers failed (research-2)");
    expect(prompt).toContain("Use SQS.");
    expect(prompt).toContain("RESEARCH REPORT 1");
    expect(prompt).not.toContain("RESEARCH REPORT 2");
    expect(snapshot.readOnly).toBe(true);
  });

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
