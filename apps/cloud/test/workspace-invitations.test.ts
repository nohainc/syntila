import { expect, it, vi } from "vitest";
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
import {
  handleAcceptWorkspaceInvitation,
  handleMyWorkspaceInvitations,
  handleWorkspaceInvitations,
} from "../src/routes/workspace-invitations.js";

function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at)
      VALUES('owner','owner@test','Owner','now','now'),('guest','guest@test','Guest','now','now'),('other','other@test','Other','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('workspace','owner','Mac','now','now');
    INSERT INTO account_plans(user_id,tier,status,source,created_at,updated_at) VALUES('owner','paid','active','manual','now','now');`);
  const env = { SYNTILA_DB: db } as SecurityEnv;
  const manage = (
    method: string,
    user: string,
    body?: unknown,
    invitationId?: string,
  ) =>
    handleWorkspaceInvitations(
      new Request("https://cloud.test/api/workspaces/workspace/invitations", {
        method,
        headers: { authorization: user },
        ...(body ? { body: JSON.stringify(body) } : {}),
      }),
      env,
      "workspace",
      invitationId,
    );
  const accept = (user: string, id: string) =>
    handleAcceptWorkspaceInvitation(
      new Request("https://cloud.test/x", {
        method: "POST",
        headers: { authorization: user },
      }),
      env,
      id,
    );
  const mine = (user: string) =>
    handleMyWorkspaceInvitations(
      new Request("https://cloud.test/x", { headers: { authorization: user } }),
      env,
    );
  return { sqlite, env, manage, accept, mine };
}
const idOf = async (response: Response) =>
  ((await response.json()) as { id: string }).id;

it("lets only the owner invite, and rejects bad or duplicate invitations", async () => {
  const { sqlite, manage } = fixture();
  try {
    await expect(
      manage("POST", "guest", { email: "x@test" }),
    ).rejects.toMatchObject({ status: 404 });
    await expect(
      manage("POST", "owner", { email: "owner@test" }),
    ).rejects.toMatchObject({ status: 400 });
    await expect(
      manage("POST", "owner", { email: "nope" }),
    ).rejects.toMatchObject({ status: 400 });
    expect(
      (await manage("POST", "owner", { email: "Guest@Test" })).status,
    ).toBe(201);
    await expect(
      manage("POST", "owner", { email: "guest@test" }),
    ).rejects.toMatchObject({ status: 409 });
  } finally {
    sqlite.close();
  }
});

it("accept creates only a grant (no people relationship), once, for the invited email", async () => {
  const { sqlite, manage, accept, mine } = fixture();
  try {
    const id = await idOf(
      await manage("POST", "owner", { email: "guest@test" }),
    );
    expect(
      ((await (await mine("guest")).json()) as { invitations: unknown[] })
        .invitations,
    ).toHaveLength(1);
    expect(
      ((await (await mine("other")).json()) as { invitations: unknown[] })
        .invitations,
    ).toHaveLength(0);
    await expect(accept("other", id)).rejects.toMatchObject({ status: 403 });
    await expect(accept("owner", id)).rejects.toMatchObject({ status: 403 });
    await accept("guest", id);
    expect(
      sqlite.prepare("SELECT status FROM workspace_person_grants").all(),
    ).toEqual([{ status: "active" }]);
    // No default policy: the guest starts chat-only with nothing shared.
    expect(
      sqlite
        .prepare("SELECT policy_json p FROM workspace_member_overrides")
        .get(),
    ).toEqual({ p: '{"schemaVersion":1,"mode":"chat","workers":{}}' });
    expect(
      sqlite.prepare("SELECT COUNT(*) n FROM people_relationships").get(),
    ).toEqual({ n: 0 });
    // Retried accept returns the original successful result instead of failing
    const repeated = await accept("guest", id);
    expect(repeated.status).toBe(200);
    expect(await repeated.json()).toMatchObject({ status: "active" });
    await expect(
      manage("POST", "owner", { email: "guest@test" }),
    ).rejects.toMatchObject({ status: 409 });
  } finally {
    sqlite.close();
  }
});

it("follows an existing default policy instead of adding an override", async () => {
  const { sqlite, manage, accept } = fixture();
  try {
    sqlite.exec(
      `INSERT INTO workspace_member_access VALUES('workspace','{"schemaVersion":1,"mode":"work","workers":{}}','now')`,
    );
    await accept(
      "guest",
      await idOf(await manage("POST", "owner", { email: "guest@test" })),
    );
    expect(
      sqlite.prepare("SELECT COUNT(*) n FROM workspace_member_overrides").get(),
    ).toEqual({ n: 0 });
  } finally {
    sqlite.close();
  }
});

it("rejects revoked and expired invitations", async () => {
  const { sqlite, manage, accept } = fixture();
  try {
    const revoked = await idOf(
      await manage("POST", "owner", { email: "guest@test" }),
    );
    await manage("POST", "owner", undefined, revoked);
    await expect(accept("guest", revoked)).rejects.toMatchObject({
      status: 404,
    });
    await expect(
      manage("POST", "owner", undefined, revoked),
    ).rejects.toMatchObject({ status: 404 });
    const expired = await idOf(
      await manage("POST", "owner", { email: "guest@test" }),
    );
    sqlite.exec(
      `UPDATE workspace_invitations SET expires_at='2000-01-01T00:00:00.000Z' WHERE id='${expired}'`,
    );
    await expect(accept("guest", expired)).rejects.toMatchObject({
      status: 410,
    });
  } finally {
    sqlite.close();
  }
});

it("caps pending invitations per Workspace", async () => {
  const { sqlite, manage } = fixture();
  try {
    for (let i = 0; i < 20; i++)
      await manage("POST", "owner", { email: `p${i}@test` });
    await expect(
      manage("POST", "owner", { email: "late@test" }),
    ).rejects.toMatchObject({ status: 429 });
  } finally {
    sqlite.close();
  }
});

it("requires a paid plan to invite, and lapses pending invitations on downgrade", async () => {
  const { sqlite, manage, accept } = fixture();
  try {
    const id = await idOf(
      await manage("POST", "owner", { email: "guest@test" }),
    );
    sqlite.exec("DELETE FROM account_plans WHERE user_id='owner'");
    await expect(
      manage("POST", "owner", { email: "other@test" }),
    ).rejects.toMatchObject({ status: 402, code: "paid_plan_required" });
    // A downgraded owner can still see and revoke what they shared.
    expect((await manage("GET", "owner")).status).toBe(200);
    await expect(accept("guest", id)).rejects.toMatchObject({ status: 403 });
    expect(
      sqlite.prepare("SELECT COUNT(*) AS n FROM workspace_person_grants").get(),
    ).toEqual({ n: 0 });
    expect((await manage("POST", "owner", undefined, id)).status).toBe(200);
  } finally {
    sqlite.close();
  }
});
