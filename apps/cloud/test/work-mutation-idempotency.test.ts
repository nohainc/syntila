import { describe, expect, it, vi } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import type { SecurityEnv } from "../src/routes/handlers.js";
vi.mock("../src/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: async () => ({
    context: { userId: "owner" },
    spaceId: "P",
  }),
  validateWorkflowWorkerEligibility: async (
    env: SecurityEnv,
    _space: string,
    _thread: string,
    _definition: unknown,
    bindings: Record<string, { workerId: string }>,
  ) => ({
    issues: [],
    primaryWorkspaceId: (await env.SYNTILA_DB.prepare(
      "SELECT workspace_id AS workspaceId FROM workspace_worker_inventory WHERE worker_id=?1",
    )
      .bind(Object.values(bindings)[0]!.workerId)
      .first<{ workspaceId: string }>())!.workspaceId,
    workerProfiles: {
      direct: { profileId: "chatgpt-codex", profileReleaseVersion: 1 },
      chat: { profileId: "chatgpt-codex", profileReleaseVersion: 1 },
    },
  }),
}));
vi.mock("../src/routes/thread-policy.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: async () => ({
    context: { userId: "owner" },
    spaceId: "P",
  }),
}));
// Applies the domain writes the route commits together with its signal.
const publish = vi.hoisted(() =>
  vi.fn(async (input?: { mutations?: { run(): Promise<unknown> }[] }) => {
    for (const statement of input?.mutations ?? []) await statement.run();
  }),
);
vi.mock("../src/event-publisher.js", () => ({
  createEventPublisher: () => ({ publish }),
}));
import { handleCreateWorkRequest } from "../src/routes/work-creation.js";
function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('owner','owner@test','Owner','now','now');
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('P','owner','Space','now','now');
    INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('member','P','owner','owner','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('W','P','Stream','active','owner','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('workspace','owner','Workspace','now','now'); INSERT INTO user_workflow_settings VALUES('owner','workspace','now');`);
  sqlite.exec(`INSERT INTO user_workflow_configurations(user_id,workspace_id,workflow_id,schema_version,configuration_json,updated_at)
    VALUES('owner','workspace','chat',1,'{"schemaVersion":1,"workflowId":"chat","enabled":true,"defaults":{"worker":"worker-a"},"stepOverrides":{}}','now'),
    ('owner','workspace','direct',1,'{"schemaVersion":1,"workflowId":"direct","enabled":true,"defaults":{"worker":"worker-a"},"stepOverrides":{}}','now');`);
  sqlite.exec(
    `INSERT INTO thread_work_configs(thread_id,config_json,updated_at) VALUES('W','{"bindings":{"direct":{"workerId":"worker-a"},"chat":{"workerId":"worker-a"}}}','now')`,
  );
  sqlite.exec(`INSERT INTO workspace_worker_inventory(worker_id,workspace_id,owner_user_id,worker_type_id,activation_state,readiness_state,local_concurrency_limit,revision,created_at,updated_at,last_seen_at)
    VALUES('worker-a','workspace','owner','chatgpt','enabled','ready',1,1,'now','now','now');`);
  sqlite.exec(
    "INSERT INTO workspace_space_grants(id,space_id,workspace_id,granted_by_user_id,status,created_at,updated_at) VALUES('grant','P','workspace','owner','active','now','now')",
  );
  const instances = new Set<string>();
  let failDispatch = false;
  const enqueue = vi.fn(async () => new Response("{}"));
  const create = vi.fn(async ({ id }: { id: string }) => {
    if (failDispatch) throw new Error("dispatch temporarily unavailable");
    if (instances.has(id)) throw new Error("instance already exists");
    instances.add(id);
    return { status: async () => ({ status: "queued" }) };
  });
  const get = vi.fn(async (id: string) => {
    if (!instances.has(id)) throw new Error("missing instance");
    return { status: async () => ({ status: "queued" }) };
  });
  const env = {
    SYNTILA_DB: db,
    SYNTILA_RUN_WORKFLOW: { create, get },
    SYNTILA_THREAD_COORDINATOR: { getByName: () => ({ fetch: enqueue }) },
  } as unknown as SecurityEnv;
  const request = (
    prompt = "Implement this",
    key = "work-operation-000000001",
    workflowId = "direct",
    executionSelection?: Record<string, unknown>,
  ) =>
    new Request("https://cloud.test/threads/W/work-requests", {
      method: "POST",
      headers: { "Idempotency-Key": key },
      body: JSON.stringify({
        workflowId,
        input: { originalRequest: prompt },
        ...(executionSelection ? { executionSelection } : {}),
      }),
    });
  const submit = (
    prompt?: string,
    key?: string,
    workflowId?: string,
    executionSelection?: Record<string, unknown>,
  ) =>
    handleCreateWorkRequest(
      request(prompt, key, workflowId, executionSelection),
      env,
      "W",
    );
  return {
    sqlite,
    db,
    env,
    instances,
    create,
    get,
    enqueue,
    submit,
    setFail: (value: boolean) => {
      failDispatch = value;
    },
  };
}
it.each(["chat", "direct"])(
  "accepts %s with one StepRun before scheduling and preserves it on replay",
  async (workflowId) => {
    const f = fixture();
    try {
      const first = await f.submit(
        "Request",
        "phase19-operation-000001",
        workflowId,
      );
      expect(first.status).toBe(202);
      const body = (await first.json()) as { workRequest: { id: string } };
      expect(publish).toHaveBeenCalledWith(
        expect.objectContaining({
          type: "work_request.created",
          payload: expect.objectContaining({
            workRequestId: body.workRequest.id,
            submissionId: "phase19-operation-000001",
          }),
        }),
      );
      const step = f.sqlite
        .prepare(
          `SELECT s.id,s.step_id,s.role,t.status FROM conversation_workflow_step_runs s
    JOIN conversation_workflow_runs r ON r.id=s.workflow_run_id JOIN workflow_tasks t ON t.id=s.task_id WHERE r.work_request_id=?`,
        )
        .all(body.workRequest.id);
      expect(step).toHaveLength(1);
      expect(step[0]).toMatchObject({
        step_id: workflowId === "chat" ? "chat" : "implement",
        role: workflowId === "chat" ? "chat" : "implement",
        status: "queued",
      });
      await f.submit("Request", "phase19-operation-000001", workflowId);
      expect(
        f.sqlite
          .prepare(
            "SELECT COUNT(*) AS count FROM conversation_workflow_step_runs",
          )
          .get()?.count,
      ).toBe(1);
    } finally {
      f.sqlite.close();
    }
  },
);

it("moves a Thread and its Space to the top when a Work Request is accepted", async () => {
  const f = fixture();
  try {
    f.sqlite.exec(
      "UPDATE spaces SET updated_at='2020-01-01T00:00:00.000Z' WHERE id='P'; UPDATE threads SET updated_at='2020-01-01T00:00:00.000Z' WHERE id='W'",
    );
    const response = await f.submit("Move this Thread up");
    expect(response.status).toBe(202);
    const timestamps = f.sqlite
      .prepare(
        `SELECT spaces.updated_at AS spaceUpdatedAt, threads.updated_at AS threadUpdatedAt
           FROM spaces JOIN threads ON threads.space_id=spaces.id
          WHERE spaces.id='P' AND threads.id='W'`,
      )
      .get() as { spaceUpdatedAt: string; threadUpdatedAt: string };
    expect(timestamps.spaceUpdatedAt).not.toBe("2020-01-01T00:00:00.000Z");
    expect(timestamps.threadUpdatedAt).not.toBe("2020-01-01T00:00:00.000Z");
    expect(timestamps.spaceUpdatedAt).toBe(timestamps.threadUpdatedAt);
  } finally {
    f.sqlite.close();
  }
});

describe("Work mutation identity through response loss", () => {
  it("rejects another Conversation scope without accepting a request", async () => {
    const f = fixture();
    await expect(
      handleCreateWorkRequest(
        new Request("https://cloud.test/threads/W/work-requests", {
          method: "POST",
          body: JSON.stringify({
            workflowId: "direct",
            conversationId: "another-conversation",
            input: { originalRequest: "Follow up" },
          }),
        }),
        f.env,
        "W",
      ),
    ).rejects.toMatchObject({ status: 400 });
    expect(
      f.sqlite.prepare("SELECT count(*) AS n FROM conversations").get(),
    ).toEqual({ n: 0 });
    expect(
      f.sqlite.prepare("SELECT count(*) AS n FROM work_requests").get(),
    ).toEqual({ n: 0 });
    f.sqlite.close();
  });
  it("continues one Thread Conversation across Chat and Work requests", async () => {
    const f = fixture();
    const work = (await (await f.submit()).json()) as {
      workRequest: { conversationId: string };
    };
    const chat = (await (
      await f.submit("Discuss", "chat-operation-000000001", "chat")
    ).json()) as typeof work;
    expect(chat.workRequest.conversationId).toBe(
      work.workRequest.conversationId,
    );
    expect(
      f.sqlite
        .prepare(
          "SELECT workflow_id, conversation_revision FROM conversations ORDER BY workflow_id",
        )
        .all(),
    ).toEqual([{ workflow_id: "work", conversation_revision: 2 }]);
    f.sqlite.close();
  });
  it("concurrent and later explicit retries create one request, Run, audit record and runtime instance", async () => {
    const f = fixture();
    const responses = await Promise.all(
      Array.from({ length: 5 }, () => f.submit()),
    );
    const values = (await Promise.all(responses.map((r) => r.json()))) as {
      workRequest: { id: string };
      run: { id: string };
    }[];
    expect(new Set(values.map((v) => v.workRequest.id)).size).toBe(1);
    expect(new Set(values.map((v) => v.run.id)).size).toBe(1);
    expect(f.instances.size).toBe(1);
    for (const table of [
      "work_requests",
      "runs",
      "space_audit_log",
      "mutation_receipts",
      "conversations",
      "conversation_work_requests",
    ]) {
      expect(
        f.sqlite.prepare(`SELECT count(*) AS n FROM ${table}`).get()?.n,
      ).toBe(1);
    }
    expect(await (await f.submit()).json()).toEqual(values[0]);
    expect(f.instances.size).toBe(1);
    expect(
      f.sqlite
        .prepare(
          "SELECT conversation_revision, context_revision FROM conversations",
        )
        .get(),
    ).toEqual({ conversation_revision: 1, context_revision: 1 });
    await expect(f.submit("Different prompt")).rejects.toMatchObject({
      status: 409,
    });
    f.sqlite.close();
  });
  it("keeps a Work Conversation across new requests and selection changes", async () => {
    const f = fixture();
    const first = (await (await f.submit()).json()) as {
      workRequest: { id: string; conversationId: string };
    };
    f.sqlite.exec(
      `UPDATE thread_work_configs SET config_json = '{"bindings":{"direct":{"workerId":"another-worker","model":"another-model","reasoningEffort":"high"}}}' WHERE thread_id = 'W'`,
    );
    const second = (await (
      await f.submit("Follow up", "work-operation-000000002")
    ).json()) as typeof first;
    expect(second.workRequest.id).not.toBe(first.workRequest.id);
    expect(second.workRequest.conversationId).toBe(
      first.workRequest.conversationId,
    );
    expect(
      f.sqlite
        .prepare(
          "SELECT workflow_id, workflow_version, conversation_revision, context_revision FROM conversations",
        )
        .get(),
    ).toEqual({
      workflow_id: "work",
      workflow_version: 1,
      conversation_revision: 2,
      context_revision: 2,
    });
    expect(
      f.sqlite
        .prepare(
          "SELECT conversation_revision FROM conversation_work_requests ORDER BY conversation_revision",
        )
        .all(),
    ).toEqual([{ conversation_revision: 1 }, { conversation_revision: 2 }]);
    const snapshot = f.sqlite
      .prepare("SELECT snapshot_json FROM work_requests WHERE id = ?")
      .get(first.workRequest.id)!;
    expect(
      JSON.parse(String(snapshot.snapshot_json)).resolvedBindings.direct,
    ).toEqual({ workerId: "worker-a" });
    f.sqlite.close();
  });
  it("a retry resumes interrupted dispatch with the same committed identities", async () => {
    const f = fixture();
    f.setFail(true);
    await expect(f.submit()).rejects.toThrow(
      "dispatch temporarily unavailable",
    );
    const before = f.sqlite.prepare("SELECT id FROM work_requests").get()?.id;
    expect(f.instances.size).toBe(0);
    f.setFail(false);
    const accepted = (await (await f.submit()).json()) as {
      workRequest: { id: string };
    };
    expect(accepted.workRequest.id).toBe(before);
    expect(f.instances.size).toBe(1);
    expect(f.sqlite.prepare("SELECT count(*) AS n FROM runs").get()?.n).toBe(1);
    f.sqlite.close();
  });
  it("replaying a cancelled/finished request never starts execution again", async () => {
    const f = fixture();
    await f.submit();
    f.sqlite.exec("UPDATE work_requests SET status='cancelled'");
    f.create.mockClear();
    f.enqueue.mockClear();
    expect((await f.submit()).status).toBe(202);
    expect(f.create).not.toHaveBeenCalled();
    expect(f.enqueue).not.toHaveBeenCalled();
    f.sqlite.close();
  });
});

it("global workflow choices beat stale Thread values and freeze Profile and step history", async () => {
  const f = fixture();
  try {
    f.sqlite.exec(
      `INSERT INTO workspace_worker_inventory(worker_id,workspace_id,owner_user_id,worker_type_id,activation_state,readiness_state,local_concurrency_limit,revision,created_at,updated_at,last_seen_at) VALUES('global-worker','workspace','owner','chatgpt','enabled','ready',1,1,'now','now','now')`,
    );
    const preference = {
      schemaVersion: 1,
      workflowId: "direct",
      enabled: true,
      defaults: {
        worker: "global-worker",
        model: "global-model",
        effort: "high",
      },
      stepOverrides: { implement: { effort: "low" } },
    };
    f.sqlite
      .prepare(
        "UPDATE user_workflow_configurations SET configuration_json=? WHERE user_id='owner' AND workflow_id='direct'",
      )
      .run(JSON.stringify(preference));
    await handleCreateWorkRequest(
      new Request("https://cloud.test/threads/W/work-requests", {
        method: "POST",
        headers: { "Idempotency-Key": "global-preferences-00001" },
        body: JSON.stringify({
          workflowId: "direct",
          input: { originalRequest: "Global" },
        }),
      }),
      f.env,
      "W",
    );
    const read = () =>
      JSON.parse(
        String(
          f.sqlite.prepare("SELECT snapshot_json FROM work_requests").get()!
            .snapshot_json,
        ),
      );
    const before = read();
    expect(before.resolvedBindings.direct).toEqual({
      workerId: "global-worker",
      model: "global-model",
      reasoningEffort: "low",
    });
    expect(before.stepExecutionConfigs.implement).toMatchObject({
      workerId: "global-worker",
      profileId: "chatgpt-codex",
      profileReleaseVersion: 1,
      modelId: "global-model",
      effort: "low",
    });
    const { loadConversationWorkflowRuns } =
      await import("../src/routes/conversation-workflow-runs.js");
    const id = String(
      f.sqlite.prepare("SELECT id FROM work_requests").get()!.id,
    );
    const history = (await loadConversationWorkflowRuns(f.db, [id])).get(id)!;
    expect(history.executionConfigs?.implement).toEqual(
      before.stepExecutionConfigs.implement,
    );
    expect(history.stepRuns[0]!.executionConfig).toEqual(
      before.stepExecutionConfigs.implement,
    );
    expect(history.stepRuns[0]!.profileReleaseVersion).toBe(1);
    f.sqlite.exec(
      "UPDATE workspace_worker_inventory SET profile_definition_id='future-profile',profile_release_version=99 WHERE worker_id='global-worker'",
    );
    const { identityService } = await import("../src/auth/identity-service.js");
    const identity = vi.spyOn(identityService, "resolve").mockResolvedValue({
      userId: "owner",
      email: "owner@test",
      name: "Owner",
      sessionId: "test-session",
    });
    f.env.BETTER_AUTH_SECRET = "test-secret";
    const { handleGetWorkRequest, handleListWorkRequests } =
      await import("../src/routes/work-lifecycle.js");
    const detail = (await (
      await handleGetWorkRequest(
        new Request("https://cloud.test/work"),
        f.env,
        id,
      )
    ).json()) as {
      steps: { profileDefinitionId: string; profileReleaseVersion: number }[];
    };
    const list = (await (
      await handleListWorkRequests(
        new Request("https://cloud.test/work"),
        f.env,
        "W",
      )
    ).json()) as {
      workRequests: {
        steps: { profileDefinitionId: string; profileReleaseVersion: number }[];
      }[];
    };
    for (const step of [detail.steps[0]!, list.workRequests[0]!.steps[0]!]) {
      expect(step.profileDefinitionId).toBe("chatgpt-codex");
      expect(step.profileReleaseVersion).toBe(1);
    }
    identity.mockRestore();
    f.sqlite.exec("DELETE FROM user_workflow_configurations");
    expect(read()).toEqual(before);
    expect((await loadConversationWorkflowRuns(f.db, [id])).get(id)).toEqual(
      history,
    );
  } finally {
    f.sqlite.close();
  }
});
it("disabled user workflow cannot create execution even with a composer selection", async () => {
  const f = fixture();
  try {
    f.sqlite
      .prepare(
        "UPDATE user_workflow_configurations SET configuration_json=? WHERE user_id='owner' AND workflow_id='direct'",
      )
      .run(
        JSON.stringify({
          schemaVersion: 1,
          workflowId: "direct",
          enabled: false,
          defaults: {},
          stepOverrides: {},
        }),
      );
    await expect(f.submit()).rejects.toMatchObject({ status: 403 });
    expect(
      f.sqlite.prepare("SELECT count(*) n FROM work_requests").get()!.n,
    ).toBe(0);
  } finally {
    f.sqlite.close();
  }
});

it("accepts one-step composer overrides without changing saved preferences", async () => {
  const f = fixture();
  try {
    const response = await handleCreateWorkRequest(
      new Request("https://cloud.test/work", {
        method: "POST",
        headers: { "Idempotency-Key": "composer-selection-000001" },
        body: JSON.stringify({
          workflowId: "direct",
          input: { originalRequest: "Request" },
          executionSelection: { workerId: "worker-a" },
        }),
      }),
      f.env,
      "W",
    );
    expect(response.status).toBe(202);
    expect(
      f.sqlite.prepare("SELECT snapshot_json FROM work_requests").get()!
        .snapshot_json,
    ).toEqual(expect.stringContaining('"workerId":"worker-a"'));
    expect(
      f.sqlite
        .prepare(
          "SELECT configuration_json FROM user_workflow_configurations WHERE user_id='owner' AND workflow_id='direct'",
        )
        .get(),
    ).toEqual(
      expect.objectContaining({
        configuration_json: expect.stringContaining('"worker":"worker-a"'),
      }),
    );
  } finally {
    f.sqlite.close();
  }
});

it("Workspace changes use the new Workspace for every Thread request while preserving earlier Run and Step snapshots", async () => {
  const f = fixture();
  try {
    const first = await f.submit("Before switch", "workspace-before-00001");
    const id = ((await first.json()) as { workRequest: { id: string } })
      .workRequest.id;
    const { loadConversationWorkflowRuns } =
      await import("../src/routes/conversation-workflow-runs.js");
    const before = (await loadConversationWorkflowRuns(f.db, [id])).get(id);
    f.sqlite
      .exec(`INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('new-workspace','owner','New Workspace','now','now');
      INSERT INTO workspace_worker_inventory(worker_id,workspace_id,owner_user_id,worker_type_id,activation_state,readiness_state,local_concurrency_limit,revision,created_at,updated_at,last_seen_at) VALUES('new-worker','new-workspace','owner','chatgpt','enabled','ready',1,1,'now','now','now');
      INSERT INTO workspace_space_grants(id,space_id,workspace_id,granted_by_user_id,status,created_at,updated_at) VALUES('new-grant','P','new-workspace','owner','active','now','now');
      INSERT INTO space_workflow_settings VALUES('P','new-workspace','now');`);
    const second = await f.submit(
      "After switch",
      "workspace-after-000001",
      "direct",
      { workerId: "new-worker" },
    );
    expect(second.status).toBe(202);
    const nextId = ((await second.json()) as { workRequest: { id: string } })
      .workRequest.id;
    const snapshot = JSON.parse(
      String(
        f.sqlite
          .prepare("SELECT snapshot_json FROM work_requests WHERE id=?")
          .get(nextId)!.snapshot_json,
      ),
    );
    expect(snapshot.resolvedBindings.direct.workerId).toBe("new-worker");
    const next = (await loadConversationWorkflowRuns(f.db, [nextId])).get(
      nextId,
    )!;
    expect(next.executionConfigs?.implement?.workerId).toBe("new-worker");
    expect(next.stepRuns[0]!.executionConfig?.workerId).toBe("new-worker");
    expect((await loadConversationWorkflowRuns(f.db, [id])).get(id)).toEqual(
      before,
    );
  } finally {
    f.sqlite.close();
  }
});

describe("Research plan admission", () => {
  it("denies a Free requester before any request, run or execution exists", async () => {
    const f = fixture();
    try {
      publish.mockClear();
      await expect(
        f.submit("Investigate", "research-free-000000001", "research"),
      ).rejects.toMatchObject({
        status: 402,
        code: "paid_plan_required",
        feature: "workflow.research",
      });
      for (const table of [
        "work_requests",
        "runs",
        "workflow_tasks",
        "worker_assignments",
      ])
        expect(
          f.sqlite.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get(),
        ).toEqual({ n: 0 });
      expect(f.create).not.toHaveBeenCalled();
      expect(publish).not.toHaveBeenCalled();
    } finally {
      f.sqlite.close();
    }
  });

  it("does not gate Chat, Work or workflows that only contain a research step", async () => {
    const f = fixture();
    try {
      expect(
        (await f.submit("Hi", "research-chat-00000001", "chat")).status,
      ).toBe(202);
      expect(
        (await f.submit("Do", "research-work-00000001", "direct")).status,
      ).toBe(202);
      const fullCycle = await f
        .submit("All", "research-full-00000001", "full_cycle")
        .then((r) => r.status)
        .catch((e: { status?: number; code?: string }) => e.code ?? e.status);
      expect(fullCycle).not.toBe("paid_plan_required");
    } finally {
      f.sqlite.close();
    }
  });

  it("requires the current plan for a user-triggered retry of a Research request", async () => {
    const f = fixture();
    try {
      f.sqlite
        .exec(`INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
        VALUES('R','W','owner','stateless','research',1,'{}','failed','{"originalRequest":"x"}','now','now')`);
      const { handleRetryWorkRequest } =
        await import("../src/routes/work-lifecycle.js");
      const retry = () =>
        handleRetryWorkRequest(
          new Request("https://cloud.test/work-requests/R/retry", {
            method: "POST",
            body: JSON.stringify({ stepKind: "research" }),
          }),
          f.env,
          "R",
        );
      await expect(retry()).rejects.toMatchObject({
        status: 402,
        feature: "workflow.research",
      });
      // Upgrading enables it again with no other change; the retry then
      // proceeds to the existing retry rules (here: no failed Step row).
      f.sqlite.exec(
        "INSERT INTO account_plans(user_id,tier,status,source,created_at,updated_at) VALUES('owner','paid','active','manual','now','now')",
      );
      await expect(retry()).rejects.not.toMatchObject({
        code: "paid_plan_required",
      });
    } finally {
      f.sqlite.close();
    }
  });
});
