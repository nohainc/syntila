import { expect, it, vi } from "vitest";
import { BUILTIN_WORKFLOW_CATALOG } from "@syntila/core";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import type { SecurityEnv } from "../src/routes/http-security.js";
vi.mock("../src/routes/http-security.js", async (original) => ({
  ...(await original<typeof import("../src/routes/http-security.js")>()),
  securityContext: async (request: Request) => {
    const userId = request.headers.get("authorization");
    if (!userId) throw new Error("Unauthenticated");
    return { userId, user: { email: `${userId}@test` } };
  },
}));
vi.mock("../src/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  validateWorkflowWorkerEligibility: async () => ({
    issues: [],
    primaryWorkspaceId: "lent",
    workerCatalogRevisions: {},
  }),
}));
vi.mock("../src/routes/thread-policy.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  validateWorkflowWorkerEligibility: async () => ({
    issues: [],
    primaryWorkspaceId: "lent",
    workerCatalogRevisions: {},
  }),
}));
import {
  handlePersonGrantQuota,
  handleRevokePersonGrant,
} from "../src/routes/workspace-invitations.js";
import { handleWorkflowWorkspace } from "../src/routes/workflow-workspace.js";
import { handleListWorkspaces } from "../src/routes/workspaces-management.js";
import { handleListWorkspaceWorkerInventory } from "../src/routes/profiles.js";
import { resolveWorkflowExecutionBindings } from "../src/routes/workflow-execution-configuration.js";

/**
 * "lender" owns Workspace "lent". "guest" owns Space "G" which runs on it; "friend"
 * is only a member of Space "G". "own" is guest's own Workspace.
 */
function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(`CREATE TABLE IF NOT EXISTS worker_profiles(worker_type_id TEXT, revision INTEGER, profile_json TEXT, digest TEXT);
    CREATE TABLE IF NOT EXISTS worker_profile_history(worker_type_id TEXT, revision INTEGER, profile_json TEXT, digest TEXT);
    ALTER TABLE workspace_worker_inventory ADD COLUMN model_catalog_json TEXT;
    INSERT INTO users(id,email,display_name,created_at,updated_at)
      VALUES('lender','lender@test','L','now','now'),('guest','guest@test','G','now','now'),('friend','friend@test','F','now','now');
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('G','guest','Guest space','now','now');
    INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at)
      VALUES('m1','G','guest','owner','now','now'),('m2','G','friend','collaborator','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('T','G','Stream','active','guest','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('lent','lender','Lender Mac','now','now'),('own','guest','Mine','now','now');
    INSERT INTO account_plans(user_id,tier,status,source,created_at,updated_at) VALUES('lender','paid','active','manual','now','now');
    INSERT INTO workspace_worker_inventory(worker_id,workspace_id,owner_user_id,worker_type_id,activation_state,readiness_state,local_concurrency_limit,revision,created_at,updated_at,last_seen_at)
      VALUES('worker-a','lent','lender','chatgpt','enabled','ready',1,1,'now','now','now');
    INSERT INTO user_workflow_settings VALUES('guest','own','now');
    INSERT INTO space_workflow_settings VALUES('G','lent','now');
    INSERT INTO space_workflow_configurations(space_id,workflow_id,schema_version,configuration_json,updated_at)
      VALUES('G','direct',1,'{"schemaVersion":1,"workflowId":"direct","enabled":true,"defaults":{"worker":"worker-a"},"stepOverrides":{}}','now'),
        ('G','chat',1,'{"schemaVersion":1,"workflowId":"chat","enabled":true,"defaults":{"worker":"worker-a"},"stepOverrides":{}}','now');`);
  const env = { SYNTILA_DB: db } as SecurityEnv;
  const grantGuest = (
    policy = '{"schemaVersion":1,"mode":"work","workers":{"worker-a":{"models":null,"efforts":null}}}',
  ) =>
    sqlite.exec(`INSERT INTO workspace_person_grants(workspace_id,user_id,granted_by_user_id,status,created_at,updated_at) VALUES('lent','guest','lender','active','now','now');
      INSERT INTO workspace_member_overrides VALUES('lent','guest','${policy}','now');`);
  const bind = (userId: string, workflowId = "chat") =>
    resolveWorkflowExecutionBindings(
      env,
      userId,
      "G",
      "T",
      Object.values(BUILTIN_WORKFLOW_CATALOG)
        .filter((entry) => entry.id === workflowId)
        .sort((a, b) => b.version - a.version)[0]!,
      {},
      [],
    );
  const workspaceFor = (method: string, user: string, body?: unknown) =>
    handleWorkflowWorkspace(
      new Request("https://cloud.test/api/spaces/G/workflow-workspace", {
        method,
        headers: { authorization: user },
        ...(body ? { body: JSON.stringify(body) } : {}),
      }),
      env,
      "G",
    );
  const revoke = (user: string, person: string) =>
    handleRevokePersonGrant(
      new Request("https://cloud.test/x", {
        method: "POST",
        headers: { authorization: user },
      }),
      env,
      "lent",
      person,
    );
  const setQuota = (user: string, body: unknown) =>
    handlePersonGrantQuota(
      new Request("https://cloud.test/x", {
        method: "PUT",
        headers: { authorization: user },
        body: JSON.stringify(body),
      }),
      env,
      "lent",
      "guest",
    );
  return { sqlite, env, setQuota, bind, grantGuest, workspaceFor, revoke };
}

