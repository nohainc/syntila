import { describe, expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import worker from "../src/index.js";

describe("Personal Invitations API (Phase 2)", () => {
  function createTestEnv() {
    const { sqlite, db } = sqliteD1();
    const now = new Date().toISOString();

    sqlite.exec(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at) VALUES
        ('user-alice', 'alice@test.com', 'Alice User', 'active', '${now}', '${now}'),
        ('user-bob', 'bob@test.com', 'Bob User', 'active', '${now}', '${now}'),
        ('user-charlie', 'charlie@test.com', 'Charlie User', 'active', '${now}', '${now}'),
        ('user-inactive', 'inactive@test.com', 'Inactive User', 'suspended', '${now}', '${now}');

      -- Establish existing collaborator relationship between Alice and Bob
      INSERT INTO people_relationships (user_low_id, user_high_id, established_at) VALUES
        ('user-alice', 'user-bob', '${now}');
    `);

    const users: Record<
      string,
      { id: string; email: string; displayName: string; status: string }
    > = {
      alice: {
        id: "user-alice",
        email: "alice@test.com",
        displayName: "Alice User",
        status: "active",
      },
      bob: {
        id: "user-bob",
        email: "bob@test.com",
        displayName: "Bob User",
        status: "active",
      },
      charlie: {
        id: "user-charlie",
        email: "charlie@test.com",
        displayName: "Charlie User",
        status: "active",
      },
      inactive: {
        id: "user-inactive",
        email: "inactive@test.com",
        displayName: "Inactive User",
        status: "suspended",
      },
    };

    const env = {
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: db,
      TEST_AUTHENTICATION: async (req: Request) => {
        const authHeader = req.headers.get("authorization");
        const key = authHeader?.replace("Bearer ", "");
        const user = key ? users[key] : null;
        if (!user) {
          return {
            userId: "anonymous",
            user: {
              id: "anonymous",
              email: "anon@test.com",
              displayName: "Anon",
              status: "active",
            },
            workspaceId: "",
            spaceRoles: {},
            sessionId: "sess-anon",
            clientType: "web",
          };
        }
        return {
          userId: user.id,
          user,
          workspaceId: "",
          spaceRoles: {},
          sessionId: `sess-${user.id}`,
          clientType: "web",
        };
      },
    };

    return { sqlite, db, env, users };
  }

  it("sends a new email invitation and lists incoming/outgoing", async () => {
    const { env } = createTestEnv();

    const sendReq = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer alice",
        "content-type": "application/json",
      },
      body: JSON.stringify({ email: "david@test.com" }),
    });

    const sendRes = await worker.fetch(sendReq, env as never);
    expect(sendRes.status).toBe(201);
    const sendBody = (await sendRes.json()) as {
      status: string;
      invitation: { id: string; email: string; status: string };
      emailDelivered: boolean;
    };
    expect(sendBody.status).toBe("pending");
    expect(sendBody.invitation.email).toBe("david@test.com");
    expect(sendBody.emailDelivered).toBe(true);

    // List outgoing for Alice
    const listReq = new Request("https://syntila.test/api/people/invitations", {
      headers: { authorization: "Bearer alice" },
    });
    const listRes = await worker.fetch(listReq, env as never);
    expect(listRes.status).toBe(200);
    const listBody = (await listRes.json()) as {
      incoming: unknown[];
      outgoing: { id: string; email: string }[];
    };
    expect(listBody.outgoing).toHaveLength(1);
    expect(listBody.outgoing[0]!.id).toBe(sendBody.invitation.id);
    expect(listBody.incoming).toHaveLength(0);
  });

  it("sends invitation to existing known collaborator by userId", async () => {
    const { env } = createTestEnv();

    const req = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer alice",
        "content-type": "application/json",
      },
      body: JSON.stringify({ userId: "user-bob" }),
    });

    const res = await worker.fetch(req, env as never);
    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      status: string;
      invitation: { id: string; inviteeUserId: string };
    };
    expect(body.status).toBe("pending");
    expect(body.invitation.inviteeUserId).toBe("user-bob");

    // Bob sees it in incoming
    const bobReq = new Request("https://syntila.test/api/people/invitations", {
      headers: { authorization: "Bearer bob" },
    });
    const bobRes = await worker.fetch(bobReq, env as never);
    expect(bobRes.status).toBe(200);
    const bobBody = (await bobRes.json()) as {
      incoming: { id: string; inviterUserId: string }[];
    };
    expect(bobBody.incoming).toHaveLength(1);
    expect(bobBody.incoming[0]!.inviterUserId).toBe("user-alice");
  });

  it("handles same-person retry idempotently", async () => {
    const { env } = createTestEnv();

    const post1 = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer alice",
        "content-type": "application/json",
      },
      body: JSON.stringify({ userId: "user-bob" }),
    });
    const res1 = await worker.fetch(post1, env as never);
    expect(res1.status).toBe(201);
    const body1 = (await res1.json()) as { invitation: { id: string } };

    // Retry sending
    const post2 = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer alice",
        "content-type": "application/json",
      },
      body: JSON.stringify({ userId: "user-bob" }),
    });
    const res2 = await worker.fetch(post2, env as never);
    expect(res2.status).toBe(200);
    const body2 = (await res2.json()) as {
      status: string;
      invitation: { id: string };
    };
    expect(body2.status).toBe("pending");
    expect(body2.invitation.id).toBe(body1.invitation.id);
  });

  it("automatically connects reciprocal simultaneous invitations", async () => {
    const { sqlite, env } = createTestEnv();

    // Alice invites Bob
    const req1 = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer alice",
        "content-type": "application/json",
      },
      body: JSON.stringify({ userId: "user-bob" }),
    });
    const res1 = await worker.fetch(req1, env as never);
    expect(res1.status).toBe(201);

    // Bob simultaneously sends invitation to Alice
    const req2 = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer bob",
        "content-type": "application/json",
      },
      body: JSON.stringify({ userId: "user-alice" }),
    });
    const res2 = await worker.fetch(req2, env as never);
    expect(res2.status).toBe(200);
    const body2 = (await res2.json()) as {
      status: string;
      directSpaceId: string;
      connection: { status: string };
    };
    expect(body2.status).toBe("connected");
    expect(body2.directSpaceId).toBeDefined();

    // The Direct Space starts without an automatically created Thread.
    const ds = sqlite
      .prepare("SELECT * FROM direct_spaces WHERE space_id = ?")
      .get(body2.directSpaceId) as {
      space_id: string;
      general_thread_id: string | null;
    };
    expect(ds).toBeDefined();
    expect(ds.general_thread_id).toBeNull();
    expect(
      sqlite
        .prepare("SELECT id FROM threads WHERE space_id = ?")
        .all(body2.directSpaceId),
    ).toHaveLength(0);

    // Verify both participants are in space_memberships
    const members = sqlite
      .prepare("SELECT user_id, role FROM space_memberships WHERE space_id = ?")
      .all(body2.directSpaceId) as { user_id: string; role: string }[];
    expect(members).toHaveLength(2);
    expect(members.map((m) => m.user_id).sort()).toEqual([
      "user-alice",
      "user-bob",
    ]);

    // Subsequent invite returns already_connected
    const req3 = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer alice",
        "content-type": "application/json",
      },
      body: JSON.stringify({ userId: "user-bob" }),
    });
    const res3 = await worker.fetch(req3, env as never);
    const body3 = (await res3.json()) as {
      status: string;
      directSpaceId: string;
    };
    expect(body3.status).toBe("already_connected");
    expect(body3.directSpaceId).toBe(body2.directSpaceId);
  });

  it("handles decline, cancel, and expiration", async () => {
    const { sqlite, env } = createTestEnv();

    // Decline flow
    const req1 = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer alice",
        "content-type": "application/json",
      },
      body: JSON.stringify({ userId: "user-bob" }),
    });
    const res1 = await worker.fetch(req1, env as never);
    const { invitation: inv1 } = (await res1.json()) as {
      invitation: { id: string };
    };

    const declineReq = new Request(
      `https://syntila.test/api/people/invitations/${inv1.id}/decline`,
      { method: "POST", headers: { authorization: "Bearer bob" } },
    );
    const declineRes = await worker.fetch(declineReq, env as never);
    expect(declineRes.status).toBe(200);
    expect((await declineRes.json()) as { status: string }).toEqual({
      status: "declined",
    });

    // Trying to accept declined invitation returns 400
    const acceptReq = new Request(
      `https://syntila.test/api/people/invitations/${inv1.id}/accept`,
      { method: "POST", headers: { authorization: "Bearer bob" } },
    );
    const acceptRes = await worker.fetch(acceptReq, env as never);
    expect(acceptRes.status).toBe(400);

    // Cancel flow
    const req2 = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer alice",
        "content-type": "application/json",
      },
      body: JSON.stringify({ email: "someone@test.com" }),
    });
    const res2 = await worker.fetch(req2, env as never);
    const { invitation: inv2 } = (await res2.json()) as {
      invitation: { id: string };
    };

    const cancelReq = new Request(
      `https://syntila.test/api/people/invitations/${inv2.id}/cancel`,
      { method: "POST", headers: { authorization: "Bearer alice" } },
    );
    const cancelRes = await worker.fetch(cancelReq, env as never);
    expect(cancelRes.status).toBe(200);
    expect((await cancelRes.json()) as { status: string }).toEqual({
      status: "cancelled",
    });

    // Expiration flow
    const past = new Date(Date.now() - 1000).toISOString();
    sqlite.exec(`
      INSERT INTO person_invitations (id, inviter_user_id, invitee_user_id, status, created_at, expires_at, updated_at)
      VALUES ('inv-expired', 'user-alice', 'user-bob', 'pending', '${past}', '${past}', '${past}');
    `);
    const expiredReq = new Request(
      "https://syntila.test/api/people/invitations/inv-expired/accept",
      { method: "POST", headers: { authorization: "Bearer bob" } },
    );
    const expiredRes = await worker.fetch(expiredReq, env as never);
    expect(expiredRes.status).toBe(400);
  });

  it("prevents acceptance by the wrong account", async () => {
    const { env } = createTestEnv();

    const req = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer alice",
        "content-type": "application/json",
      },
      body: JSON.stringify({ userId: "user-bob" }),
    });
    const res = await worker.fetch(req, env as never);
    const { invitation } = (await res.json()) as { invitation: { id: string } };

    // Charlie tries to accept Bob's invitation
    const wrongReq = new Request(
      `https://syntila.test/api/people/invitations/${invitation.id}/accept`,
      { method: "POST", headers: { authorization: "Bearer charlie" } },
    );
    const wrongRes = await worker.fetch(wrongReq, env as never);
    expect(wrongRes.status).toBe(403);
  });

  it("retains recipient identity through email change before acceptance", async () => {
    const { sqlite, env } = createTestEnv();

    // Alice invites Bob by userId
    const req = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer alice",
        "content-type": "application/json",
      },
      body: JSON.stringify({ userId: "user-bob" }),
    });
    const res = await worker.fetch(req, env as never);
    const { invitation } = (await res.json()) as { invitation: { id: string } };

    // Bob changes his email in database
    sqlite.exec(
      "UPDATE users SET email = 'bob-new@test.com' WHERE id = 'user-bob'",
    );

    // Bob accepts
    const acceptReq = new Request(
      `https://syntila.test/api/people/invitations/${invitation.id}/accept`,
      { method: "POST", headers: { authorization: "Bearer bob" } },
    );
    const acceptRes = await worker.fetch(acceptReq, env as never);
    expect(acceptRes.status).toBe(200);
    const acceptBody = (await acceptRes.json()) as {
      status: string;
      directSpaceId: string;
    };
    expect(acceptBody.status).toBe("accepted");
    expect(acceptBody.directSpaceId).toBeDefined();
  });

  it("supports unknown email invitation followed by registration and acceptance", async () => {
    const { sqlite, env } = createTestEnv();

    // Alice invites non-registered email eva@test.com
    const req = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer alice",
        "content-type": "application/json",
      },
      body: JSON.stringify({ email: "eva@test.com" }),
    });
    const res = await worker.fetch(req, env as never);
    expect(res.status).toBe(201);
    const { invitation } = (await res.json()) as { invitation: { id: string } };

    // Eva registers
    const now = new Date().toISOString();
    sqlite.exec(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at)
      VALUES ('user-eva', 'eva@test.com', 'Eva User', 'active', '${now}', '${now}');
    `);

    // Eva can now authenticate
    const evaEnv = {
      ...env,
      TEST_AUTHENTICATION: async () => ({
        userId: "user-eva",
        user: {
          id: "user-eva",
          email: "eva@test.com",
          displayName: "Eva User",
          status: "active",
        },
        workspaceId: "",
        spaceRoles: {},
        sessionId: "sess-eva",
        clientType: "web",
      }),
    };

    // Eva sees the invitation
    const listReq = new Request("https://syntila.test/api/people/invitations");
    const listRes = await worker.fetch(listReq, evaEnv as never);
    const listBody = (await listRes.json()) as { incoming: { id: string }[] };
    expect(listBody.incoming).toHaveLength(1);
    expect(listBody.incoming[0]!.id).toBe(invitation.id);

    // Eva accepts
    const acceptReq = new Request(
      `https://syntila.test/api/people/invitations/${invitation.id}/accept`,
      { method: "POST" },
    );
    const acceptRes = await worker.fetch(acceptReq, evaEnv as never);
    expect(acceptRes.status).toBe(200);
    const acceptBody = (await acceptRes.json()) as {
      status: string;
      directSpaceId: string;
    };
    expect(acceptBody.status).toBe("accepted");
    expect(acceptBody.directSpaceId).toBeDefined();

    // Connection exists in DB for (alice, eva)
    const conn = sqlite
      .prepare(
        "SELECT * FROM person_connections WHERE user_low_id = 'user-alice' AND user_high_id = 'user-eva'",
      )
      .get() as { status: string };
    expect(conn.status).toBe("connected");
  });

  it("handles deleted or deactivated recipient and inviter", async () => {
    const { sqlite, env } = createTestEnv();

    // Trying to invite inactive recipient returns 400
    const req1 = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer alice",
        "content-type": "application/json",
      },
      body: JSON.stringify({ email: "inactive@test.com" }),
    });
    const res1 = await worker.fetch(req1, env as never);
    expect(res1.status).toBe(400);

    // Alice invites Bob, then Alice is deactivated before acceptance
    const req2 = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer alice",
        "content-type": "application/json",
      },
      body: JSON.stringify({ userId: "user-bob" }),
    });
    const res2 = await worker.fetch(req2, env as never);
    const { invitation } = (await res2.json()) as {
      invitation: { id: string };
    };

    sqlite.exec(
      "UPDATE users SET status = 'deactivated' WHERE id = 'user-alice'",
    );

    const acceptReq = new Request(
      `https://syntila.test/api/people/invitations/${invitation.id}/accept`,
      { method: "POST", headers: { authorization: "Bearer bob" } },
    );
    const acceptRes = await worker.fetch(acceptReq, env as never);
    expect(acceptRes.status).toBe(400);
  });

  it("enforces rate limiting on invitation creation", async () => {
    const { sqlite, env } = createTestEnv();
    const now = new Date().toISOString();

    // Insert 20 invitations in the last hour
    for (let i = 0; i < 20; i++) {
      sqlite.exec(`
        INSERT INTO person_invitations (id, inviter_user_id, email, status, created_at, expires_at, updated_at)
        VALUES ('rate-${i}', 'user-alice', 'target${i}@test.com', 'pending', '${now}', '${now}', '${now}');
      `);
    }

    const req = new Request("https://syntila.test/api/people/invitations", {
      method: "POST",
      headers: {
        authorization: "Bearer alice",
        "content-type": "application/json",
      },
      body: JSON.stringify({ email: "target-overflow@test.com" }),
    });
    const res = await worker.fetch(req, env as never);
    expect(res.status).toBe(429);
  });
});
