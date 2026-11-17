import { conversationFixture } from "./helpers/conversation";
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
      spaceId: "P",
      workspaceId: "WS",
      workspaceRuntimeIdentityId: "RT",
      workspaceSpaceGrantId: "G",
      workerId: "worker-a",
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
        profileDefinitionId: "profile",
        profileReleaseVersion: 2,
        workerDisplayName: "Original Worker",
        executionSelection: selection,
        permissions: ["repository:read"],
      },
      selectionExplanation: {},
      executionClass: "stateless_read",
      readOnly: true,
    });
    const f = await conversationFixture();
    f.sqlite.exec(`
      INSERT INTO runs(id,space_id,status,created_at,updated_at) VALUES('RUN','P','running','now','now');
      INSERT INTO workspace_space_grants(id,space_id,workspace_id,granted_by_user_id,created_at,updated_at) VALUES('G','P','WS','U','now','now');
      INSERT INTO workspace_worker_inventory (
        worker_id, workspace_id, owner_user_id, worker_type_id, activation_state, readiness_state,
        local_concurrency_limit, revision, created_at, updated_at, last_seen_at
      ) VALUES ('worker-a', 'WS', 'U', 'gemini', 'enabled', 'ready', 1, 1, now(), now(), now());`);
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
        SYNTILA_DB: f.db,
        SYNTILA_WORKSPACE_GATEWAY:
          namespace as unknown as DurableObjectNamespace,
      },
      {
        workspaceId: "WS",
        runId: "RUN",
        taskId: "T",
        task: {
          id: "T",
          role: "collaborator",
          objective: "Prompt",
          spaceId: "P",
          requestedByUserId: "U",
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
    const stored = f.sqlite
      .prepare(
        "SELECT permission_snapshot_json AS snapshot FROM worker_assignments WHERE task_id = 'T' AND run_id = 'RUN'",
      )
      .get() as { snapshot: string };
    expect(JSON.parse(stored.snapshot).executionSelection).toEqual(selection);
  },
);