it("lets the borrower, not their Space friend, run on the lent Workspace", async () => {
  const { sqlite, bind, grantGuest } = fixture();
  try {
    // Without a grant even the Space owner is refused.
    await expect(bind("guest")).rejects.toMatchObject({ status: 403 });
    grantGuest();
    expect((await bind("guest")).chat).toMatchObject({
      workerId: "worker-a",
    });
    // Strict: Space members never use it, not even with their own grant.
    await expect(bind("friend")).rejects.toMatchObject({ status: 403 });
    sqlite.exec(
      `INSERT INTO workspace_person_grants(workspace_id,user_id,granted_by_user_id,status,created_at,updated_at) VALUES('lent','friend','lender','active','now','now')`,
    );
    await expect(bind("friend")).rejects.toMatchObject({ status: 403 });
    // Nor does the lender through someone else's Space.
    await expect(bind("lender")).rejects.toMatchObject({ status: 403 });
  } finally {
    sqlite.close();
  }
});

it("runs only Chat on a lent Workspace, whatever the borrower's mode", async () => {
  const { sqlite, bind, grantGuest } = fixture();
  try {
    grantGuest();
    await expect(bind("guest", "direct")).rejects.toMatchObject({
      status: 403,
    });
    expect((await bind("guest")).chat).toMatchObject({ workerId: "worker-a" });
  } finally {
    sqlite.close();
  }
});

it("creates the Space grant by the lender and never touches the lender's scheduling", async () => {
  const { sqlite, grantGuest, workspaceFor } = fixture();
  try {
    grantGuest();
    await workspaceFor("GET", "guest");
    expect(
      sqlite
        .prepare(
          "SELECT granted_by_user_id g, status s, allowed_permissions_json p FROM workspace_space_grants WHERE space_id='G'",
        )
        .all(),
    ).toEqual([{ g: "lender", s: "active", p: '["repository:read"]' }]);
    // The lent Workspace is offered to the borrower beside their own.
    const body = (await (await workspaceFor("GET", "guest")).json()) as {
      workspaces: { id: string }[];
    };
    expect(body.workspaces.map((w) => w.id).sort()).toEqual(["lent", "own"]);
  } finally {
    sqlite.close();
  }
});

