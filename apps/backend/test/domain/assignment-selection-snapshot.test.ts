import { expect, it, vi } from "./helpers/vitest-compat";
import { dispatchTaskAssignment } from "../../src/domain/assignment-dispatcher.js";
import {
  parseWorkspaceRuntimeMessage,
  WORKSPACE_RUNTIME_PROTOCOL_NAME,
  WORKSPACE_RUNTIME_PROTOCOL_VERSION,
} from "@syntila/workspace-runtime-protocol";
const scheduler = vi.hoisted(() => ({ selectSpaceExecutionTarget: vi.fn() }));
vi.mock("../../src/domain/scheduler.js", () => scheduler);

it.each([null, "low"])(
  "dispatch uses the frozen effort %s even if the task has a later override",
  async (effort) => {
    const selection = {
      schemaVersion: 1,
      workerTypeId: "gemini",
      workerDisplayName: "Original Worker",
      profileReleaseVersion: 2,
      catalogSource: "profile_catalog",
      modelId: "family",
      modelName: "Original Family",
      effort,
      catalogRevision: "a".repeat(64),
      modelSource: "explicit",
      effortSource: effort === null ? "provider_default" : "explicit",
    };
    scheduler.selectSpaceExecutionTarget.mockResolvedValue({
      spaceId: "space",
      workspaceId: "workspace",
      workspaceRuntimeIdentityId: "runtime",
      workspaceSpaceGrantId: "grant",
      workerId: "worker",
      workerTypeId: "gemini",
      engineVersion: "1.3.0",
      profileDefinitionId: "profile",
      profileReleaseVersion: 2,
      providerToolName: "Provider",
      providerToolVersion: "1.0.0",
      model: "family",
      reasoningEffort: effort,
      effectivePermissions: ["repository:read"],
      permissionSnapshot: {
        executionSelection: selection,
        permissions: ["repository:read"],
      },
      selectionExplanation: {},
      executionClass: "stateless_read",
      readOnly: true,
    });
    let persisted: unknown[] = [];
    const db = {
      prepare(sql: string) {
        return {
          bind(...values: unknown[]) {
            if (sql.includes("INSERT INTO worker_assignments"))
              persisted = values;
            return this;
          },
          async first() {
            if (sql.includes("INSERT INTO worker_assignments"))
              return { id: persisted[0] };
            return null;
          },
          async run() {
            return {};
          },
          async all() {
            return { results: [] };
          },
        };
      },
    };
    let sent: Record<string, unknown> | undefined;
    const namespace = {
      idFromName() {
        return "workspace";
      },
      get() {
        return {
          async fetch(_url: string, init: RequestInit) {
            sent = JSON.parse(init.body as string);
            return new Response("{}");
          },
        };
      },
    };
    const result = await dispatchTaskAssignment(
      {
        SYNTILA_DB: db as unknown as D1Database,
        SYNTILA_WORKSPACE_GATEWAY:
          namespace as unknown as DurableObjectNamespace,
      },
      {
        workspaceId: "workspace",
        runId: "run",
        taskId: "task",
        task: {
          id: "task",
          role: "collaborator",
          objective: "Prompt",
          spaceId: "space",
          requestedByUserId: "user",
          model: "changed-later",
          reasoningEffort: "high",
        },
      },
    );
    expect(result.accepted).toBe(true);
    const message = parseWorkspaceRuntimeMessage({
      ...sent,
      protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
      protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
      messageId: "message",
      timestamp: "2026-10-11T00:00:00Z",
      type: "assignment.start",
    });
    expect(
      (message.payload as { snapshot: Record<string, unknown> }).snapshot,
    ).toMatchObject({
      model: "family",
      reasoningEffort: effort,
      executionSelection: selection,
    });
    expect(JSON.parse(persisted[15] as string).executionSelection).toEqual(
      selection,
    );
  },
);
