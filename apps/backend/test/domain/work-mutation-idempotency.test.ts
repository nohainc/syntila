import { describe, expect, it, vi } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import type { SecurityEnv } from "../../src/domain/routes/handlers.js";
vi.mock("../../src/domain/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: async () => ({
    context: { userId: "owner" },
    spaceId: "P",
  }),
}));
vi.mock("../../src/domain/routes/thread-policy.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: async () => ({
    context: { userId: "owner" },
    spaceId: "P",
  }),
}));
// Applies the domain writes the route commits together with its signal.
const publish = vi.hoisted(() => vi.fn(async (_input?: unknown) => {}));
vi.mock("../../src/domain/event-publisher.js", () => ({
  createEventPublisher: (env: unknown) => ({
    publish: async (input?: { mutate?: (tx: never) => Promise<unknown> }) => {
      await publish(input);
      if (input?.mutate) {
        const { dataOf } = await import("../../src/platform/data.js");
        await dataOf(env as never).tx("test.publish", (tx) => input.mutate!(tx as never));
      }
    },
  }),
}));
import { handleCreateWorkRequest } from "../../src/domain/routes/work-creation.js";
async function fixture() {
  const { sqlite, db } = await pgD1();
  await sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('owner','owner@test','Owner','now','now');
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('P','owner','Space','now','now');
    INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('member','P','owner','owner','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('W','P','Stream','active','owner','now','now');
    INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES('worker-a','','owner','chatgpt','Worker A');
    INSERT INTO worker_credentials(id,worker_instance_id,public_key,key_fingerprint) VALUES('cred-a','worker-a','${"a".repeat(43)}','${"a".repeat(64)}');
    INSERT INTO worker_agent_sessions(worker_instance_id,session_id,session_epoch,credential_id,token_digest,lease_expires_at,device_id) VALUES('worker-a','sess-a',1,'cred-a','digest-a',now() + interval '5 minutes','dev-1');
    INSERT INTO worker_profiles(worker_type_id,schema_version,profile_json,revision,digest,updated_at) VALUES('chatgpt',1,'{"schemaVersion":1,"profileDefinitionId":"chatgpt-codex"}',1,'${"a".repeat(64)}',now()) ON CONFLICT (worker_type_id) DO NOTHING;
    INSERT INTO device_folders(owner_user_id,device_id,folder_id,device_name,display_name,mode) VALUES('owner','dev-1','fld-1','Mac','Repo','write');
    INSERT INTO space_folders(space_id,owner_user_id,device_id,folder_id) VALUES('P','owner','dev-1','fld-1');`);
  await sqlite.exec(`INSERT INTO user_worker_workflow_configurations(user_id,workflow_id,schema_version,configuration_json,updated_at)
    VALUES('owner','chat',1,'{"schemaVersion":1,"workflowId":"chat","enabled":true,"defaults":{"worker":"worker-a"},"stepOverrides":{}}','now'),
    ('owner','direct',1,'{"schemaVersion":1,"workflowId":"direct","enabled":true,"defaults":{"worker":"worker-a"},"stepOverrides":{}}','now');`);
  await sqlite.exec(
    `INSERT INTO thread_work_configs(thread_id,config_json,updated_at) VALUES('W','{"bindings":{"direct":{"workerId":"worker-a"},"chat":{"workerId":"worker-a"}}}','now')`,
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
    extra?: Record<string, unknown>,
  ) =>
    new Request("https://cloud.test/threads/W/work-requests", {
      method: "POST",
      headers: { "Idempotency-Key": key },
      body: JSON.stringify({
        workflowId,
        workerId: "worker-a",
        input: { originalRequest: prompt },
        ...(extra ?? {}),
      }),
    });
  const submit = (
    prompt?: string,
    key?: string,
    workflowId?: string,
    extra?: Record<string, unknown>,
  ) =>
    handleCreateWorkRequest(
      request(prompt, key, workflowId, extra),
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
    const f = await fixture();
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
      const step = await f.sqlite
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
        (await f.sqlite
          .prepare(
            "SELECT COUNT(*) AS count FROM conversation_workflow_step_runs",
          )
          .get())?.count,
      ).toBe(1);
    } finally {
      await f.sqlite.close();
    }
  },
);

it("moves a Thread and its Space to the top when a Work Request is accepted", async () => {
  const f = await fixture();
  try {
    await f.sqlite.exec(
      "UPDATE spaces SET updated_at='2020-01-01T00:00:00.000Z' WHERE id='P'; UPDATE threads SET updated_at='2020-01-01T00:00:00.000Z' WHERE id='W'",
    );
    const response = await f.submit("Move this Thread up");
    expect(response.status).toBe(202);
    const timestamps = await f.sqlite
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
    await f.sqlite.close();
  }
});

describe("Work mutation identity through response loss", () => {
  it("rejects another Conversation scope without accepting a request", async () => {
    const f = await fixture();
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
      await f.sqlite.prepare("SELECT count(*) AS n FROM conversations").get(),
    ).toEqual({ n: 0 });
    expect(
      await f.sqlite.prepare("SELECT count(*) AS n FROM work_requests").get(),
    ).toEqual({ n: 0 });
    await f.sqlite.close();
  });
  it("continues one Thread Conversation across Chat and Work requests", async () => {
    const f = await fixture();
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
      await f.sqlite
        .prepare(
          "SELECT workflow_id, conversation_revision FROM conversations ORDER BY workflow_id",
        )
        .all(),
    ).toEqual([{ workflow_id: "work", conversation_revision: 2 }]);
    await f.sqlite.close();
  });
  it("concurrent and later explicit retries create one request, Run, audit record and runtime instance", async () => {
    const f = await fixture();
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
        (await f.sqlite.prepare(`SELECT count(*) AS n FROM ${table}`).get())?.n,
      ).toBe(1);
    }
    expect(await (await f.submit()).json()).toEqual(values[0]);
    expect(f.instances.size).toBe(1);
    expect(
      await f.sqlite
        .prepare(
          "SELECT conversation_revision, context_revision FROM conversations",
        )
        .get(),
    ).toEqual({ conversation_revision: 1, context_revision: 1 });
    await expect(f.submit("Different prompt")).rejects.toMatchObject({
      status: 409,
    });
    await f.sqlite.close();
  });
  it("keeps a Work Conversation across new requests and selection changes", async () => {
    const f = await fixture();
    const first = (await (await f.submit()).json()) as {
      workRequest: { id: string; conversationId: string };
    };
    await f.sqlite.exec(
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
      await f.sqlite
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
      await f.sqlite
        .prepare(
          "SELECT conversation_revision FROM conversation_work_requests ORDER BY conversation_revision",
        )
        .all(),
    ).toEqual([{ conversation_revision: 1 }, { conversation_revision: 2 }]);
    const snapshot = (await f.sqlite
      .prepare("SELECT snapshot_json FROM work_requests WHERE id = ?")
      .get(first.workRequest.id))!;
    expect(
      JSON.parse(String(snapshot.snapshot_json)).resolvedBindings.direct,
    ).toMatchObject({ workerId: "worker-a" });
    await f.sqlite.close();
  });
  it("a retry resumes interrupted dispatch with the same committed identities", async () => {
    const f = await fixture();
    f.setFail(true);
    await expect(f.submit()).rejects.toThrow(
      "dispatch temporarily unavailable",
    );
    const before = (await f.sqlite.prepare("SELECT id FROM work_requests").get())?.id;
    expect(f.instances.size).toBe(0);
    f.setFail(false);
    const accepted = (await (await f.submit()).json()) as {
      workRequest: { id: string };
    };
    expect(accepted.workRequest.id).toBe(before);
    expect(f.instances.size).toBe(1);
    expect((await f.sqlite.prepare("SELECT count(*) AS n FROM runs").get())?.n).toBe(1);
    await f.sqlite.close();
  });
  it("replaying a cancelled/finished request never starts execution again", async () => {
    const f = await fixture();
    await f.submit();
    await f.sqlite.exec("UPDATE work_requests SET status='cancelled'");
    f.create.mockClear();
    f.enqueue.mockClear();
    expect((await f.submit()).status).toBe(202);
    expect(f.create).not.toHaveBeenCalled();
    expect(f.enqueue).not.toHaveBeenCalled();
    await f.sqlite.close();
  });
});

it("global workflow choices beat stale Thread values and freeze Profile and step history", async () => {
  const f = await fixture();
  try {
    await f.sqlite.exec(
      `INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES('global-worker','','owner','chatgpt','Global Worker');
       INSERT INTO worker_credentials(id,worker_instance_id,public_key,key_fingerprint) VALUES('cred-g','global-worker','${"b".repeat(43)}','${"b".repeat(64)}');
       INSERT INTO worker_agent_sessions(worker_instance_id,session_id,session_epoch,credential_id,token_digest,lease_expires_at,device_id) VALUES('global-worker','sess-g',1,'cred-g','digest-g',now() + interval '5 minutes','dev-1');`,
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
    await f.sqlite
      .prepare(
        "UPDATE user_worker_workflow_configurations SET configuration_json=? WHERE user_id='owner' AND workflow_id='direct'",
      )
      .run(JSON.stringify(preference));
    await handleCreateWorkRequest(
      new Request("https://cloud.test/threads/W/work-requests", {
        method: "POST",
        headers: { "Idempotency-Key": "global-preferences-00001" },
        body: JSON.stringify({
          workflowId: "direct",
          workerId: "global-worker",
          model: "global-model",
          reasoningEffort: "low",
          input: { originalRequest: "Global" },
        }),
      }),
      f.env,
      "W",
    );
    const read = async () =>
      JSON.parse(
        String(
          (await f.sqlite.prepare("SELECT snapshot_json FROM work_requests").get())!
            .snapshot_json,
        ),
      );
    const before = await read();
    expect(before.resolvedBindings.direct).toMatchObject({
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
      await import("../../src/domain/routes/conversation-workflow-runs.js");
    const id = String(
      (await f.sqlite.prepare("SELECT id FROM work_requests").get())!.id,
    );
    const history = (await loadConversationWorkflowRuns(f.db, [id])).get(id)!;
    expect(history.executionConfigs?.implement).toEqual(
      before.stepExecutionConfigs.implement,
    );
    expect(history.stepRuns[0]!.executionConfig).toEqual(
      before.stepExecutionConfigs.implement,
    );
    expect(history.stepRuns[0]!.profileReleaseVersion).toBe(1);
    await f.sqlite.exec(
      `UPDATE worker_profiles SET profile_json='{"schemaVersion":1,"profileDefinitionId":"future-profile"}',revision=99 WHERE worker_type_id='chatgpt'`,
    );
    const { identityService } = await import("../../src/domain/auth/identity-service.js");
    const identity = vi.spyOn(identityService, "resolve").mockResolvedValue({
      userId: "owner",
      email: "owner@test",
      name: "Owner",
      sessionId: "test-session",
    });
    f.env.BETTER_AUTH_SECRET = "test-secret";
    const { handleGetWorkRequest, handleListWorkRequests } =
      await import("../../src/domain/routes/work-lifecycle.js");
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
    await f.sqlite.exec("DELETE FROM user_worker_workflow_configurations");
    expect(await read()).toEqual(before);
    expect((await loadConversationWorkflowRuns(f.db, [id])).get(id)).toEqual(
      history,
    );
  } finally {
    await f.sqlite.close();
  }
});
it("disabled user workflow cannot create execution even with a composer selection", async () => {
  const f = await fixture();
  try {
    await f.sqlite
      .prepare(
        "UPDATE user_worker_workflow_configurations SET configuration_json=? WHERE user_id='owner' AND workflow_id='direct'",
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
    await expect(f.submit()).rejects.toThrow("Workflow is disabled in this Space");
    expect(
      (await f.sqlite.prepare("SELECT count(*) n FROM work_requests").get())!.n,
    ).toBe(0);
  } finally {
    await f.sqlite.close();
  }
});

it("accepts Research v2 through request creation with every role frozen in the snapshot", async () => {
  const f = await fixture();
  try {
    await f.sqlite.exec(
      "INSERT INTO account_plans(user_id,tier,status,source,created_at,updated_at) VALUES('owner','paid','active','manual','now','now')",
    );
    await f.sqlite
      .prepare(
        "INSERT INTO user_worker_workflow_configurations(user_id,workflow_id,schema_version,configuration_json,updated_at) VALUES('owner','research',1,?,'now')",
      )
      .run(
        JSON.stringify({
          schemaVersion: 2,
          workflowId: "research",
          enabled: true,
          researcherCount: 2,
          defaults: { worker: "worker-a", model: "model-a" },
          stepOverrides: { "research-2": { model: "model-b" } },
        }),
      );
    const response = await f.submit(
      "Investigate",
      "research-request-create-0001",
      "research",
      {
        researcherCount: 2,
        workerId: "worker-a",
        model: "model-a",
        workerBindings: {
          "research-2": { workerId: "worker-a", model: "model-b" },
        },
      },
    );
    expect(response.status).toBe(202);
    const row = (await f.sqlite
      .prepare("SELECT snapshot_json AS snapshot FROM work_requests")
      .get())!;
    const snapshot = JSON.parse(String(row.snapshot));
    expect(Object.keys(snapshot.resolvedBindings)).toEqual([
      "research-1",
      "research-2",
      "synthesis",
    ]);
    expect(snapshot.resolvedBindings["research-2"].model).toBe("model-b");
    expect(Object.keys(snapshot.stepExecutionConfigs)).toEqual([
      "research-1",
      "research-2",
      "synthesis",
    ]);
    expect(snapshot.workflowSnapshot.steps).toHaveLength(3);
    const conversation = await f.sqlite
      .prepare(
        `SELECT cr.conversation_id AS conversationId, cr.conversation_revision AS revision,
        r.workflow_id AS workflowId, COUNT(s.id) AS stepCount
        FROM conversation_work_requests cr JOIN conversation_workflow_runs r ON r.work_request_id=cr.work_request_id
        JOIN conversation_workflow_step_runs s ON s.workflow_run_id=r.id
        WHERE cr.work_request_id=(SELECT id FROM work_requests LIMIT 1) GROUP BY cr.work_request_id, cr.conversation_id, cr.conversation_revision, r.workflow_id`,
      )
      .get();
    expect(conversation).toMatchObject({
      revision: 1,
      workflowId: "research",
      stepCount: 3,
    });
  } finally {
    await f.sqlite.close();
  }
});

it("accepts one-step composer overrides without changing saved preferences", async () => {
  const f = await fixture();
  try {
    const response = await handleCreateWorkRequest(
      new Request("https://cloud.test/work", {
        method: "POST",
        headers: { "Idempotency-Key": "composer-selection-000001" },
        body: JSON.stringify({
          workflowId: "direct",
          workerId: "worker-a",
          input: { originalRequest: "Request" },
        }),
      }),
      f.env,
      "W",
    );
    expect(response.status).toBe(202);
    expect(
      (await f.sqlite.prepare("SELECT snapshot_json FROM work_requests").get())!
        .snapshot_json,
    ).toEqual(expect.stringContaining('"workerId":"worker-a"'));
    expect(
      await f.sqlite
        .prepare(
          "SELECT configuration_json FROM user_worker_workflow_configurations WHERE user_id='owner' AND workflow_id='direct'",
        )
        .get(),
    ).toEqual(
      expect.objectContaining({
        configuration_json: expect.stringContaining('"worker":"worker-a"'),
      }),
    );
  } finally {
    await f.sqlite.close();
  }
});

it("Worker selection changes apply to new Thread requests while preserving earlier Run and Step snapshots", async () => {
  const f = await fixture();
  try {
    const first = await f.submit("Before switch", "workspace-before-00001");
    const id = ((await first.json()) as { workRequest: { id: string } })
      .workRequest.id;
    const { loadConversationWorkflowRuns } =
      await import("../../src/domain/routes/conversation-workflow-runs.js");
    const before = (await loadConversationWorkflowRuns(f.db, [id])).get(id);
    await f.sqlite.exec(`
      INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES('new-worker','','owner','chatgpt','New Worker');
      INSERT INTO worker_credentials(id,worker_instance_id,public_key,key_fingerprint) VALUES('cred-n','new-worker','${"c".repeat(43)}','${"c".repeat(64)}');
      INSERT INTO worker_agent_sessions(worker_instance_id,session_id,session_epoch,credential_id,token_digest,lease_expires_at,device_id) VALUES('new-worker','sess-n',1,'cred-n','digest-n',now() + interval '5 minutes','dev-1');
    `);
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
        (await f.sqlite
          .prepare("SELECT snapshot_json FROM work_requests WHERE id=?")
          .get(nextId))!.snapshot_json,
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
    await f.sqlite.close();
  }
});

describe("Research plan admission", () => {
  it("denies a Free requester before any request, run or execution exists", async () => {
    const f = await fixture();
    try {
      publish.mockClear();
      await expect(f.submit("Investigate", "research-free-000000001", "research"),).rejects.toMatchObject({
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
          await f.sqlite.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get(),
        ).toEqual({ n: 0 });
      expect(f.create).not.toHaveBeenCalled();
      expect(publish).not.toHaveBeenCalled();
    } finally {
      await f.sqlite.close();
    }
  });

  it("gates Implement for a Free requester but not Chat or Work", async () => {
    const f = await fixture();
    try {
      expect(
        (await f.submit("Hi", "research-chat-00000001", "chat")).status,
      ).toBe(202);
      expect(
        (await f.submit("Do", "research-work-00000001", "direct")).status,
      ).toBe(202);
      await expect(f.submit("All", "research-plan-00000001", "plan_implement"),).rejects.toMatchObject({
        status: 402,
        code: "paid_plan_required",
        feature: "workflow.implement",
      });
    } finally {
      await f.sqlite.close();
    }
  });

  it("requires the current plan for a user-triggered retry of a Research request", async () => {
    const f = await fixture();
    try {
      await f.sqlite
        .exec(`INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
        VALUES('R','W','owner','stateless','research',1,'{}','failed','{"originalRequest":"x"}','now','now')`);
      const { handleRetryWorkRequest } =
        await import("../../src/domain/routes/work-lifecycle.js");
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
      (await f.sqlite.exec(
        "INSERT INTO account_plans(user_id,tier,status,source,created_at,updated_at) VALUES('owner','paid','active','manual','now','now')",
      ));
      await expect(retry()).rejects.not.toMatchObject({
        code: "paid_plan_required",
      });
    } finally {
      await f.sqlite.close();
    }
  });

  it("offers and validates a user-requested partial synthesis of a failed Research request", async () => {
    const f = await fixture();
    try {
      await f.sqlite.exec(
        "INSERT INTO account_plans(user_id,tier,status,source,created_at,updated_at) VALUES('owner','paid','active','manual','now','now')",
      );
      const workflowSnapshot = JSON.stringify({
        steps: [
          { kind: "research", id: "research-1" },
          { kind: "research", id: "research-2" },
          { kind: "synthesis", id: "synthesis" },
        ],
      });
      await f.sqlite
        .prepare(
          `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
        VALUES('R','W','owner','stateless','research',2,?,'failed','{"originalRequest":"x"}','now','now')`,
        )
        .run(workflowSnapshot);
      const task = (id: string, kind: string, status: string) =>
        f.sqlite
          .prepare(
            `INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,attempt,created_at,updated_at,step_instance_id)
             VALUES(?, 'R', ?, 'stateless_read', 1000, 'v', ?, 1, 'now', 'now', ?)`,
          )
          .run(`t-${id}`, kind, status, id);
      await task("research-1", "research", "completed");
      await task("research-2", "research", "failed");
      await task("synthesis", "synthesis", "queued");
      const { handleRetryWorkRequest } =
        await import("../../src/domain/routes/work-lifecycle.js");
      const retry = (body: object) =>
        handleRetryWorkRequest(
          new Request("https://cloud.test/work-requests/R/retry", {
            method: "POST",
            body: JSON.stringify(body),
          }),
          f.env,
          "R",
        );
      // Continuing without any successful report is not allowed.
      (await f.sqlite
        .prepare(
          "UPDATE workflow_tasks SET status = 'failed' WHERE id = 't-research-1'",
        )
        .run());
      await expect(retry({ stepKind: "synthesis", stepId: "synthesis", partial: true }),).rejects.toMatchObject({ status: 409 });
      // Only the synthesis can be partial.
      await expect(retry({ stepKind: "research", stepId: "research-2", partial: true }),).rejects.toMatchObject({ status: 400 });
    } finally {
      await f.sqlite.close();
    }
  });
});

describe("Research gap read model", () => {
  const steps = (
    first: string,
    second: string,
    third: string,
    synthesis: string,
  ) => [
    { kind: "research", stepId: "research-1", status: first },
    { kind: "research", stepId: "research-2", status: second },
    { kind: "research", stepId: "research-3", status: third },
    { kind: "synthesis", stepId: "synthesis", status: synthesis },
  ];
  const row = (status: string) => ({
    workflowId: "research",
    workflowVersion: 2,
    status,
  });

  it("offers a partial synthesis only with enough reports and a failure", async () => {
    const { researchGapFields } =
      await import("../../src/domain/routes/work-lifecycle.js");
    expect(
      researchGapFields(
        row("failed"),
        steps("completed", "completed", "failed", "queued"),
      ),
    ).toMatchObject({
      partialSynthesisAvailable: true,
      completedWithGaps: false,
      researchReports: { succeeded: 2, failed: 1, total: 3 },
    });
    // One report is enough to continue with a clearly identified gap.
    expect(
      researchGapFields(
        row("failed"),
        steps("completed", "failed", "failed", "queued"),
      ),
    ).toMatchObject({ partialSynthesisAvailable: true });
    expect(
      researchGapFields(
        row("failed"),
        steps("failed", "failed", "failed", "queued"),
      ),
    ).toMatchObject({ partialSynthesisAvailable: false });
    // Cancelled or running requests never offer it.
    expect(
      researchGapFields(
        row("cancelled"),
        steps("completed", "completed", "failed", "queued"),
      ),
    ).toMatchObject({ partialSynthesisAvailable: false });
  });

  it("marks a synthesis that ran over fewer reports as completed with gaps", async () => {
    const { researchGapFields } =
      await import("../../src/domain/routes/work-lifecycle.js");
    expect(
      researchGapFields(
        row("completed"),
        steps("completed", "completed", "failed", "completed"),
      ),
    ).toMatchObject({
      completedWithGaps: true,
      partialSynthesisAvailable: false,
    });
    expect(
      researchGapFields(
        row("completed"),
        steps("completed", "completed", "completed", "completed"),
      ),
    ).toMatchObject({ completedWithGaps: false });
    // Other workflows carry no Research fields.
    expect(
      researchGapFields(
        { workflowId: "direct", workflowVersion: 2, status: "completed" },
        [],
      ),
    ).toEqual({});
  });
});

describe("tool call admission", () => {
  const toolCall = () => ({
    serverId: "files",
    tool: "read",
    toolDefinitionHash: "a".repeat(64),
    arguments: { path: "a.txt" },
  });
  const post = (
    f: Awaited<ReturnType<typeof fixture>>,
    key: string,
    body: Record<string, unknown>,
  ) =>
    handleCreateWorkRequest(
      new Request("https://cloud.test/threads/W/work-requests", {
        method: "POST",
        headers: { "Idempotency-Key": key },
        body: JSON.stringify(body),
      }),
      f.env,
      "W",
    );

  it("refuses input.toolCall cleanly as not yet available", async () => {
    const f = await fixture();
    await expect(post(f, "toolcall-operation-00001", {
      workflowId: "chat",
      input: { originalRequest: "Read it", toolCall: toolCall() },
    })).rejects.toMatchObject({ status: 400, message: "Tool calls are not available yet" });
    await expect(post(f, "toolcall-operation-00003", {
      workflowId: "direct",
      input: { originalRequest: "x", toolCall: toolCall() },
    })).rejects.toMatchObject({ status: 400, message: "Tool calls are not available yet" });
  });
});