it("refuses to select a Workspace that is neither owned nor lent", async () => {
  const { sqlite, workspaceFor } = fixture();
  try {
    await expect(
      workspaceFor("PUT", "guest", { workspaceId: "lent", confirmReset: true }),
    ).rejects.toMatchObject({ status: 403 });
  } finally {
    sqlite.close();
  }
});

it("revokes a grant: owner only, ends access and the Space grant, and is audited", async () => {
  const { sqlite, bind, grantGuest, workspaceFor, revoke } = fixture();
  try {
    grantGuest();
    await workspaceFor("GET", "guest");
    await expect(revoke("guest", "guest")).rejects.toMatchObject({
      status: 404,
    });
    await revoke("lender", "guest");
    await expect(bind("guest")).rejects.toMatchObject({ status: 403 });
    expect(
      sqlite
        .prepare("SELECT status FROM workspace_space_grants WHERE space_id='G'")
        .all(),
    ).toEqual([{ status: "revoked" }]);
    expect(
      sqlite.prepare("SELECT action FROM workspace_audit_log").all(),
    ).toEqual([{ action: "workspace.person_grant.revoked" }]);
    await expect(revoke("lender", "guest")).rejects.toMatchObject({
      status: 404,
    });
    // The borrower can still read the selection after revocation.
    expect((await workspaceFor("GET", "guest")).status).toBe(200);
  } finally {
    sqlite.close();
  }
});

it("shows the lender usage only, never the borrower's content", async () => {
  const { sqlite, env, grantGuest } = fixture();
  const { handlePeopleWithAccess } =
    await import("../src/routes/workspace-people-with-access.js");
  const call = (user: string) =>
    handlePeopleWithAccess(
      new Request("https://cloud.test/x", {
        headers: { authorization: user },
      }),
      env,
      "lent",
    );
  try {
    grantGuest();
    // Fixture rows only need the columns usage reads.
    sqlite.exec("PRAGMA foreign_keys = OFF");
    sqlite.exec(`INSERT INTO worker_assignments(id,space_id,execution_workspace_id,runtime_identity_id,worker_type_id,status,input_json,created_at,updated_at,requested_by_user_id,workspace_worker_id)
      VALUES('a1','G','lent','rt','chatgpt','completed','{"prompt":"SECRET PROMPT"}','2026-01-01T00:00:00.000Z','2026-01-01T00:01:00.000Z','guest','worker-a'),
            ('a2','G','lent','rt','chatgpt','completed','{}','2026-01-02T00:00:00.000Z','2026-01-02T00:00:30.000Z','guest','worker-a'),
            ('a3','G','lent','rt','chatgpt','completed','{}','2026-01-03T00:00:00.000Z','2026-01-03T00:00:10.000Z','lender','worker-a')`);
    await expect(call("guest")).rejects.toMatchObject({ status: 404 });
    const text = await (await call("lender")).text();
    const body = JSON.parse(text) as { people: Record<string, unknown>[] };
    expect(body.people).toHaveLength(1);
    expect(body.people[0]).toEqual({
      userId: "guest",
      displayName: "G",
      email: "guest@test",
      status: "active",
      grantedAt: "now",
      maxConcurrentRequests: 1,
      maxRunSecondsPerMonth: null,
      custom: true,
      mode: "work",
      usage: {
        requests: 2,
        approxSeconds: 90,
        lastUsedAt: "2026-01-02T00:00:00.000Z",
        monthSeconds: 0,
        workerIds: ["worker-a"],
      },
    });
    // No Space name, Thread title or prompt text anywhere in the response.
    for (const secret of ["SECRET PROMPT", "Guest space", "Stream"])
      expect(text).not.toContain(secret);
  } finally {
    sqlite.close();
  }
});

