import { afterEach, describe, expect, it, vi } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import {
  parseImplementationPhases,
  handleApprovePlan,
  evaluatePhaseCompletionAndAdvanceQueue,
} from "../../src/domain/routes/implement-plan.js";
import { handleThreadRequestQueue } from "../../src/domain/routes/thread-request-queue.js";
import type { SecurityEnv } from "../../src/domain/routes/http-security.js";

vi.mock("../../src/domain/collaboration-events.js", () => ({
  publishCollaborationEvent: async () => {},
}));
vi.mock("../../src/domain/routes/space-permissions.js", async (original) => ({
  ...(await original<typeof import("../../src/domain/routes/space-permissions.js")>()),
  requireWorkflowPermission: async () => {},
}));

const cleanups: (() => void)[] = [];
afterEach(() => {
  for (const close of cleanups.splice(0)) close();
});

describe("Implement workflow: plan parsing", () => {
  it("parses structured YAML phases from a plan response", () => {
    const plan = `
# Architecture Plan
Here is the approach to solve the problem.

\`\`\`yaml:phases
phases:
  - id: 1
    title: "Database schema and models"
    description: "Add new user preferences table and migrations"
    files: ["migrations/001.sql", "src/models.ts"]
    criteria: "Migrations run cleanly and model tests pass"
  - id: 2
    title: "API endpoints"
    description: "Implement GET/PUT endpoints for preferences"
    files: ["src/routes/prefs.ts"]
    criteria: "All integration tests return 200"
\`\`\`

Let me know if you approve this plan!
    `;

    const phases = parseImplementationPhases(plan);
    expect(phases).toHaveLength(2);
    expect(phases[0]).toEqual({
      id: 1,
      title: "Database schema and models",
      description: "Add new user preferences table and migrations",
      files: ["migrations/001.sql", "src/models.ts"],
      criteria: "Migrations run cleanly and model tests pass",
    });
    expect(phases[1]).toEqual({
      id: 2,
      title: "API endpoints",
      description: "Implement GET/PUT endpoints for preferences",
      files: ["src/routes/prefs.ts"],
      criteria: "All integration tests return 200",
    });
  });

  it("parses JSON phases block as a fallback", () => {
    const plan = `
\`\`\`json:phases
[
  { "id": 1, "title": "Setup", "description": "Initialize package" },
  { "id": 2, "title": "Build", "description": "Compile output" }
]
\`\`\`
    `;
    const phases = parseImplementationPhases(plan);
    expect(phases).toHaveLength(2);
    expect(phases[0]?.title).toBe("Setup");
    expect(phases[1]?.title).toBe("Build");
  });

  it("parses Markdown phase section headers when no fenced block is present", () => {
    const plan = `
# Plan

### Phase 1: Authentication Migration
Goal: Migrate tokens from session store to JWT.
Completion Criteria: Auth tests pass.

### Phase 2: User Profile UI
Goal: Update frontend profile components.
Completion Criteria: Profile renders avatar and bio.
    `;
    const phases = parseImplementationPhases(plan);
    expect(phases).toHaveLength(2);
    expect(phases[0]?.title).toBe("Authentication Migration");
    expect(phases[0]?.description).toBe(
      "Migrate tokens from session store to JWT.",
    );
    expect(phases[0]?.criteria).toBe("Auth tests pass.");
    expect(phases[1]?.title).toBe("User Profile UI");
    expect(phases[1]?.description).toBe("Update frontend profile components.");
  });
});

function fixture() {
  const { sqlite, db } = sqliteD1();
  cleanups.push(() => sqlite.close());

  sqlite
    .prepare(
      "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES(?,?,?,'now','now')",
    )
    .run("owner", "owner@test", "OWNER");

  sqlite.exec(`
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('S','owner','Space','now','now');
    INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('m1','S','owner','owner','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('T','S','Thread','active','owner','now','now');
  `);

  const env = {
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_DB: db,
    TEST_AUTHENTICATION: async (_req: Request) => ({
      userId: "owner",
      user: {
        id: "owner",
        email: "owner@test",
        displayName: "OWNER",
        status: "active",
      },
      workspaceId: "",
      spaceRoles: { S: "owner" },
      sessionId: "test",
    }),
  } as unknown as SecurityEnv;

  return { sqlite, env };
}

