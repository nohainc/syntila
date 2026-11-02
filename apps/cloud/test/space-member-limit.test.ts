import { afterEach, describe, expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import {
  handleAcceptSpaceInvitation,
  handleCreateSpaceInvitation,
  handleDeclineSpaceInvitation,
  handleExpireSpaceInvitation,
  handleListSpaceMembers,
  handleRemoveSpaceMember,
} from "../src/routes/handlers.js";
import {
  FREE_SPACE_MEMBER_LIMIT,
  getSpaceMemberUsage,
  spaceMemberLimit,
} from "../src/account-plan.js";

const MESSAGE =
  "Free includes up to 4 people in each Space, including the owner.";
const open: Array<{ close(): void }> = [];
afterEach(() => {
  for (const sqlite of open.splice(0)) sqlite.close();
});

function fixture() {
  const { sqlite, db } = sqliteD1();
  open.push(sqlite);
  const now = new Date().toISOString();
  const ids = ["O", "O2", "A", "B", "C", "D", "E", "F", "PLUS", "V"];
  for (const id of ids)
    sqlite
      .prepare(
        "INSERT INTO users (id,email,display_name,status,created_at,updated_at) VALUES (?,?,?,'active',?,?)",
      )
      .run(id, `${id.toLowerCase()}@example.test`, id, now, now);
  for (const [space, owner] of [
    ["S1", "O"],
    ["S2", "O"],
    ["S3", "O2"],
  ] as const) {
    sqlite
      .prepare(
        "INSERT INTO spaces (id,name,owner_user_id,created_at,updated_at) VALUES (?,?,?,?,?)",
      )
      .run(space, space, owner, now, now);
    sqlite
      .prepare(
        "INSERT INTO space_memberships (id,space_id,user_id,role,created_at,updated_at) VALUES (?,?,?,'owner',?,?)",
      )
      .run(`pm-${space}`, space, owner, now, now);
  }
  const env = {
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_DB: db,
    TEST_AUTHENTICATION: async (request: Request) => {
      const id = request.headers.get("authorization")!.replace("Bearer ", "");
      const row = sqlite
        .prepare("SELECT id,email,display_name FROM users WHERE id = ?")
        .get(id) as { id: string; email: string; display_name: string };
      const roles = sqlite
        .prepare(
          "SELECT space_id, role FROM space_memberships WHERE user_id = ?",
        )
        .all(id) as Array<{ space_id: string; role: string }>;
      return {
        userId: row.id,
        user: {
          id: row.id,
          email: row.email,
          displayName: row.display_name,
          status: "active",
        },
        workspaceId: "",
        spaceRoles: Object.fromEntries(roles.map((r) => [r.space_id, r.role])),
        sessionId: `sess-${id}`,
        clientType: "web",
      };
    },
  };
  const call = (
    as: string,
    path: string,
    method: string,
    body?: unknown,
    headers: Record<string, string> = {},
  ) =>
    new Request(`https://syntila.internal${path}`, {
      method,
      headers: {
        authorization: `Bearer ${as}`,
        "content-type": "application/json",
        ...headers,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  const raw_invite = (
    who: string,
    space = "S1",
    role = "collaborator",
    as = space === "S3" ? "O2" : "O",
    headers: Record<string, string> = {},
  ) =>
    handleCreateSpaceInvitation(
      call(
        as,
        `/api/spaces/${space}/invitations`,
        "POST",
        { email: `${who.toLowerCase()}@example.test`, role },
        headers,
      ),
      env as never,
      space,
    );
  const invitationId = (who: string, space = "S1") =>
    (
      sqlite
        .prepare(
          "SELECT id FROM space_invitations WHERE space_id=? AND LOWER(email)=? AND status='pending'",
        )
        .get(space, `${who.toLowerCase()}@example.test`) as { id: string }
    ).id;
  const raw_accept = (who: string, id: string) =>
    handleAcceptSpaceInvitation(
      call(who, `/api/me/invitations/${id}/accept`, "POST"),
      env as never,
      id,
    );
  const raw_decline = (who: string, id: string) =>
    handleDeclineSpaceInvitation(
      call(who, `/api/me/invitations/${id}/decline`, "POST"),
      env as never,
      id,
    );
  const raw_revoke = (id: string, space = "S1") =>
    handleExpireSpaceInvitation(
      call("O", `/api/spaces/${space}/invitations/${id}`, "DELETE"),
      env as never,
      space,
      id,
    );
  const raw_remove = (user: string, space = "S1") =>
    handleRemoveSpaceMember(
      call("O", `/api/spaces/${space}/members/${user}`, "DELETE"),
      env as never,
      space,
      user,
    );
  const invite = (...a: Parameters<typeof raw_invite>) =>
    response(raw_invite(...a));
  const accept = (...a: Parameters<typeof raw_accept>) =>
    response(raw_accept(...a));
  const decline = (...a: Parameters<typeof raw_decline>) =>
    response(raw_decline(...a));
  const revoke = (...a: Parameters<typeof raw_revoke>) =>
    response(raw_revoke(...a));
  const remove = (...a: Parameters<typeof raw_remove>) =>
    response(raw_remove(...a));
  const join = async (who: string, space = "S1", role = "collaborator") => {
    expect((await invite(who, space, role)).status).toBe(201);
    expect((await accept(who, invitationId(who, space))).status).toBe(200);
  };
  const plan = (user: string, status = "active", end: string | null = null) =>
    sqlite
      .prepare(
        `INSERT OR REPLACE INTO account_plans(user_id,tier,status,source,current_period_end,created_at,updated_at)
         VALUES(?, 'paid', ?, 'manual', ?, 'now', 'now')`,
      )
      .run(user, status, end);
  const usage = (space = "S1") => getSpaceMemberUsage(env as never, space);
  return {
    sqlite,
    env,
    invite,
    invitationId,
    accept,
    decline,
    revoke,
    remove,
    join,
    plan,
    usage,
    call,
  };
}

/** Handlers throw HttpError; the router turns it into this response. */
async function response(run: Promise<Response>): Promise<Response> {
  try {
    return await run;
  } catch (error) {
    const e = error as { status?: number; message: string; code?: string };
    if (typeof e.status !== "number") throw error;
    return Response.json(
      { error: e.message, ...(e.code ? { code: e.code } : {}) },
      { status: e.status },
    );
  }
}

const code = async (response: Response) =>
  ((await response.json()) as { code?: string; error?: string }) ?? {};

describe("Free Space member allowance", () => {
  it("keeps the allowance in the central plan policy", () => {
    expect(FREE_SPACE_MEMBER_LIMIT).toBe(4);
    expect(spaceMemberLimit("free")).toBe(4);
    expect(spaceMemberLimit("paid")).toBeNull();
  });

  it("counts the owner, allows the fourth person and blocks the fifth", async () => {
    const f = fixture();
    expect(await f.usage()).toEqual({
      members: 1,
      pendingInvitations: 0,
      limit: 4,
    });
    await f.join("A");
    await f.join("B");
    await f.join("C", "S1", "viewer"); // viewers count too
    expect((await f.usage()).members).toBe(4);
    const blocked = await f.invite("D");
    expect(blocked.status).toBe(402);
    const body = await code(blocked);
    expect(body.code).toBe("space_member_limit_reached");
    expect(body.error).toContain(MESSAGE);
    expect(body.error).toContain("Upgrade to Syntila Plus");
  });

  it("reserves a slot for each pending invitation and counts AI Workers nowhere", async () => {
    const f = fixture();
    await f.join("A");
    expect((await f.invite("B")).status).toBe(201);
    expect((await f.invite("C")).status).toBe(201);
    expect(await f.usage()).toMatchObject({
      members: 2,
      pendingInvitations: 2,
    });
    expect((await f.invite("D")).status).toBe(402);
    // Workers are not Space members: they never appear in the count.
    expect(
      f.sqlite
        .prepare(
          "SELECT COUNT(*) AS n FROM space_memberships WHERE space_id='S1'",
        )
        .get(),
    ).toEqual({ n: 2 });
  });

  it("converts a reservation to membership on acceptance without a second slot", async () => {
    const f = fixture();
    await f.join("A");
    expect((await f.invite("C")).status).toBe(201); // 2 members + 1 pending
    expect((await f.invite("D")).status).toBe(201); // 4 reserved
    expect((await f.invite("E")).status).toBe(402);
    expect((await f.accept("C", f.invitationId("C"))).status).toBe(200);
    expect(await f.usage()).toMatchObject({
      members: 3,
      pendingInvitations: 1,
    });
    expect((await f.invite("E")).status).toBe(402); // still 4 reserved
    expect((await f.accept("D", f.invitationId("D"))).status).toBe(200);
    expect(await f.usage()).toMatchObject({
      members: 4,
      pendingInvitations: 0,
    });
  });

  it("releases capacity on decline, revocation, expiry and member removal", async () => {
    const f = fixture();
    await f.join("A");
    await f.invite("B");
    await f.invite("C");
    expect((await f.invite("D")).status).toBe(402);
    expect((await f.decline("B", f.invitationId("B"))).status).toBe(200);
    expect((await f.invite("D")).status).toBe(201);
    expect((await f.invite("E")).status).toBe(402);
    await f.revoke(f.invitationId("C"));
    expect((await f.invite("E")).status).toBe(201);
    // An invitation past its expiry no longer reserves a slot.
    f.sqlite.exec(
      "UPDATE space_invitations SET expires_at='2000-01-01T00:00:00.000Z' WHERE LOWER(email)='d@example.test'",
    );
    expect(await f.usage()).toMatchObject({ pendingInvitations: 1 });
    expect((await f.invite("F")).status).toBe(201);
    // Removing a member frees a slot.
    expect((await f.invite("PLUS")).status).toBe(402);
    expect((await f.remove("A")).status).toBeLessThan(300);
    expect((await f.invite("PLUS")).status).toBe(201);
  });

  it("does not consume a slot for duplicates, existing members or retried requests", async () => {
    const f = fixture();
    await f.join("A");
    expect((await f.invite("B")).status).toBe(201);
    expect((await f.invite("B")).status).toBe(409); // already pending
    expect((await f.invite("A")).status).toBe(409); // already a member
    const keyed = { "idempotency-key": "11111111-1111-4111-8111-111111111111" };
    const first = await f.invite("C", "S1", "collaborator", "O", keyed);
    const retry = await f.invite("C", "S1", "collaborator", "O", keyed);
    expect(first.status).toBe(201);
    expect(retry.status).toBe(201);
    expect(await f.usage()).toMatchObject({
      members: 2,
      pendingInvitations: 2,
    });
    // Email case and whitespace do not create a second reservation.
    expect((await f.invite("B".toUpperCase(), "S1")).status).toBe(409);
  });

  it("allows one reservation when many invitations race for the last slot", async () => {
    const f = fixture();
    await f.join("A"); // two slots left
    const results = await Promise.all(
      ["C", "D", "E", "F"].map((who) => f.invite(who)),
    );
    expect(results.filter((r) => r.status === 201)).toHaveLength(2);
    expect(results.filter((r) => r.status === 402)).toHaveLength(2);
    expect(
      (await f.usage()).members + (await f.usage()).pendingInvitations,
    ).toBe(4);
  });

  it("counts every Space on its own", async () => {
    const f = fixture();
    await f.join("A", "S1");
    await f.join("B", "S1");
    await f.join("C", "S1");
    expect((await f.invite("D", "S1")).status).toBe(402);
    // The same people fit in the owner's other Space and in another owner's.
    for (const who of ["A", "B", "C"]) await f.join(who, "S2");
    await f.join("A", "S3");
    expect((await f.usage("S2")).members).toBe(4);
    expect((await f.usage("S3")).members).toBe(2);
  });

  it("follows the Space owner's plan, not the inviter's or recipient's", async () => {
    const f = fixture();
    // A Plus recipient does not lift a Free owner's limit...
    f.plan("PLUS");
    await f.join("A");
    await f.join("B");
    await f.join("C");
    expect((await f.invite("PLUS")).status).toBe(402);
    // ...but a Free person can join a larger Plus-owned Space.
    f.plan("O2");
    for (const who of ["A", "B", "C", "D", "E"]) await f.join(who, "S3");
    expect((await f.usage("S3")).limit).toBeNull();
    expect((await f.usage("S3")).members).toBe(6);
  });

  it("re-evaluates the owner's plan: upgrade, expiry, grace and downgrade", async () => {
    const f = fixture();
    await f.join("A");
    await f.join("B");
    await f.join("C");
    expect((await f.invite("D")).status).toBe(402);
    f.plan("O"); // upgrade
    expect((await f.invite("D")).status).toBe(201);
    expect((await f.invite("E")).status).toBe(201);
    f.plan("O", "active", "2000-01-01T00:00:00Z"); // expired: Free again
    expect((await f.usage()).limit).toBe(4);
    expect((await f.invite("F")).status).toBe(402);
    f.plan("O", "past_due", "2999-01-01T00:00:00Z"); // grace keeps Plus
    expect((await f.invite("F")).status).toBe(201);
    expect((await f.usage()).limit).toBeNull();
  });

  it("preserves an over-limit Space after a downgrade, but blocks additions and acceptance", async () => {
    const f = fixture();
    f.plan("O");
    for (const who of ["A", "B", "C"]) await f.join(who);
    await f.invite("D");
    await f.invite("E");
    f.sqlite.exec("DELETE FROM account_plans WHERE user_id='O'"); // downgrade
    // Nobody is removed and nothing is revoked.
    expect(await f.usage()).toMatchObject({
      members: 4,
      pendingInvitations: 2,
    });
    // Pending invitations are kept but cannot be accepted while over the limit.
    const refused = await f.accept("D", f.invitationId("D"));
    expect(refused.status).toBe(402);
    const body = await code(refused);
    expect(body.code).toBe("space_member_limit_reached");
    expect(body.error).toContain("owner needs to upgrade");
    expect(
      f.sqlite
        .prepare(
          "SELECT status FROM space_invitations WHERE LOWER(email)='d@example.test'",
        )
        .get(),
    ).toEqual({ status: "pending" });
    expect((await f.invite("F")).status).toBe(402);
    // Management stays available: revoke and remove still work.
    await f.revoke(f.invitationId("E"));
    expect((await f.remove("C")).status).toBeLessThan(300);
    // 3 members + 1 pending (D) = 4: D's own reservation is not counted twice.
    expect((await f.accept("D", f.invitationId("D"))).status).toBe(200);
    expect(await f.usage()).toMatchObject({
      members: 4,
      pendingInvitations: 0,
    });
    // Existing members keep access.
    expect(
      (
        await handleListSpaceMembers(
          f.call("A", "/api/spaces/S1/members", "GET"),
          f.env as never,
          "S1",
        )
      ).status,
    ).toBe(200);
  });

  it("reports usage with the members list", async () => {
    const f = fixture();
    await f.join("A");
    await f.invite("B");
    const response = await handleListSpaceMembers(
      f.call("A", "/api/spaces/S1/members", "GET"),
      f.env as never,
      "S1",
    );
    expect(((await response.json()) as { usage: unknown }).usage).toEqual({
      members: 2,
      pendingInvitations: 1,
      limit: 4,
    });
  });

  it("accepts simultaneous invitations that exactly fill the allowance, each counted once", async () => {
    const f = fixture();
    f.plan("O");
    await f.join("D");
    await f.invite("A");
    await f.invite("B"); // O + D + two pending = 4 reserved
    f.sqlite.exec("DELETE FROM account_plans WHERE user_id='O'");
    const results = await Promise.all(
      ["A", "B"].map((who) => f.accept(who, f.invitationId(who))),
    );
    expect(results.map((r) => r.status)).toEqual([200, 200]);
    expect(await f.usage()).toMatchObject({
      members: 4,
      pendingInvitations: 0,
    });
  });
});