it("limits the borrower's concurrent requests, set by the owner", async () => {
  const { sqlite, bind, grantGuest, setQuota } = fixture();
  try {
    grantGuest();
    sqlite.exec("PRAGMA foreign_keys = OFF");
    const busy = (id: string, status: string) =>
      sqlite.exec(`INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,primary_workspace_id,created_at,updated_at)
        VALUES('${id}','T','guest','stateful','direct',1,'{}','${status}','lent','now','now')`);
    expect((await bind("guest")).chat).toBeDefined();
    busy("r1", "running");
    // Default limit is 1: a second request is refused until the first ends.
    await expect(bind("guest")).rejects.toMatchObject({ status: 429 });
    sqlite.exec("UPDATE work_requests SET status='completed'");
    expect((await bind("guest")).chat).toBeDefined();
    // Only the Workspace owner sets the limit, within 1-10.
    await expect(
      setQuota("guest", { maxConcurrentRequests: 5 }),
    ).rejects.toMatchObject({ status: 404 });
    await expect(
      setQuota("lender", { maxConcurrentRequests: 11 }),
    ).rejects.toMatchObject({ status: 400 });
    await setQuota("lender", { maxConcurrentRequests: 2 });
    busy("r2", "running");
    expect((await bind("guest")).chat).toBeDefined();
    busy("r3", "queued");
    await expect(bind("guest")).rejects.toMatchObject({ status: 429 });
  } finally {
    sqlite.close();
  }
});

it("limits the borrower's run time per month, set by the owner", async () => {
  const { sqlite, bind, grantGuest, setQuota } = fixture();
  try {
    grantGuest();
    sqlite.exec("PRAGMA foreign_keys = OFF");
    const row = (id: string, created: string, updated: string) =>
      sqlite.exec(`INSERT INTO worker_assignments(id,space_id,execution_workspace_id,runtime_identity_id,worker_type_id,status,created_at,updated_at,requested_by_user_id,workspace_worker_id)
        VALUES('${id}','G','lent','rt','chatgpt','completed','${created}','${updated}','guest','worker-a')`);
    const month = new Date();
    const start = new Date(
      Date.UTC(month.getUTCFullYear(), month.getUTCMonth(), 1, 0, 1),
    );
    const iso = (offsetSeconds: number) =>
      new Date(start.getTime() + offsetSeconds * 1000).toISOString();
    // Time used in earlier months does not count.
    row("old", "2020-01-01T00:00:00.000Z", "2020-01-01T05:00:00.000Z");
    await setQuota("lender", { maxRunSecondsPerMonth: 120 });
    expect((await bind("guest")).chat).toBeDefined();
    row("now1", iso(0), iso(100));
    expect((await bind("guest")).chat).toBeDefined();
    row("now2", iso(200), iso(260));
    await expect(bind("guest")).rejects.toMatchObject({ status: 429 });
    // The owner can raise or clear the limit; the concurrent limit is untouched.
    await setQuota("lender", { maxRunSecondsPerMonth: 600 });
    expect((await bind("guest")).chat).toBeDefined();
    await setQuota("lender", { maxRunSecondsPerMonth: null });
    row("now3", iso(300), iso(5000));
    expect((await bind("guest")).chat).toBeDefined();
    await expect(
      setQuota("lender", { maxRunSecondsPerMonth: 10 }),
    ).rejects.toMatchObject({ status: 400 });
    await expect(setQuota("lender", {})).rejects.toMatchObject({ status: 400 });
  } finally {
    sqlite.close();
  }
});