describe("Implement workflow: plan approval and queue restrictions", () => {
  it("enforces that phased items in thread_request_queue cannot be edited", async () => {
    const { sqlite, env } = fixture();
    sqlite
      .prepare(
        `INSERT INTO thread_request_queue(id,thread_id,author_user_id,request_json,position,status,created_at,updated_at)
         VALUES('trq-phase-1','T','owner',?,'1','queued','now','now')`,
      )
      .run(
        JSON.stringify({
          workflowId: "direct",
          isPhased: true,
          phaseIndex: 1,
        }),
      );

    const req = new Request(
      "https://syntila.test/api/threads/T/queue/trq-phase-1",
      {
        method: "PUT",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          request: {
            workflowId: "direct",
            input: { originalRequest: "edited" },
          },
        }),
      },
    );

    await expect(
      handleThreadRequestQueue(req, env, "T", "trq-phase-1", null),
    ).rejects.toThrow(/Phased implementation steps cannot be edited/);
  });

  it("enforces that phased items cannot be forced (send-now) out of sequence", async () => {
    const { sqlite, env } = fixture();
    sqlite
      .prepare(
        `INSERT INTO thread_request_queue(id,thread_id,author_user_id,request_json,position,status,created_at,updated_at)
         VALUES('trq-phase-1','T','owner',?,'1','queued','now','now')`,
      )
      .run(
        JSON.stringify({
          workflowId: "direct",
          isPhased: true,
          phaseIndex: 1,
        }),
      );

    const req = new Request(
      "https://syntila.test/api/threads/T/queue/trq-phase-1/send-now",
      {
        method: "POST",
        headers: {
          authorization: "Bearer test",
        },
      },
    );

    await expect(
      handleThreadRequestQueue(req, env, "T", "trq-phase-1", "send-now"),
    ).rejects.toThrow(
      /Phased implementation steps execute in their planned sequence/,
    );
  });

  it("rejects removing a single phased item and removes all with stop-phases", async () => {
    const { sqlite, env } = fixture();
    sqlite
      .prepare(
        `INSERT INTO thread_request_queue(id,thread_id,author_user_id,request_json,position,status,created_at,updated_at)
         VALUES('trq-phase-1','T','owner',?,'1','queued','now','now')`,
      )
      .run(
        JSON.stringify({
          workflowId: "direct",
          isPhased: true,
          phaseIndex: 1,
          planWorkRequestId: "wr-plan-1",
        }),
      );

    const deleteReq = new Request(
      "https://syntila.test/api/threads/T/queue/trq-phase-1",
      {
        method: "DELETE",
        headers: {
          authorization: "Bearer test",
        },
      },
    );

    await expect(
      handleThreadRequestQueue(deleteReq, env, "T", "trq-phase-1", null),
    ).rejects.toMatchObject({ status: 400 });

    const stopReq = new Request(
      "https://syntila.test/api/threads/T/queue/trq-phase-1/stop-phases",
      {
        method: "POST",
        headers: {
          authorization: "Bearer test",
        },
      },
    );

    const res = await handleThreadRequestQueue(
      stopReq,
      env,
      "T",
      "trq-phase-1",
      "stop-phases",
    );
    expect(res.status).toBe(200);

    const row = sqlite
      .prepare("SELECT 1 FROM thread_request_queue WHERE id = 'trq-phase-1'")
      .get();
    expect(row).toBeUndefined();
  });

  it("handleApprovePlan validates plan, parses phases, and enqueues locked requests with verification", async () => {
    const { sqlite, env } = fixture();

    const planJson = JSON.stringify({
      text: `
# Implementation Plan

\`\`\`yaml:phases
phases:
  - id: 1
    title: "Setup Auth"
    description: "Install auth dependencies"
    criteria: "Auth packages installed"
  - id: 2
    title: "Auth Route"
    description: "Add login and register endpoints"
    criteria: "Auth routes return 200"
\`\`\`
      `,
    });

    sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at)
         VALUES('wr-plan-1','T','owner','stateless','plan_implement',2,'{}','{}','completed','{}','now','now')`,
      )
      .run();

    sqlite
      .prepare(
        `INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,output_json,created_at,updated_at)
         VALUES('task-plan-1','wr-plan-1','plan','stateless_read',60000,'plan:v2','completed',?,'now','now')`,
      )
      .run(planJson);

    const req = new Request(
      "https://syntila.test/api/work-requests/wr-plan-1/approve-plan",
      {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          verificationMode: "per_phase",
        }),
      },
    );

    const response = await handleApprovePlan(req, env, "wr-plan-1");
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body.approved).toBe(true);
    expect(body.phasesCount).toBe(2);
    // 2 phases + 2 per-phase verifications = 4 items enqueued
    expect(body.enqueuedCount).toBe(4);

    const queuedRows = sqlite
      .prepare(
        "SELECT request_json, position FROM thread_request_queue WHERE thread_id = 'T' ORDER BY position",
      )
      .all() as Array<{ request_json: string; position: number }>;

    expect(queuedRows).toHaveLength(4);
    const item1 = JSON.parse(queuedRows[0]!.request_json);
    const item2 = JSON.parse(queuedRows[1]!.request_json);
    const item3 = JSON.parse(queuedRows[2]!.request_json);
    const item4 = JSON.parse(queuedRows[3]!.request_json);

    expect(item1.isPhased).toBe(true);
    expect(item1.isVerification).toBe(false);
    expect(item1.phaseTitle).toBe("Setup Auth");

    expect(item2.isPhased).toBe(true);
    expect(item2.isVerification).toBe(true);
    expect(item2.phaseTitle).toContain("Verify Phase 1");

    expect(item3.isPhased).toBe(true);
    expect(item3.isVerification).toBe(false);
    expect(item3.phaseTitle).toBe("Auth Route");

    expect(item4.isPhased).toBe(true);
    expect(item4.isVerification).toBe(true);
    expect(item4.phaseTitle).toContain("Verify Phase 2");
  });

  it("handleApprovePlan attaches executionSelection for implementer and verifier from space config and overrides", async () => {
    const { sqlite, env } = fixture();

    // Configure space workflow for plan_implement with custom roles
    sqlite
      .prepare(
        `INSERT INTO space_workflow_configurations(space_id,workflow_id,schema_version,configuration_json,updated_at)
         VALUES('S','plan_implement',1,?,'now')`,
      )
      .run(
        JSON.stringify({
          schemaVersion: 1,
          workflowId: "plan_implement",
          enabled: true,
          stepOverrides: {
            plan: { worker: "worker-plan" },
            implement: { worker: "worker-impl", model: "model-impl" },
            verify: {
              worker: "worker-ver",
              model: "model-ver",
              effort: "high",
            },
          },
        }),
      );

    const planJson = JSON.stringify({
      text: `
