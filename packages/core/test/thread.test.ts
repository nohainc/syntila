import { describe, expect, it } from "vitest";
import {
  type DiscussionMessage,
  type SpaceMembership,
  type WorkRequest,
  type Thread,
  type ThreadExecutionLease,
  type ThreadExecutionPolicy,
  type BuiltinWorkflowDefinition,
  BUILTIN_WORKFLOWS,
  BUILTIN_WORKFLOW_CATALOG,
  STEP_KINDS,
  STEP_HARD_CAP_MS,
  effectiveStepTimeoutMs,
  WORKFLOW_IDS,
  THREAD_BINDING_IDS,
  deserializeEntity,
  serializeEntity,
  validateBuiltinWorkflowDefinition,
  validateWorkRequest,
  validateThread,
  validateThreadLeases,
  canDiscussThread,
  canExecuteThread,
  canManageThread,
  canViewThread,
} from "../src/index.js";

const memberships: SpaceMembership[] = [
  {
    id: "membership-owner",
    spaceId: "space-1",
    userId: "owner-1",
    role: "owner",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
  },
  {
    id: "membership-collaborator",
    spaceId: "space-1",
    userId: "collaborator-1",
    role: "collaborator",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
  },
  {
    id: "membership-viewer",
    spaceId: "space-1",
    userId: "viewer-1",
    role: "viewer",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
  },
];

const thread: Thread = {
  id: "thread-1",
  spaceId: "space-1",
  name: "Authentication",
  status: "active",
  accessPolicy: {
    allowedUserIds: ["owner-1", "collaborator-1"],
    allowedSpaceRoles: ["owner", "collaborator"],
    allowedPermissions: ["repository:read"],
  },
  lead: {
    userId: "collaborator-1",
    assignedAt: "2026-01-01T00:00:00.000Z",
    assignedByUserId: "owner-1",
  },
  createdAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:00.000Z",
};

const statefulPolicy: ThreadExecutionPolicy = {
  mode: "stateful",
  primaryWorkspaceId: "workspace-1",
};