it("lists a lent Workspace as shared and lets the borrower make it the default", async () => {
  const { sqlite, env, grantGuest } = fixture();
  const list = async (user: string) =>
    (
      (await (
        await handleListWorkspaces(
          new Request("https://cloud.test/api/workspaces", {
            headers: { authorization: user },
          }),
          env,
        )
      ).json()) as {
        workspaces: { id: string; role: string; shared: boolean }[];
      }
    ).workspaces.map(({ id, role, shared }) => ({ id, role, shared }));
  const global = (method: string, body?: unknown) =>
    handleWorkflowWorkspace(
      new Request("https://cloud.test/api/workflow-workspace", {
        method,
        headers: { authorization: "guest" },
        ...(body ? { body: JSON.stringify(body) } : {}),
      }),
      env,
    );
  try {
    expect(await list("guest")).toEqual([
      { id: "own", role: "owner", shared: false },
    ]);
    grantGuest();
    expect(await list("guest")).toEqual([
      { id: "own", role: "owner", shared: false },
      { id: "lent", role: "member", shared: true },
    ]);
    // The lender still sees it as their own.
    expect(await list("lender")).toEqual([
      { id: "lent", role: "owner", shared: false },
    ]);
    const choices = (await (await global("GET")).json()) as {
      workspaces: { id: string }[];
    };
    expect(choices.workspaces.map((w) => w.id)).toEqual(["own", "lent"]);
    await global("PUT", { workspaceId: "lent", confirmReset: true });
    expect(
      sqlite
        .prepare(
          "SELECT workspace_id FROM user_workflow_settings WHERE user_id='guest'",
        )
        .get(),
    ).toEqual({ workspace_id: "lent" });
  } finally {
    sqlite.close();
  }
});

it("does not pass a lent Workspace on to the borrower's Space members", async () => {
  const { sqlite, env, grantGuest, workspaceFor } = fixture();
  const workers = async (user: string) =>
    (
      (await (
        await handleListWorkspaceWorkerInventory(
          new Request("https://cloud.test/api/workers?includeShared=true", {
            headers: { authorization: user },
          }),
          env,
        )
      ).json()) as { workers: { id: string }[] }
    ).workers.map((worker) => worker.id);
  try {
    grantGuest();
    expect(await workers("guest")).toEqual(["worker-a"]);
    // "friend" is in guest's Space G, which runs on the lent Workspace.
    expect(await workers("friend")).toEqual([]);
    // A Space member cannot pick it, and the Space shows only the selection.
    await expect(
      workspaceFor("PUT", "friend", {
        workspaceId: "lent",
        confirmReset: true,
      }),
    ).rejects.toMatchObject({ status: 403 });
  } finally {
    sqlite.close();
  }
});

it("pauses lent access while the lender is on Free and restores it on renewal", async () => {
  const { sqlite, env, bind, grantGuest } = fixture();
  const listed = async () =>
    (
      (await (
        await handleListWorkspaces(
          new Request("https://cloud.test/api/workspaces", {
            headers: { authorization: "guest" },
          }),
          env,
        )
      ).json()) as { workspaces: { id: string }[] }
    ).workspaces.map((w) => w.id);
  const sharedWorkers = async () =>
    (
      (await (
        await handleListWorkspaceWorkerInventory(
          new Request("https://cloud.test/api/workers?includeShared=true", {
            headers: { authorization: "guest" },
          }),
          env,
        )
      ).json()) as { workers: { id: string }[] }
    ).workers.map((worker) => worker.id);
  try {
    grantGuest();
    expect(await listed()).toContain("lent");
    expect(await sharedWorkers()).toEqual(["worker-a"]);
    // The period ended without renewal: the lender is Free now.
    sqlite.exec(
      "UPDATE account_plans SET current_period_end='2020-01-01T00:00:00Z' WHERE user_id='lender'",
    );
    await expect(bind("guest")).rejects.toMatchObject({
      status: 403,
      message: expect.stringContaining("no longer shared"),
    });
    expect(await listed()).toEqual(["own"]);
    expect(await sharedWorkers()).toEqual([]);
    // The grant itself is kept, so renewing restores access.
    sqlite.exec(
      "UPDATE account_plans SET status='active', current_period_end='2999-01-01T00:00:00.000Z' WHERE user_id='lender'",
    );
    expect((await bind("guest")).chat).toMatchObject({
      workerId: "worker-a",
    });
    expect(await listed()).toContain("lent");
  } finally {
    sqlite.close();
  }
});