\`\`\`yaml:phases
phases:
  - id: 1
    title: "Phase One"
    description: "Do stuff"
\`\`\`
      `,
    });

    sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at)
         VALUES('wr-plan-2','T','owner','stateless','plan_implement',2,'{}','{}','completed','{}','now','now')`,
      )
      .run();

    sqlite
      .prepare(
        `INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,output_json,created_at,updated_at)
         VALUES('task-plan-2','wr-plan-2','plan','stateless_read',60000,'plan:v2','completed',?,'now','now')`,
      )
      .run(planJson);

    // Call approve plan with verificationMode='per_phase' and an override for implementer model
    const req = new Request(
      "https://syntila.test/api/work-requests/wr-plan-2/approve-plan",
      {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          verificationMode: "per_phase",
          implementer: { model: "model-override" },
        }),
      },
    );

    const response = await handleApprovePlan(req, env, "wr-plan-2");
    expect(response.status).toBe(200);

    const queuedRows = sqlite
      .prepare(
        "SELECT request_json FROM thread_request_queue WHERE thread_id = 'T' ORDER BY position",
      )
      .all() as Array<{ request_json: string }>;

    expect(queuedRows).toHaveLength(2);
    const implItem = JSON.parse(queuedRows[0]!.request_json);
    const verifyItem = JSON.parse(queuedRows[1]!.request_json);

    // Implementer gets worker-impl from space config and model-override from request body
    expect(implItem.executionSelection).toEqual({
      workerId: "worker-impl",
      model: "model-override",
    });

    // Verifier gets full config from space
    expect(verifyItem.executionSelection).toEqual({
      workerId: "worker-ver",
      model: "model-ver",
      reasoningEffort: "high",
    });
  });
});

describe("Implement workflow: phase completion and auto-pause", () => {
  it("pauses the remaining phases and finishes the phase when output has STATUS: NEEDS_INPUT", async () => {
    const { sqlite, env } = fixture();

    sqlite
      .prepare(
        `INSERT INTO thread_request_queue(id,thread_id,author_user_id,request_json,position,status,created_at,updated_at)
         VALUES('trq-phase-2','T','owner','{}',2,'queued','now','now')`,
      )
      .run();

    sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at)
         VALUES('wr-phase-1','T','owner','stateless','direct',2,'{}','{}','running',?,'now','now')`,
      )
      .run(
        JSON.stringify({
          isPhased: true,
          phaseIndex: 1,
          phaseTitle: "Setup Database",
        }),
      );

    sqlite
      .prepare(
        `INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,output_json,created_at,updated_at)
         VALUES('task-phase-1','wr-phase-1','implement','stateless_read',60000,'implement:v2','completed',?,'now','now')`,
      )
      .run(
        JSON.stringify({
          text: "I set up the files, but I need clarification.\n```status\nSTATUS: NEEDS_INPUT\nREASON: Database credentials not specified in env\n```",
        }),
      );

    const result = await evaluatePhaseCompletionAndAdvanceQueue(
      env,
      "T",
      "wr-phase-1",
      "work_request.completed",
    );

    expect(result.paused).toBe(true);
    expect(result.reason).toContain(
      "Database credentials not specified in env",
    );

    const wrRow = sqlite
      .prepare("SELECT status FROM work_requests WHERE id = 'wr-phase-1'")
      .get() as { status: string };
    // Not left half-open: a reply runs as a normal request.
    expect(wrRow.status).not.toBe("waiting");

    const queueState = sqlite
      .prepare(
        "SELECT paused_reason, failure_message FROM thread_request_queue_state WHERE thread_id = 'T'",
      )
      .get() as { paused_reason: string; failure_message: string };
    expect(queueState).toBeDefined();
    expect(queueState.paused_reason).toBe("failure");
    expect(queueState.failure_message).toContain(
      "Setup Database needs your input: Database credentials not specified",
    );
  });

  it("pauses the queue and marks work request as failed when verification output has STATUS: FAILED", async () => {
    const { sqlite, env } = fixture();

    sqlite
      .prepare(
        `INSERT INTO thread_request_queue(id,thread_id,author_user_id,request_json,position,status,created_at,updated_at)
         VALUES('trq-phase-2','T','owner','{}',2,'queued','now','now')`,
      )
      .run();

    sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at)
         VALUES('wr-verify-1','T','owner','stateless','direct',2,'{}','{}','running',?,'now','now')`,
      )
      .run(
        JSON.stringify({
          isPhased: true,
          phaseIndex: 1,
          phaseTitle: "Verify Database",
          isVerification: true,
        }),
      );

    sqlite
      .prepare(
        `INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,output_json,created_at,updated_at)
         VALUES('task-verify-1','wr-verify-1','verify','stateless_read',60000,'verify:v2','completed',?,'now','now')`,
      )
      .run(
        JSON.stringify({
          text: "Verification failed.\n```status\nSTATUS: FAILED\nREASON: 2 unit tests failed in db-test.ts\n```",
        }),
      );

    const result = await evaluatePhaseCompletionAndAdvanceQueue(
      env,
      "T",
      "wr-verify-1",
      "work_request.completed",
    );

    expect(result.paused).toBe(true);
    expect(result.reason).toContain("2 unit tests failed in db-test.ts");

    const wrRow = sqlite
      .prepare("SELECT status FROM work_requests WHERE id = 'wr-verify-1'")
      .get() as { status: string };
    expect(wrRow.status).toBe("failed");

    const queueState = sqlite
      .prepare(
        "SELECT paused_reason, failure_message FROM thread_request_queue_state WHERE thread_id = 'T'",
      )
      .get() as { paused_reason: string; failure_message: string };
    expect(queueState).toBeDefined();
    expect(queueState.failure_message).toContain(
      "Verify Database failed: 2 unit tests failed",
    );
  });

  it("does not pause the queue when a phase completes with STATUS: COMPLETED", async () => {
    const { sqlite, env } = fixture();

    sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at)
         VALUES('wr-phase-ok','T','owner','stateless','direct',2,'{}','{}','completed',?,'now','now')`,
      )
      .run(
        JSON.stringify({
          isPhased: true,
          phaseIndex: 1,
          phaseTitle: "Setup DB",
        }),
      );

    sqlite
      .prepare(
        `INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,output_json,created_at,updated_at)
         VALUES('task-phase-ok','wr-phase-ok','implement','stateless_read',60000,'implement:v2','completed',?,'now','now')`,
      )
      .run(
        JSON.stringify({
          text: "Finished phase 1 cleanly.\n```status\nSTATUS: COMPLETED\n```",
        }),
      );

    const result = await evaluatePhaseCompletionAndAdvanceQueue(
      env,
      "T",
      "wr-phase-ok",
      "work_request.completed",
    );

    expect(result.paused).toBe(false);

    const queueState = sqlite
      .prepare("SELECT 1 FROM thread_request_queue_state WHERE thread_id = 'T'")
      .get();
    expect(queueState).toBeUndefined();
  });
});