describe("Thread domain", () => {
  it("defines Chat as a distinct read-only conversation workflow", () => {
    expect(STEP_KINDS).toContain("chat");
    expect(WORKFLOW_IDS).toContain("chat");
    expect(THREAD_BINDING_IDS.filter((id) => id === "chat")).toEqual(["chat"]);
    expect(BUILTIN_WORKFLOW_CATALOG["chat:v1"]).toBe(BUILTIN_WORKFLOWS.chat);
    expect(BUILTIN_WORKFLOWS.chat.steps).toEqual([
      {
        kind: "chat",
        order: 0,
        executionMode: "stateless_read",
        executionClass: "analysis",
        requiredCapabilities: ["authorized_context_read"],
        readWritePolicy: "read_only",
        timeoutMs: 900000,
        promptProfileVersion: "chat:v1",
        dependsOn: [],
        inputsFrom: [],
        resultSemantics: "conversation_response",
      },
    ]);
    for (const id of [
      "direct",
      "research",
      "plan_implement",
      "implement_verify",
      "full_cycle",
    ] as const) {
      expect(
        BUILTIN_WORKFLOWS[id].steps.map((step) => step.kind),
      ).not.toContain("chat");
    }
    expect(BUILTIN_WORKFLOWS.full_cycle.steps.map((step) => step.kind)).toEqual(
      ["research", "plan", "implement", "test", "verify"],
    );
  });
  it("requires a Space owner or collaborator as the lead", () => {
    expect(() => validateThread(thread, memberships)).not.toThrow();
    expect(() =>
      validateThread(
        { ...thread, lead: { ...thread.lead, userId: "viewer-1" } },
        memberships,
      ),
    ).toThrow(/lead must be a Space owner or collaborator/);
  });

  it("prevents Thread access from expanding Space membership", () => {
    expect(() =>
      validateThread(
        {
          ...thread,
          accessPolicy: {
            ...thread.accessPolicy,
            allowedUserIds: ["viewer-1"],
          },
        },
        memberships,
      ),
    ).toThrow(/cannot expand Space membership/);
  });

  it("intersects Space roles with selected Space members and permissions", () => {
    const restricted = {
      ...thread,
      accessPolicy: {
        allowedUserIds: ["collaborator-1", "viewer-1"],
        allowedSpaceRoles: ["collaborator", "viewer"] as const,
        allowedPermissions: ["view", "discuss"] as const,
      },
    };
    const owner = memberships[0]!;
    const collaborator = memberships[1]!;
    const viewer = memberships[2]!;

    expect(canViewThread(owner.userId, owner, restricted)).toBe(true);
    expect(canViewThread(collaborator.userId, collaborator, restricted)).toBe(
      true,
    );
    expect(
      canDiscussThread(collaborator.userId, collaborator, restricted),
    ).toBe(true);
    expect(
      canExecuteThread(collaborator.userId, collaborator, restricted),
    ).toBe(false);
    expect(canViewThread(viewer.userId, viewer, restricted)).toBe(true);
    expect(canDiscussThread(viewer.userId, viewer, restricted)).toBe(false);
    expect(canExecuteThread(viewer.userId, viewer, restricted)).toBe(false);
  });

  it("removes access with Space membership and gives the lead management authority", () => {
    const collaborator = memberships[1]!;
    expect(canManageThread(collaborator.userId, collaborator, thread)).toBe(
      true,
    );
    expect(canManageThread("removed-user", undefined, thread)).toBe(false);
    expect(canViewThread("removed-user", undefined, thread)).toBe(false);
    expect(canExecuteThread("viewer-1", memberships[2], thread)).toBe(false);

    // In a Direct Space, each participant can only manage threads they created.
    const owner = memberships[0]!;
    expect(canManageThread(owner.userId, owner, thread, "direct")).toBe(false);
    expect(canManageThread(collaborator.userId, collaborator, thread, "direct")).toBe(true);
  });

  it("requires a Primary Workspace for stateful Work Requests", () => {
    const request: WorkRequest = {
      id: "request-1",
      threadId: "thread-1",
      requestedByUserId: "collaborator-1",
      mode: "stateful",
      workflowId: "direct",
      workflowVersion: 2,
      workflowSnapshot: BUILTIN_WORKFLOWS.direct,
      status: "queued",
      primaryWorkspaceId: "workspace-1",
      input: {},
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    };
    expect(() => validateWorkRequest(request, statefulPolicy)).not.toThrow();
    expect(() =>
      validateWorkRequest(
        { ...request, primaryWorkspaceId: null },
        statefulPolicy,
      ),
    ).toThrow(/requires a Primary Workspace/);
  });

  it("enforces one active runtime lease per Thread", () => {
    const leases: ThreadExecutionLease[] = [
      {
        id: "lease-1",
        threadId: "thread-1",
        workRequestId: "request-1",
        workspaceId: "workspace-1",
        fencingToken: 1,
        status: "active",
        acquiredAt: "2026-01-01T00:00:00.000Z",
        expiresAt: "2026-01-01T01:00:00.000Z",
        releasedAt: null,
      },
    ];
    const lease = leases[0]!;
    expect(() => validateThreadLeases(thread, leases)).not.toThrow();
    expect(() =>
      validateThreadLeases(thread, [
        ...leases,
        { ...lease, id: "lease-2", fencingToken: 2 },
      ]),
    ).toThrow(/only one active execution lease/);
  });

  it("serializes and restores domain entities without persistence types", () => {
    const message: DiscussionMessage = {
      id: "message-1",
      threadId: "thread-1",
      authorUserId: "collaborator-1",
      body: "Ready for review",
      createdAt: "2026-01-01T00:00:00.000Z",
      editedAt: null,
    };
    const encoded = serializeEntity(message);
    expect(deserializeEntity<DiscussionMessage>(encoded)).toEqual(message);
    expect(() => deserializeEntity("[]")).toThrow(/must be an object/);
  });

  it("admits only canonical built-in Workflows and fixed step semantics", () => {
    expect(BUILTIN_WORKFLOW_CATALOG["direct:v1"]).toMatchObject({
      id: "direct",
      version: 1,
      name: "Direct",
      description: "Implement the requested work.",
    });
    expect(BUILTIN_WORKFLOWS.direct).toMatchObject({
      id: "direct",
      version: 2,
      name: "Work",
      description: "Implement the requested work.",
    });
    expect(BUILTIN_WORKFLOW_CATALOG["direct:v2"]).toBe(
      BUILTIN_WORKFLOWS.direct,
    );
    expect(BUILTIN_WORKFLOWS.direct.steps).toEqual(
      BUILTIN_WORKFLOW_CATALOG["direct:v1"]!.steps,
    );
    expect(BUILTIN_WORKFLOWS.direct.steps[0]).toMatchObject({
      kind: "implement",
      executionMode: "stateful_thread",
      readWritePolicy: "write_thread",
    });
    expect(() =>
      validateBuiltinWorkflowDefinition({
        ...BUILTIN_WORKFLOW_CATALOG["direct:v1"]!,
        name: "Work",
      }),
    ).toThrow(/canonical version/);
    for (const definition of Object.values(BUILTIN_WORKFLOW_CATALOG)) {
      expect(() => validateBuiltinWorkflowDefinition(definition)).not.toThrow();
      for (const step of definition.steps) {
        expect(step).toMatchObject({
          executionClass: expect.any(String),
          requiredCapabilities: expect.any(Array),
          readWritePolicy: expect.any(String),
          timeoutMs: expect.any(Number),
          promptProfileVersion: expect.any(String),
          inputsFrom: expect.any(Array),
          resultSemantics: expect.any(String),
        });
      }
    }
    expect(
      BUILTIN_WORKFLOWS.full_cycle.steps.map((step) => [
        step.kind,
        step.inputsFrom,
      ]),
    ).toEqual([
      ["research", []],
      ["plan", ["research"]],
      ["implement", ["research", "plan"]],
      ["test", ["plan", "implement"]],
      ["verify", ["research", "plan", "implement", "test"]],
    ]);
    expect(BUILTIN_WORKFLOWS.implement_verify.steps[1]?.inputsFrom).toEqual([
      "implement",
    ]);
    const custom: BuiltinWorkflowDefinition = {
      ...BUILTIN_WORKFLOWS.implement_verify,
      steps: [
        {
          ...BUILTIN_WORKFLOWS.implement_verify.steps[0]!,
          kind: "research",
        },
      ],
    };
    expect(() => validateBuiltinWorkflowDefinition(custom)).toThrow(
      /canonical version/,
    );
    const openEndedRole = {
      ...BUILTIN_WORKFLOWS.direct,
      steps: [
        {
          ...BUILTIN_WORKFLOWS.direct.steps[0]!,
          role: "senior_magic_reviewer",
        },
      ],
    } as unknown as BuiltinWorkflowDefinition;
    expect(() => validateBuiltinWorkflowDefinition(openEndedRole)).toThrow(
      /unsupported fields/,
    );
  });

  it("snapshots the selected built-in Workflow version", () => {
    const request: WorkRequest = {
      id: "request-1",
      threadId: "thread-1",
      requestedByUserId: "collaborator-1",
      mode: "stateful",
      workflowId: "direct",
      workflowVersion: 2,
      workflowSnapshot: BUILTIN_WORKFLOWS.direct,
      status: "queued",
      primaryWorkspaceId: "workspace-1",
      input: {},
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    };
    expect(() => validateWorkRequest(request, statefulPolicy)).not.toThrow();
    const historical: WorkRequest = {
      ...request,
      workflowVersion: 1,
      workflowSnapshot: BUILTIN_WORKFLOW_CATALOG["direct:v1"]!,
    };
    const stored = deserializeEntity<WorkRequest>(serializeEntity(historical));
    expect(stored.workflowSnapshot.name).toBe("Direct");
    expect(() => validateWorkRequest(stored, statefulPolicy)).not.toThrow();
  });
});

describe("step hard cap", () => {
  it("raises the declared 15 minute timeout to the 2 hour cap at dispatch", () => {
    expect(STEP_HARD_CAP_MS).toBe(8 * 60 * 60 * 1000);
    expect(effectiveStepTimeoutMs(15 * 60 * 1000)).toBe(STEP_HARD_CAP_MS);
    expect(effectiveStepTimeoutMs(STEP_HARD_CAP_MS + 1)).toBe(
      STEP_HARD_CAP_MS + 1,
    );
  });

  it("does not change the canonical built-in definitions", () => {
    for (const definition of Object.values(BUILTIN_WORKFLOWS)) {
      for (const step of definition.steps) {
        expect(step.timeoutMs).toBe(15 * 60 * 1000);
      }
    }
  });
});
