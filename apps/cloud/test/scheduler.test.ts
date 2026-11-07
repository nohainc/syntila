import { describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { selectSpaceExecutionTarget } from "../src/scheduler.js";

const permissionAssignment = JSON.parse(
  readFileSync(
    new URL(
      "../../../packages/workspace-runtime-protocol/test/fixtures/execution-permission-assignment.json",
      import.meta.url,
    ),
    "utf8",
  ),
) as {
  permissions: string[];
  permissionSnapshot: { permissions: string[] };
};

function candidate(overrides: Record<string, unknown> = {}) {
  const workerTypeId = overrides.worker_type_id ?? "chatgpt";
  const profileDefinitionId =
    (Object.hasOwn(overrides, "profile_definition_id")
      ? overrides.profile_definition_id
      : undefined) ??
    (workerTypeId === "gemini" ? "gemini-antigravity" : "chatgpt-codex");
  return {
    grant_id: "grant-a",
    space_id: "space-a",
    workspace_id: "workspace-a",
    grant_status: "active",
    allowed_worker_ids_json: "[]",
    allowed_worker_capabilities_json: "[]",
    allowed_permissions_json: JSON.stringify([
      "repository:read",
      "repository:write",
    ]),
    network_policy_json: JSON.stringify({ mode: "deny_all", allowedHosts: [] }),
    concurrency_json: JSON.stringify({ maxConcurrentAssignments: 2 }),
    expires_at: null,
    workspace_name: "Contributor Workspace",
    owner_user_id: "user-contributor",
    space_workflow_workspace_id: "workspace-a",
    workspace_status: "online",
    runtime_identity_id: "runtime-a",
    worker_id: "worker-a",
    worker_type_id: "chatgpt",
    worker_catalog_lifecycle_state: "active",
    worker_catalog_visibility_state: "visible",
    worker_catalog_release_stage: "stable",
    workspace_tool_profile_channel: "stable",
    engine_version: "1.0.0",
    profile_definition_id: "chatgpt-codex",
    profile_release_version: 3,
    provider_tool_name: "Codex CLI",
    provider_tool_version: "0.44.0",
    execution_profile_json: JSON.stringify({
      model: {
        supported: true,
        catalog: [
          { id: "gpt-5.6-codex", name: "Codex" },
          { id: "gpt-5.5", name: "GPT" },
        ],
      },
    }),
    capabilities_json: JSON.stringify(["repository"]),
    local_permissions_json: JSON.stringify([
      "repository:read",
      "repository:write",
    ]),
    local_worker_activation_state: "enabled",
    local_worker_readiness_state: "ready",
    cloud_scheduling_state: "enabled",
    local_concurrency_limit: 2,
    active_assignments: 0,
    allowed_worker_type_ids_json: "[]",
    allowed_models_json: "[]",
    ...overrides,
    current_profile_definition_id: Object.hasOwn(
      overrides,
      "current_profile_definition_id",
    )
      ? overrides.current_profile_definition_id
      : profileDefinitionId,
  };
}

function db(
  rows: Record<string, unknown>[],
  role = "collaborator",
  lease: Record<string, unknown> | null = null,
  thread: Record<string, unknown> | null = {
    space_id: "space-a",
    lead_user_id: "user-a",
    access_policy_json: JSON.stringify({ allowedPermissions: ["execute"] }),
  },
  settings: Record<string, unknown> = {},
) {
  return {
    prepare(query: string) {
      let _values: unknown[] = [];
      return {
        bind(...bound: unknown[]) {
          _values = bound;
          return this;
        },
        async first<T>() {
          if (query.includes("workflow_id AS workflowId"))
            return {
              workflowId: "direct",
              requesterUserId: "user-a",
              threadId:
                lease?.threadId ??
                (rows.some((row) =>
                  String(row.work_request_snapshot_json).includes(
                    "resolvedBindings",
                  ),
                )
                  ? "thread-a"
                  : undefined),
            } as T;
          if (query.includes("thread_runtime_leases")) return lease as T;
          if (query.includes("FROM threads ws")) return thread as T;
          return query.includes("space_memberships")
            ? ({ role, settingsJson: JSON.stringify(settings) } as T)
            : null;
        },
        async all<T>() {
          return { results: rows as T[] };
        },
      };
    },
  } as never;
}

describe("Space execution scheduler", () => {
  it("emits the canonical permissions consumed by Workspace assignment execution", async () => {
    const target = await selectSpaceExecutionTarget(db([candidate()]), {
      spaceId: "space-a",
      requesterUserId: "user-a",
      role: "collaborator",
      capabilities: ["repository"],
    });

    expect(target?.effectivePermissions).toEqual(
      permissionAssignment.permissions,
    );
    expect(target?.permissionSnapshot.permissions).toEqual(
      permissionAssignment.permissionSnapshot.permissions,
    );
  });

  it("fails closed when a stored Grant contains a noncanonical permission", async () => {
    await expect(
      selectSpaceExecutionTarget(
        db([
          candidate({
            allowed_permissions_json: '["workspace:read"]',
          }),
        ]),
        {
          spaceId: "space-a",
          requesterUserId: "user-a",
          role: "collaborator",
          capabilities: ["repository"],
        },
      ),
    ).resolves.toBeNull();
  });

  it.each([
    ["Worker IDs", { allowed_worker_ids_json: '["../foreign"]' }],
    ["network policy", { network_policy_json: '{"mode":"allow_all"}' }],
    ["concurrency", { concurrency_json: '{"maxConcurrentAssignments":0}' }],
    ["status", { grant_status: "revoked" }],
  ])(
    "fails closed when stored Grant %s are invalid",
    async (_name, override) => {
      await expect(
        selectSpaceExecutionTarget(db([candidate(override)]), {
          spaceId: "space-a",
          requesterUserId: "user-a",
          role: "collaborator",
          capabilities: ["repository"],
        }),
      ).resolves.toBeNull();
    },
  );

  it.each([
    ["retired", { worker_catalog_lifecycle_state: "retired" }],
    ["hidden", { worker_catalog_visibility_state: "hidden" }],
    ["without its current Profile revision", { profile_release_version: null }],
    [
      "without its executable Profile payload",
      { execution_profile_json: null },
    ],
  ])("rejects a stale Ready Worker that is %s", async (_case, override) => {
    await expect(
      selectSpaceExecutionTarget(db([candidate(override)]), {
        spaceId: "space-a",
        requesterUserId: "user-a",
        role: "collaborator",
        capabilities: ["repository"],
      }),
    ).resolves.toBeNull();
  });

  it("uses the accepted Step snapshot for Worker and model", async () => {
    const configured = candidate({
      work_request_snapshot_json: JSON.stringify({
        defaultWorkflowId: "direct",
        resolvedBindings: {
          implement: {
            workerId: "worker-a",
            model: "gpt-5.6-codex",
          },
        },
      }),
    });
    const result = await selectSpaceExecutionTarget(db([configured]), {
      spaceId: "space-a",
      requesterUserId: "user-a",
      role: "Implementer",
      capabilities: ["repository"],
      threadId: "thread-a",
      workRequestId: "request-a",
      workBindingId: "implement" as const,
    });
    expect(result).toMatchObject({
      workerId: "worker-a",
      workerTypeId: "chatgpt",
      engineVersion: "1.0.0",
      profileDefinitionId: "chatgpt-codex",
      profileReleaseVersion: 3,
      providerToolName: "Codex CLI",
      providerToolVersion: "0.44.0",
      permissionSnapshot: {
        engineVersion: "1.0.0",
        profileDefinitionId: "chatgpt-codex",
        profileReleaseVersion: 3,
        model: "gpt-5.6-codex",
        providerToolName: "Codex CLI",
        providerToolVersion: "0.44.0",
      },
      model: "gpt-5.6-codex",
      selectionExplanation: {
        worker: {
          workBindingId: "implement",
          engineVersion: "1.0.0",
          profileDefinitionId: "chatgpt-codex",
          profileReleaseVersion: 3,
          providerToolName: "Codex CLI",
          providerToolVersion: "0.44.0",
          selection: "configured_preference",
        },
      },
    });

    const atLimit = await selectSpaceExecutionTarget(
      db([candidate({ ...configured, active_assignments: 2 })]),
      {
        spaceId: "space-a",
        requesterUserId: "user-a",
        role: "implementer",
        capabilities: ["repository"],
        threadId: "thread-a",
        workRequestId: "request-a",
        workBindingId: "implement",
      },
    );
    expect(atLimit).toBeNull();

    const queuedAtLimit = await selectSpaceExecutionTarget(
      db([candidate({ ...configured, active_assignments: 2 })]),
      {
        spaceId: "space-a",
        requesterUserId: "user-a",
        role: "implementer",
        capabilities: ["repository"],
        threadId: "thread-a",
        workRequestId: "request-a",
        workBindingId: "implement" as const,
        allowQueue: true,
      },
    );
    expect(queuedAtLimit?.workerId).toBe("worker-a");
  });

  it("schedules a Worker type unknown to application code", async () => {
    const dynamicWorker = candidate({
      worker_id: "workspace-worker-dynamic",
      worker_type_id: "dynamic-test-worker",
      profile_definition_id: "dynamic-test-cli",
      current_profile_definition_id: "dynamic-test-cli",
      provider_tool_name: "Fixture CLI",
      work_request_snapshot_json: JSON.stringify({
        defaultWorkflowId: "direct",
        resolvedBindings: {
          implement: { workerId: "workspace-worker-dynamic" },
        },
      }),
    });

    const target = await selectSpaceExecutionTarget(db([dynamicWorker]), {
      spaceId: "space-a",
      requesterUserId: "user-a",
      role: "implementer",
      capabilities: ["repository"],
      threadId: "thread-a",
      workRequestId: "request-a",
      workBindingId: "implement",
    });

    expect(target).toMatchObject({
      workerId: "workspace-worker-dynamic",
      workerTypeId: "dynamic-test-worker",
      profileDefinitionId: "dynamic-test-cli",
      providerToolName: "Fixture CLI",
    });
  });

  it("independently rejects a retired dynamic Worker reported Ready", async () => {
    const staleDynamicWorker = candidate({
      worker_id: "workspace-worker-dynamic",
      worker_type_id: "dynamic-test-worker",
      worker_catalog_lifecycle_state: "retired",
      profile_definition_id: "dynamic-test-cli",
      current_profile_definition_id: "dynamic-test-cli",
      provider_tool_name: "Fixture CLI",
      work_request_snapshot_json: JSON.stringify({
        defaultWorkflowId: "direct",
        resolvedBindings: {
          implement: { workerId: "workspace-worker-dynamic" },
        },
      }),
    });

    const target = await selectSpaceExecutionTarget(db([staleDynamicWorker]), {
      spaceId: "space-a",
      requesterUserId: "user-a",
      role: "implementer",
      capabilities: ["repository"],
      threadId: "thread-a",
      workRequestId: "request-a",
      workBindingId: "implement",
    });

    expect(target).toBeNull();
  });

  it("requires AX to configure a Thread Step before dispatch", async () => {
    const result = await selectSpaceExecutionTarget(db([candidate()]), {
      spaceId: "space-a",
      requesterUserId: "user-a",
      role: "reviewer",
      capabilities: ["repository"],
      threadId: "thread-a",
      workRequestId: "request-a",
      workBindingId: "verify",
    });
    expect(result).toBeNull();
  });

  it("fails closed when a Thread row is missing", async () => {
    const result = await selectSpaceExecutionTarget(
      db([candidate()], "collaborator", null, null),
      {
        spaceId: "space-a",
        requesterUserId: "user-a",
        role: "collaborator",
        capabilities: ["repository"],
        threadId: "thread-missing",
      },
    );
    expect(result).toBeNull();
  });

  it("treats Thread Worker Type policy as product IDs", async () => {
    const configured = {
      ...candidate(),
      work_request_snapshot_json: JSON.stringify({
        defaultWorkflowId: "direct",
        resolvedBindings: { implement: { workerId: "worker-a" } },
      }),
    };
    const request = {
      spaceId: "space-a",
      requesterUserId: "user-a",
      role: "implementer",
      capabilities: ["repository"],
      threadId: "thread-a",
      workRequestId: "request-a",
      workBindingId: "implement" as const,
    };
    const legacyPackageIdPolicy = await selectSpaceExecutionTarget(
      db([{ ...configured, allowed_worker_type_ids_json: '["codex"]' }]),
      request,
    );
    expect(legacyPackageIdPolicy).toBeNull();

    const productIdPolicy = await selectSpaceExecutionTarget(
      db([{ ...configured, allowed_worker_type_ids_json: '["chatgpt"]' }]),
      request,
    );
    expect(productIdPolicy?.workerTypeId).toBe("chatgpt");
  });

  it("selects an enabled, ready Workspace Worker from inventory", async () => {
    const currentCandidate = {
      ...candidate({ worker_type_id: "gemini" }),
      grant_id: "grant-current",
      space_id: "space-current",
      workspace_id: "workspace-current",
      grant_status: "active",
      allowed_worker_ids_json: "[]",
      allowed_worker_capabilities_json: "[]",
      allowed_permissions_json: JSON.stringify([
        "repository:read",
        "repository:write",
      ]),
      network_policy_json: JSON.stringify({
        mode: "deny_all",
        allowedHosts: [],
      }),
      concurrency_json: JSON.stringify({ maxConcurrentAssignments: 4 }),
      expires_at: null,
      workspace_name: "MacBook Pro",
      owner_user_id: "user-developer",
      workspace_status: "online",
      runtime_identity_id: "runtime-current",
      worker_id: "worker-antigravity-1",
      worker_type_id: "gemini",
      engine_version: "1.0.0",
      profile_definition_id: "gemini-antigravity",
      profile_release_version: 3,
      capabilities_json: JSON.stringify(["code", "shell"]),
      local_permissions_json: JSON.stringify([
        "repository:read",
        "repository:write",
      ]),
      local_worker_activation_state: "enabled",
      local_worker_readiness_state: "ready",
      cloud_scheduling_state: "enabled",
      provider: "gemini",
      local_concurrency_limit: 2,
      active_assignments: 0,
    };

    const target = await selectSpaceExecutionTarget(
      db([currentCandidate], "collaborator"),
      {
        spaceId: "space-current",
        requesterUserId: "user-requester",
        role: "implementer",
        capabilities: ["code"],
      },
    );

    expect(target).toMatchObject({
      spaceId: "space-current",
      workspaceId: "workspace-current",
      workerId: "worker-antigravity-1",
      workerTypeId: "gemini",
      effectivePermissions: ["repository:read"],
    });
  });

  it("narrows candidate Workers by Thread type and model policy", async () => {
    const currentWorker = {
      ...candidate(),
      grant_id: "grant-current",
      space_id: "space-current",
      workspace_id: "workspace-current",
      grant_status: "active",
      allowed_worker_ids_json: "[]",
      allowed_worker_capabilities_json: "[]",
      allowed_permissions_json: JSON.stringify([
        "repository:read",
        "repository:write",
      ]),
      network_policy_json: JSON.stringify({
        mode: "deny_all",
        allowedHosts: [],
      }),
      concurrency_json: JSON.stringify({ maxConcurrentAssignments: 2 }),
      expires_at: null,
      workspace_name: "MacBook Pro",
      owner_user_id: "user-developer",
      workspace_status: "online",
      runtime_identity_id: "runtime-current",
      worker_id: "worker-chatgpt-1",
      worker_type_id: "chatgpt",
      engine_version: "1.0.0",
      profile_definition_id: "chatgpt-codex",
      profile_release_version: 3,
      capabilities_json: JSON.stringify(["code"]),
      local_permissions_json: JSON.stringify(["repository:read"]),
      local_worker_activation_state: "enabled",
      local_worker_readiness_state: "ready",
      cloud_scheduling_state: "enabled",
      provider: "chatgpt",
      local_concurrency_limit: 1,
      active_assignments: 0,
    };

    // 1. Rejected if allowed_worker_type_ids_json excludes this worker type
    await expect(
      selectSpaceExecutionTarget(
        db(
          [
            {
              ...currentWorker,
              allowed_worker_type_ids_json: JSON.stringify(["gemini"]),
            },
          ],
          "collaborator",
        ),
        {
          spaceId: "space-current",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["code"],
        },
      ),
    ).resolves.toBeNull();

    // 2. Rejected if allowed_models_json excludes requested model
    await expect(
      selectSpaceExecutionTarget(
        db(
          [
            {
              ...currentWorker,
              allowed_models_json: JSON.stringify(["gpt-4o"]),
            },
          ],
          "collaborator",
        ),
        {
          spaceId: "space-current",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["code"],
          model: "gpt-5.5",
        },
      ),
    ).resolves.toBeNull();

    // 3. Allowed when matching policy
    await expect(
      selectSpaceExecutionTarget(
        db(
          [
            {
              ...currentWorker,
              allowed_worker_type_ids_json: JSON.stringify(["chatgpt"]),
              allowed_models_json: JSON.stringify(["gpt-5.5"]),
            },
          ],
          "collaborator",
        ),
        {
          spaceId: "space-current",
          requesterUserId: "user-requester",
          role: "implementer",
          capabilities: ["code"],
          model: "gpt-5.5",
        },
      ),
    ).resolves.toMatchObject({
      workerId: "worker-chatgpt-1",
      workerTypeId: "chatgpt",
      model: "gpt-5.5",
      effectivePermissions: ["repository:read"],
    });
  });

  it("uses only the Space role and Workspace Grant at the Cloud boundary", async () => {
    const currentWorker = {
      ...candidate(),
      grant_id: "grant-current",
      space_id: "space-current",
      workspace_id: "workspace-current",
      grant_status: "active",
      allowed_worker_ids_json: "[]",
      allowed_worker_capabilities_json: "[]",
      // Cloud grant permits all four canonical assignment permissions.
      allowed_permissions_json: JSON.stringify([
        "repository:read",
        "repository:write",
        "shell:execute",
        "network:use",
      ]),
      network_policy_json: JSON.stringify({
        mode: "allowlist",
        allowedHosts: ["api.example.com"],
      }),
      concurrency_json: JSON.stringify({ maxConcurrentAssignments: 2 }),
      expires_at: null,
      workspace_name: "MacBook Pro",
      owner_user_id: "user-developer",
      workspace_status: "online",
      runtime_identity_id: "runtime-current",
      worker_id: "worker-sandboxed",
      worker_type_id: "chatgpt",
      engine_version: "1.0.0",
      profile_definition_id: "chatgpt-codex",
      profile_release_version: 3,
      capabilities_json: JSON.stringify(["code"]),
      // Deliberately conflicting data proves Cloud does not simulate local
      // Workspace permissions in its authorization intersection.
      local_permissions_json: JSON.stringify(["repository:read"]),
      local_worker_activation_state: "enabled",
      local_worker_readiness_state: "ready",
      cloud_scheduling_state: "enabled",
      provider: "chatgpt",
      local_concurrency_limit: 1,
      active_assignments: 0,
    };

    const target = await selectSpaceExecutionTarget(
      db([currentWorker], "owner"),
      {
        spaceId: "space-current",
        requesterUserId: "user-developer",
        role: "owner",
        capabilities: ["code"],
      },
    );

    expect(target).not.toBeNull();
    expect(target?.effectivePermissions).toEqual([
      "repository:read",
      "network:use",
    ]);
  });

  it("requires independent Cloud enablement and local readiness for current scheduling", async () => {
    const base = {
      ...candidate(),
      workspace_id: "workspace-current",
      worker_id: "worker-current",
      worker_type_id: "chatgpt",
      capabilities_json: '["repository"]',
      local_permissions_json: '["repository:read"]',
      local_worker_activation_state: "enabled",
      local_worker_readiness_state: "ready",
      cloud_scheduling_state: "disabled",
      cloud_concurrency_limit: null,
      local_concurrency_limit: 2,
      active_assignments: 0,
    };
    const request = {
      spaceId: "space-a",
      requesterUserId: "user-requester",
      role: "implementer",
      capabilities: ["repository"],
    };
    await expect(
      selectSpaceExecutionTarget(db([base]), request),
    ).resolves.toBeNull();
    await expect(
      selectSpaceExecutionTarget(
        db([{ ...base, cloud_scheduling_state: "draining" }]),
        request,
      ),
    ).resolves.toBeNull();
    await expect(
      selectSpaceExecutionTarget(
        db([
          {
            ...base,
            cloud_scheduling_state: "enabled",
            local_worker_activation_state: "disabled",
            local_worker_readiness_state: "ready",
          },
        ]),
        request,
      ),
    ).resolves.toBeNull();
    await expect(
      selectSpaceExecutionTarget(
        db([
          {
            ...base,
            cloud_scheduling_state: "enabled",
            local_worker_activation_state: "enabled",
            local_worker_readiness_state: "setup_required",
          },
        ]),
        request,
      ),
    ).resolves.toBeNull();
    await expect(
      selectSpaceExecutionTarget(
        db([{ ...base, cloud_scheduling_state: "enabled" }]),
        request,
      ),
    ).resolves.toMatchObject({ workerId: "worker-current" });
    await expect(
      selectSpaceExecutionTarget(
        db([
          {
            ...base,
            cloud_scheduling_state: "enabled",
            profile_release_version: null,
          },
        ]),
        request,
      ),
    ).resolves.toBeNull();
    await expect(
      selectSpaceExecutionTarget(
        db([
          { ...base, cloud_scheduling_state: "enabled", active_assignments: 2 },
        ]),
        request,
      ),
    ).resolves.toBeNull();
    await expect(
      selectSpaceExecutionTarget(
        db([
          {
            ...base,
            cloud_scheduling_state: "enabled",
            cloud_concurrency_limit: 1,
            active_assignments: 1,
          },
        ]),
        request,
      ),
    ).resolves.toBeNull();
  });

  it("uses live Workspace Gateway state instead of the persisted online projection", async () => {
    const offlineProjection = {
      ...candidate(),
      workspace_id: "workspace-live",
      runtime_identity_id: "runtime-live",
      workspace_status: "offline",
      cloud_scheduling_state: "enabled",
      local_worker_activation_state: "enabled",
      local_worker_readiness_state: "ready",
      active_assignments: 0,
    };
    const request = {
      spaceId: "space-a",
      requesterUserId: "user-requester",
      role: "implementer",
      capabilities: ["repository"],
    };
    const liveCheck = vi.fn(async () => true);
    const target = await selectSpaceExecutionTarget(
      db([offlineProjection]),
      request,
      new Date(),
      liveCheck,
    );

    expect(target?.workspaceId).toBe("workspace-live");
    expect(liveCheck).toHaveBeenCalledWith("workspace-live", "runtime-live");
    await expect(
      selectSpaceExecutionTarget(
        db([{ ...offlineProjection, workspace_status: "online" }]),
        request,
        new Date(),
        async () => false,
      ),
    ).resolves.toBeNull();
  });
});

describe("scheduling by Service readiness", () => {
  const request = {
    spaceId: "space-a",
    requesterUserId: "user-requester",
    role: "implementer",
    capabilities: ["repository"],
  };
  const workspace = (id: string, active = 0) => ({
    ...candidate(),
    workspace_id: id,
    runtime_identity_id: `runtime-${id}`,
    active_assignments: active,
  });

  it("prefers a ready Service over a connected one that is still synchronizing", async () => {
    // The synchronizing Workspace sorts first (less loaded); readiness, not
    // connection liveness, decides.
    const states: Record<string, "ready" | "connected"> = {
      "workspace-syncing": "connected",
      "workspace-ready": "ready",
    };
    const target = await selectSpaceExecutionTarget(
      db([workspace("workspace-syncing", 0), workspace("workspace-ready", 1)]),
      request,
      new Date(),
      async (workspaceId) => states[workspaceId]!,
    );
    expect(target?.workspaceId).toBe("workspace-ready");
    expect(target?.selectionExplanation).toMatchObject({
      workspace: { readiness: "ready" },
    });
  });

  it("falls back to a connected but unready Service so the work can be queued durably", async () => {
    const target = await selectSpaceExecutionTarget(
      db([workspace("workspace-syncing")]),
      request,
      new Date(),
      async () => "connected",
    );
    expect(target?.workspaceId).toBe("workspace-syncing");
    expect(target?.selectionExplanation).toMatchObject({
      workspace: { readiness: "connected" },
    });
  });

  it("never selects a disconnected Service", async () => {
    await expect(
      selectSpaceExecutionTarget(
        db([workspace("workspace-gone")]),
        request,
        new Date(),
        async () => false,
      ),
    ).resolves.toBeNull();
  });

  it("treats a plain true live check as ready", async () => {
    const target = await selectSpaceExecutionTarget(
      db([workspace("workspace-legacy")]),
      request,
      new Date(),
      async () => true,
    );
    expect(target?.selectionExplanation).toMatchObject({
      workspace: { readiness: "ready" },
    });
  });
});

it.each(["turn", "step"])(
  "refuses silently replacing an accepted %s Profile release",
  async (kind) => {
    const target = await selectSpaceExecutionTarget(
      db([
        candidate({
          work_request_snapshot_json: JSON.stringify({
            ...((config: object) =>
              kind === "step"
                ? { stepExecutionConfigs: { collaborator: config } }
                : { turnExecutionConfig: config })({
              schemaVersion: 1,
              workerId: "worker-a",
              profileId: "chatgpt-codex",
              profileReleaseVersion: 2,
              modelId: null,
              effort: null,
            }),
          }),
        }),
      ]),
      {
        spaceId: "space-a",
        requesterUserId: "user-a",
        role: "collaborator",
        capabilities: ["repository"],
        workRequestId: "request-a",
      },
    );
    expect(target).toBeNull();
  },
);

it.each([
  ["research-1", "research", "worker-a", "gpt-5.5"],
  ["research-2", "research", "worker-b", "gpt-5.6-codex"],
  ["synthesis", "synthesis", "worker-a", "gpt-5.5"],
])(
  "schedules %s using its frozen instance configuration",
  async (bindingId, role, workerId, model) => {
    const bindings = {
      "research-1": { workerId: "worker-a", model: "gpt-5.5" },
      "research-2": { workerId: "worker-b", model: "gpt-5.6-codex" },
      synthesis: { workerId: "worker-a", model: "gpt-5.5" },
    };
    const configs = Object.fromEntries(
      Object.entries(bindings).map(([id, binding]) => [
        id,
        {
          schemaVersion: 1,
          workerId: binding.workerId,
          profileId: "chatgpt-codex",
          profileReleaseVersion: 3,
          modelId: binding.model,
          effort: null,
        },
      ]),
    );
    const request = {
      spaceId: "space-a",
      requesterUserId: "user-a",
      role,
      capabilities: ["repository"],
      workRequestId: "request-a",
      workBindingId: bindingId,
      threadId: "thread-a",
      executionClass: "stateless_read" as const,
    };
    const rows = (stepExecutionConfigs: object) =>
      ["worker-a", "worker-b"].map((worker_id) =>
        candidate({
          worker_id,
          work_request_snapshot_json: JSON.stringify({
            resolvedBindings: bindings,
            stepExecutionConfigs,
          }),
        }),
      );
    const target = await selectSpaceExecutionTarget(db(rows(configs)), request);
    expect(target).toMatchObject({ workerId, model, readOnly: true });
    expect(target?.effectivePermissions).not.toContain("repository:write");
    // A kind-level config must not substitute for a missing researcher instance.
    const missing: Record<string, unknown> = {
      ...configs,
      research: configs[bindingId],
    };
    delete missing[bindingId];
    expect(
      await selectSpaceExecutionTarget(db(rows(missing)), request),
    ).toBeNull();
  },
);

it("keeps Work's direct binding separate from its implement step configuration", async () => {
  const target = await selectSpaceExecutionTarget(
    db([
      candidate({
        work_request_snapshot_json: JSON.stringify({
          resolvedBindings: { direct: { workerId: "worker-a" } },
          stepExecutionConfigs: {
            implement: {
              schemaVersion: 1,
              workerId: "worker-a",
              profileId: "chatgpt-codex",
              profileReleaseVersion: 3,
              modelId: "gpt-5.5",
              effort: null,
            },
          },
        }),
      }),
    ]),
    {
      spaceId: "space-a",
      requesterUserId: "user-a",
      role: "implement",
      capabilities: ["repository"],
      workRequestId: "request-a",
      workBindingId: "direct",
      threadId: "thread-a",
    },
  );
  expect(target).toMatchObject({ workerId: "worker-a", model: "gpt-5.5" });
});

it.each(["turn", "step"])(
  "dispatches accepted %s Default model and effort even when later defaults differ",
  async (kind) => {
    const target = await selectSpaceExecutionTarget(
      db([
        candidate({
          work_request_snapshot_json: JSON.stringify({
            ...((config: object) =>
              kind === "step"
                ? { stepExecutionConfigs: { collaborator: config } }
                : { turnExecutionConfig: config })({
              schemaVersion: 1,
              workerId: "worker-a",
              profileId: "chatgpt-codex",
              profileReleaseVersion: 3,
              modelId: null,
              effort: null,
            }),
          }),
        }),
      ]),
      {
        spaceId: "space-a",
        requesterUserId: "user-a",
        role: "collaborator",
        capabilities: ["repository"],
        workRequestId: "request-a",
        model: "later-model",
        reasoningEffort: "high",
      },
    );
    expect(target).not.toBeNull();
    expect(target!.model).toBeNull();
    expect(target!.reasoningEffort).toBeNull();
  },
);

it("rechecks granular rights at dispatch and ignores the retired Space-wide switch for accepted work", async () => {
  const request = {
    spaceId: "space-a",
    requesterUserId: "user-a",
    role: "collaborator",
    capabilities: ["repository"],
  };
  const chatOnly = {
    memberPermissions: {
      "user-a": {
        chat: true,
        work: false,
        manageOwnThreads: false,
      },
    },
  };
  expect(
    await selectSpaceExecutionTarget(
      db([candidate()], "collaborator", null, undefined, chatOnly),
      request,
    ),
  ).toBeNull();
  expect(
    await selectSpaceExecutionTarget(
      db([candidate()], "collaborator", null, undefined, chatOnly),
      { ...request, workBindingId: "chat" },
    ),
  ).not.toBeNull();
  expect(
    await selectSpaceExecutionTarget(
      db([candidate()], "owner", null, undefined, { allowWork: false }),
      request,
    ),
  ).not.toBeNull();
  expect(
    await selectSpaceExecutionTarget(
      db([candidate()], "owner", null, undefined, { allowWork: false }),
      { ...request, workBindingId: "chat" },
    ),
  ).not.toBeNull();
});

it("runs Chat outside the Space Workspace only on the requester's own Workspace while own Workers are allowed", async () => {
  const request = {
    spaceId: "space-a",
    requesterUserId: "user-a",
    role: "collaborator",
    capabilities: ["repository"],
    workBindingId: "chat" as const,
  };
  const own = candidate({
    workspace_id: "workspace-own",
    owner_user_id: "user-a",
    workspace_owner_name: "Alice",
  });
  const allowed = await selectSpaceExecutionTarget(db([own]), request);
  expect(allowed?.workspaceId).toBe("workspace-own");
  expect(allowed?.permissionSnapshot).toMatchObject({
    workerOwnerUserId: "user-a",
    workerOwnerName: "Alice",
  });
  const denied = {
    memberPermissions: {
      "user-a": {
        chat: false,
        work: true,
        manageOwnThreads: true,
      },
    },
  };
  expect(
    await selectSpaceExecutionTarget(
      db([own], "collaborator", null, undefined, denied),
      request,
    ),
  ).toBeNull();
  // A legacy stored useOwnWorkers: false is ignored; Chat alone decides.
  const legacy = {
    memberPermissions: {
      "user-a": { chat: true, useOwnWorkers: false, work: false },
    },
  };
  expect(
    (
      await selectSpaceExecutionTarget(
        db([own], "collaborator", null, undefined, legacy),
        request,
      )
    )?.workspaceId,
  ).toBe("workspace-own");
  // A Worker of the Space Workflow Workspace is not attributed to its owner.
  const spaceTarget = await selectSpaceExecutionTarget(
    db([candidate({ workspace_owner_name: "Owner" })]),
    request,
  );
  expect(spaceTarget?.permissionSnapshot.workerOwnerName).toBeNull();
  // Another member's personal Workspace never serves this requester.
  expect(
    await selectSpaceExecutionTarget(
      db([candidate({ workspace_id: "workspace-other" })]),
      request,
    ),
  ).toBeNull();
});

it("revalidates exact model and effort at dispatch without fallback", async () => {
  const request = {
    spaceId: "space-a",
    requesterUserId: "user-a",
    role: "collaborator",
    capabilities: [],
    model: "gpt-5.5",
  };
  expect(
    await selectSpaceExecutionTarget(db([candidate()]), request),
  ).not.toBeNull();
  expect(
    await selectSpaceExecutionTarget(db([candidate()]), {
      ...request,
      reasoningEffort: "invented",
    }),
  ).toBeNull();
  expect(
    await selectSpaceExecutionTarget(db([candidate()]), {
      ...request,
      catalogRevision: "f".repeat(64),
    }),
  ).toBeNull();
  expect(
    await selectSpaceExecutionTarget(
      db([candidate({ execution_profile_json: null })]),
      request,
    ),
  ).toBeNull();
  expect(
    await selectSpaceExecutionTarget(
      db([candidate({ workspace_status: "offline" })]),
      request,
    ),
  ).toBeNull();
});

it("requires a pin-capable Engine and freezes the normalized Gemini selection before dispatch", async () => {
  const profile = JSON.parse(
    readFileSync(
      new URL("../../profile_lab/assets/profiles/gemini.json", import.meta.url),
      "utf8",
    ),
  );
  const catalog = {
    schemaVersion: 2,
    profileDigest: "a".repeat(64),
    providerToolVersion: "1.3.3",
    catalogRevision: "b".repeat(64),
    discoveredAt: "2026-10-11T00:00:00Z",
    models: [
      {
        id: "gemini-3.1-pro",
        name: "Original Pro",
        efforts: ["low", "high"],
        defaultEffort: null,
        selectionMode: "combined",
        status: "listed",
      },
    ],
  };
  const row = candidate({
    worker_type_id: "gemini",
    profile_definition_id: "gemini-antigravity",
    provider_tool_version: "1.3.3",
    execution_profile_json: JSON.stringify(profile),
    execution_profile_digest: catalog.profileDigest,
    model_catalog_json: JSON.stringify(catalog),
  });
  const request = {
    spaceId: "space-a",
    requesterUserId: "user-a",
    role: "collaborator",
    capabilities: ["repository"],
    model: "gemini-3.1-pro",
    reasoningEffort: "high",
    catalogRevision: catalog.catalogRevision,
  };
  expect(
    await selectSpaceExecutionTarget(
      db([{ ...row, engine_version: "1.2.0" }]),
      request,
    ),
  ).toBeNull();
  const target = await selectSpaceExecutionTarget(
    db([{ ...row, engine_version: "1.3.0" }]),
    request,
  );
  expect(target?.permissionSnapshot.executionSelection).toMatchObject({
    modelId: "gemini-3.1-pro",
    modelName: "Original Pro",
    effort: "high",
    catalogRevision: catalog.catalogRevision,
  });
  expect(target?.permissionSnapshot.executionSelection).not.toHaveProperty(
    "resolvedNativeModelId",
  );
});