describe("Implement workflow: hardening", () => {
  it("parses multi-line, quoted and nested-list YAML phases", () => {
    const plan = [
      "```yaml:phases",
      "phases:",
      "  - id: 1",
      "    title: \"Add 'cache' layer\"",
      "    description: Wrap the loader",
      "      and keep the API stable",
      "    files:",
      "      - src/a.ts",
      "      - src/b.ts",
      "    criteria: tests pass",
      "  - id: 2",
      "    title: Second",
      "    description: Next",
      "```",
    ].join("\n");
    const phases = parseImplementationPhases(plan);
    expect(phases).toHaveLength(2);
    expect(phases[0]!.description).toBe(
      "Wrap the loader and keep the API stable",
    );
    expect(phases[0]!.files).toEqual(["src/a.ts", "src/b.ts"]);
    expect(phases[1]!.title).toBe("Second");
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  async function seedPlan(sqlite: any, workflowId = "plan_implement") {
    sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at)
         VALUES('wr-h','T','owner','stateless',?,2,'{}','{}','completed','{}','now','now')`,
      )
      .run(workflowId);
    sqlite
      .prepare(
        `INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,output_json,created_at,updated_at)
         VALUES('task-h','wr-h','plan','stateless_read',60000,'plan:v2','completed',?,'now','now')`,
      )
      .run(JSON.stringify({ text: "### Phase 1: Only\nGoal: do it" }));
  }

  const approve = (env: SecurityEnv, body: unknown) =>
    handleApprovePlan(
      new Request("https://syntila.test/api/work-requests/wr-h/approve-plan", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
      }),
      env,
      "wr-h",
    );

  it("rejects non-Implement requests, bad modes and double approval", async () => {
    const a = fixture();
    await seedPlan(a.sqlite, "direct");
    await expect(approve(a.env, {})).rejects.toMatchObject({ status: 400 });

    const b = fixture();
    await seedPlan(b.sqlite);
    await expect(
      approve(b.env, { verificationMode: "bogus" }),
    ).rejects.toMatchObject({ status: 400 });
    await expect(
      approve(b.env, { customPhases: [{ title: 1 }] }),
    ).rejects.toMatchObject({ status: 400 });
    expect((await approve(b.env, { verificationMode: "none" })).status).toBe(
      200,
    );
    await expect(
      approve(b.env, { verificationMode: "none" }),
    ).rejects.toMatchObject({ status: 409 });
  });

  it("pauses when a phase, or a status follow-up, reports no status marker", async () => {
    for (const [isVerification, kind, isStatusFollowUp] of [
      [false, "implement", false],
      [true, "verify", true],
    ] as const) {
      const { sqlite, env } = fixture();
      sqlite
        .prepare(
          `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at)
           VALUES('wr-x','T','owner','stateless','direct',2,'{}','{}','completed',?,'now','now')`,
        )
        .run(
          JSON.stringify({
            isPhased: true,
            phaseIndex: 1,
            phaseTitle: "P",
            isVerification,
            ...(isStatusFollowUp ? { isStatusFollowUp: true } : {}),
          }),
        );
      sqlite
        .prepare(
          `INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,output_json,created_at,updated_at)
           VALUES('task-x','wr-x',?,'stateless_read',60000,'x','completed',?,'now','now')`,
        )
        .run(kind, JSON.stringify({ text: "done, no marker" }));
      const result = await evaluatePhaseCompletionAndAdvanceQueue(
        env,
        "T",
        "wr-x",
        "work_request.completed",
      );
      expect(result.paused).toBe(true);
    }
  });

  it("asks the same verifier once for a missing status block", async () => {
    const { sqlite, env } = fixture();
    sqlite
      .prepare(
        `INSERT INTO thread_request_queue(id,thread_id,author_user_id,request_json,position,status,created_at,updated_at)
         VALUES('trq-next','T','owner','{}',5,'queued','now','now')`,
      )
      .run();
    // Held by the user, so the follow-up stays in the queue to inspect.
    sqlite
      .prepare(
        `INSERT INTO thread_request_queue_state(thread_id,paused_reason,paused_by_user_id,failure_message,updated_at)
         VALUES('T','user','owner',NULL,'now')`,
      )
      .run();
    sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at)
         VALUES('wr-v','T','owner','stateful','direct',2,'{}',?,'completed',?,'now','now')`,
      )
      .run(
        JSON.stringify({
          turnExecutionConfig: {
            workerId: "w-gemini",
            modelId: "gemini-3.8-flash",
            effort: "low",
          },
        }),
        JSON.stringify({
          isPhased: true,
          planWorkRequestId: "wr-plan",
          phaseIndex: 4,
          totalPhases: 4,
          phaseTitle: "Final Verification",
          isVerification: true,
          isFinalVerification: true,
        }),
      );
    sqlite
      .prepare(
        `INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,output_json,created_at,updated_at)
         VALUES('task-v','wr-v','implement','stateful_thread',60000,'implement:v1','completed',?,'now','now')`,
      )
      .run(JSON.stringify({ text: "# Report\nAll criteria met." }));

    const result = await evaluatePhaseCompletionAndAdvanceQueue(
      env,
      "T",
      "wr-v",
      "work_request.completed",
    );

    expect(result.paused).toBe(false);
    const wr = sqlite
      .prepare("SELECT status FROM work_requests WHERE id = 'wr-v'")
      .get() as { status: string };
    expect(wr.status).toBe("completed");
    const rows = sqlite
      .prepare(
        "SELECT id, request_json AS requestJson FROM thread_request_queue WHERE thread_id = 'T' ORDER BY position",
      )
      .all() as { id: string; requestJson: string }[];
    const followUp = rows.find((r) => r.id.startsWith("trq-verify-status-"));
    expect(followUp).toBeDefined();
    const request = JSON.parse(followUp!.requestJson);
    expect(request.executionSelection).toEqual({
      workerId: "w-gemini",
      model: "gemini-3.8-flash",
      reasoningEffort: "low",
    });
    expect(request.input.isStatusFollowUp).toBe(true);
    expect(request.input.isFinalVerification).toBe(true);
    expect(request.input.originalRequest).toContain("All criteria met.");
    expect(request.input.originalRequest).toContain("STATUS: PASSED");
    // It runs before the rest of the queue.
    expect(rows[0]!.id).toBe(followUp!.id);
  });

  it("marks the verified phase failed when its verification fails", async () => {
    const { sqlite, env } = fixture();
    const ins = sqlite.prepare(
      `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,status,input_json,created_at,updated_at)
       VALUES(?,'T','owner','stateless','direct',2,'{}','{}','completed',?,'now','now')`,
    );
    ins.run(
      "wr-impl",
      JSON.stringify({
        isPhased: true,
        planWorkRequestId: "wr-plan",
        phaseIndex: 1,
        isVerification: false,
      }),
    );
    ins.run(
      "wr-ver",
      JSON.stringify({
        isPhased: true,
        planWorkRequestId: "wr-plan",
        phaseIndex: 1,
        isVerification: true,
      }),
    );
    sqlite
      .prepare(
        `INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,output_json,created_at,updated_at)
         VALUES('task-ver','wr-ver','verify','stateless_read',60000,'x','completed',?,'now','now')`,
      )
      .run(JSON.stringify({ text: "STATUS: FAILED\nREASON: broken" }));
    await evaluatePhaseCompletionAndAdvanceQueue(
      env,
      "T",
      "wr-ver",
      "work_request.completed",
    );
    const row = sqlite
      .prepare("SELECT status FROM work_requests WHERE id='wr-impl'")
      .get() as { status: string };
    expect(row.status).toBe("failed");
  });
});
