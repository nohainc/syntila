import { describe, expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import {
  handleListCurrentUserInvitations,
  handleAcceptSpaceInvitation,
  handleDeclineSpaceInvitation,
} from "../../src/domain/routes/handlers.js";
import worker from "../../src/domain/index.js";

describe("Recipient Invitations API", () => {
  function createTestEnv() {
    const { sqlite, db } = sqliteD1();
    const now = new Date().toISOString();

    // Seed users
    sqlite.exec(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at)
      VALUES 
        ('user-vitalii', 'vitalii@nohainc.com', 'Vitalii Noha', 'active', '${now}', '${now}'),
        ('user-ulikoss', 'ulikossnokia@gmail.com', 'Ulikoss Nokia', 'active', '${now}', '${now}'),
        ('user-other', 'other@example.com', 'Other Person', 'active', '${now}', '${now}');
    `);

    // Seed space owned by vitalii
    sqlite.exec(`
      INSERT INTO spaces (id, name, owner_user_id, created_at, updated_at)
      VALUES ('proj-1', 'Syntila Development', 'user-vitalii', '${now}', '${now}');
      INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at)
      VALUES ('pm-1', 'proj-1', 'user-vitalii', 'owner', '${now}', '${now}');
    `);

    const env = {
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: db,
      TEST_AUTHENTICATION: async (req: Request) => {
        const authHeader = req.headers.get("authorization");
        if (authHeader === "Bearer ulikoss") {
          return {
            userId: "user-ulikoss",
            user: {
              id: "user-ulikoss",
              email: "ulikossnokia@gmail.com",
              displayName: "Ulikoss Nokia",
              status: "active",
            },
            workspaceId: "",
            spaceRoles: {},
            sessionId: "sess-ulikoss",
            clientType: "web",
          };
        }
        if (authHeader === "Bearer vitalii") {
          return {
            userId: "user-vitalii",
            user: {
              id: "user-vitalii",
              email: "vitalii@nohainc.com",
              displayName: "Vitalii Noha",
              status: "active",
            },
            workspaceId: "",
            spaceRoles: { "proj-1": "owner" },
            sessionId: "sess-vitalii",
            clientType: "web",
          };
        }
        return {
          userId: "user-other",
          user: {
            id: "user-other",
            email: "other@example.com",
            displayName: "Other Person",
            status: "active",
          },
          workspaceId: "",
          spaceRoles: {},
          sessionId: "sess-other",
          clientType: "web",
        };
      },
    };

    return { sqlite, db, env };
  }

  describe("GET /api/me/invitations", () => {
    it("returns active pending invitations for authenticated recipient", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();
      const past = new Date(Date.now() - 86400000).toISOString();

      // Active invitation to ulikoss
      sqlite.exec(`
        INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-1', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-1', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      // An expired pending invitation in another Space (one pending per Space/email).
      sqlite.exec(
        `INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('proj-expired','user-vitalii','Expired','now','now')`,
      );
      sqlite.exec(`
        INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-expired', 'proj-expired', 'ulikossnokia@gmail.com', 'collaborator', 'hash-exp', 'user-vitalii', 'pending', '${past}', '${past}', '${past}');
      `);

      // Invitation to someone else
      sqlite.exec(`
        INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-other', 'proj-1', 'other@example.com', 'collaborator', 'hash-other', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const req = new Request("https://syntila.test/api/me/invitations", {
        headers: { authorization: "Bearer ulikoss" },
      });
      const res = await handleListCurrentUserInvitations(req, env as never);
      expect(res.status).toBe(200);

      const body = (await res.json()) as {
        invitations: Array<Record<string, unknown>>;
      };
      expect(body.invitations).toHaveLength(1);
      expect(body.invitations[0]).toMatchObject({
        id: "pinv-1",
        spaceId: "proj-1",
        spaceName: "Syntila Development",
        email: "ulikossnokia@gmail.com",
        role: "collaborator",
        status: "pending",
        invitedByUserId: "user-vitalii",
        invitedByUserName: "Vitalii Noha",
        invitedByUserEmail: "vitalii@nohainc.com",
      });
    });

    it("works via appRouter dispatch", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-router', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-r', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const req = new Request("https://syntila.test/api/me/invitations", {
        headers: { authorization: "Bearer ulikoss" },
      });
      const res = await worker.fetch(req, env as never);
      expect(res.status).toBe(200);
      const body = (await res.json()) as { invitations: unknown[] };
      expect(body.invitations).toHaveLength(1);
    });
  });

  describe("POST /api/invitations/:id/accept", () => {
    it("atomically creates space membership and marks invitation accepted", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-accept-1', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-acc', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const req = new Request(
        "https://syntila.test/api/invitations/pinv-accept-1/accept",
        {
          method: "POST",
          headers: { authorization: "Bearer ulikoss" },
        },
      );
      const res = await handleAcceptSpaceInvitation(
        req,
        env as never,
        "pinv-accept-1",
      );
      expect(res.status).toBe(200);
      const body = (await res.json()) as Record<string, unknown>;
      expect(body).toMatchObject({
        id: "pinv-accept-1",
        spaceId: "proj-1",
        role: "collaborator",
        status: "accepted",
        accepted: true,
      });

      // Verify DB membership was created
      const membership = sqlite
        .prepare(
          "SELECT user_id, space_id, role FROM space_memberships WHERE space_id = 'proj-1' AND user_id = 'user-ulikoss'",
        )
        .get() as { user_id: string; space_id: string; role: string };
      expect(membership).toEqual({
        user_id: "user-ulikoss",
        space_id: "proj-1",
        role: "collaborator",
      });

      // Verify invitation status updated
      const invitation = sqlite
        .prepare(
          "SELECT status, accepted_by_user_id FROM space_invitations WHERE id = 'pinv-accept-1'",
        )
        .get() as { status: string; accepted_by_user_id: string };
      expect(invitation.status).toBe("accepted");
      expect(invitation.accepted_by_user_id).toBe("user-ulikoss");
    });

    it("rejects acceptance by a different authenticated user", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-wrong', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-w', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const req = new Request(
        "https://syntila.test/api/invitations/pinv-wrong/accept",
        {
          method: "POST",
          headers: { authorization: "Bearer other" },
        },
      );
      await expect(
        handleAcceptSpaceInvitation(req, env as never, "pinv-wrong"),
      ).rejects.toThrow("Invitation recipient does not match signed-in user");
    });

    it("rejects acceptance of expired invitation", async () => {
      const { sqlite, env } = createTestEnv();
      const past = new Date(Date.now() - 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-exp-acc', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-ea', 'user-vitalii', 'pending', '${past}', '${past}', '${past}');
      `);

      const req = new Request(
        "https://syntila.test/api/invitations/pinv-exp-acc/accept",
        {
          method: "POST",
          headers: { authorization: "Bearer ulikoss" },
        },
      );
      await expect(
        handleAcceptSpaceInvitation(req, env as never, "pinv-exp-acc"),
      ).rejects.toThrow("Space invitation expired");
    });
  });

  describe("POST /api/invitations/:id/decline", () => {
    it("marks invitation declined and records audit entry", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-dec-1', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-dec', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const req = new Request(
        "https://syntila.test/api/invitations/pinv-dec-1/decline",
        {
          method: "POST",
          headers: { authorization: "Bearer ulikoss" },
        },
      );
      const res = await handleDeclineSpaceInvitation(
        req,
        env as never,
        "pinv-dec-1",
      );
      expect(res.status).toBe(200);
      const body = (await res.json()) as Record<string, unknown>;
      expect(body).toMatchObject({
        id: "pinv-dec-1",
        spaceId: "proj-1",
        status: "declined",
        declined: true,
      });

      // Verify DB status
      const invitation = sqlite
        .prepare("SELECT status FROM space_invitations WHERE id = 'pinv-dec-1'")
        .get() as { status: string };
      expect(invitation.status).toBe("declined");

      // Verify audit log
      const audit = sqlite
        .prepare(
          "SELECT action, target_id FROM space_audit_log WHERE action = 'space.invitation.declined'",
        )
        .get() as { action: string; target_id: string };
      expect(audit).toMatchObject({
        action: "space.invitation.declined",
        target_id: "pinv-dec-1",
      });
    });

    it("rejects decline by non-recipient user", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-dec-wrong', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-dw', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const req = new Request(
        "https://syntila.test/api/invitations/pinv-dec-wrong/decline",
        {
          method: "POST",
          headers: { authorization: "Bearer other" },
        },
      );
      await expect(
        handleDeclineSpaceInvitation(req, env as never, "pinv-dec-wrong"),
      ).rejects.toThrow("Invitation recipient does not match signed-in user");
    });

    it("publishes realtime events for invitation lifecycle actions", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-rt-1', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-rt', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const req = new Request(
        "https://syntila.test/api/invitations/pinv-rt-1/accept",
        {
          method: "POST",
          headers: { authorization: "Bearer ulikoss" },
        },
      );
      await handleAcceptSpaceInvitation(req, env as never, "pinv-rt-1");

      const event = sqlite
        .prepare(
          "SELECT event_type, space_id, payload_json FROM realtime_events WHERE space_id = 'proj-1' ORDER BY sequence DESC LIMIT 1",
        )
        .get() as {
        event_type: string;
        space_id: string;
        payload_json: string;
      };

      expect(event).toBeDefined();
      expect(event.event_type).toBe("space.updated");
      expect(event.space_id).toBe("proj-1");
      expect(JSON.parse(event.payload_json)).toEqual({ entityId: "pinv-rt-1" });
    });
  });

  describe("End-to-End Invitation Lifecycle & Edge Cases", () => {
    it("handles new user invited before account creation, who signs in later", async () => {
      const { sqlite, env } = createTestEnv();
      const now = new Date().toISOString();
      const future = new Date(Date.now() + 86400000).toISOString();

      // Vitalii invites newuser@example.com (does not exist in users table yet)
      sqlite.exec(`
        INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-newuser', 'proj-1', 'newuser@example.com', 'collaborator', 'hash-nu', 'user-vitalii', 'pending', '${future}', '${now}', '${now}');
      `);

      // Later, user signs up / authenticates
      sqlite.exec(`
        INSERT INTO users (id, email, display_name, status, created_at, updated_at)
        VALUES ('user-new', 'newuser@example.com', 'New User', 'active', '${now}', '${now}');
      `);

      const reqAuth = new Request("https://syntila.test/api/me/invitations", {
        headers: { authorization: "Bearer newuser" },
      });
      const customEnv = {
        ...env,
        TEST_AUTHENTICATION: async () => ({
          userId: "user-new",
          user: {
            id: "user-new",
            email: "newuser@example.com",
            displayName: "New User",
            status: "active",
          },
          workspaceId: "",
          spaceRoles: {},
          sessionId: "sess-new",
          clientType: "web",
        }),
      };

      // 1. Discovery on sign-in
      const res = await handleListCurrentUserInvitations(
        reqAuth,
        customEnv as never,
      );
      expect(res.status).toBe(200);
      const data = (await res.json()) as { invitations: Array<{ id: string }> };
      expect(data.invitations).toHaveLength(1);
      expect(data.invitations[0]!.id).toBe("pinv-newuser");

      // 2. Acceptance
      const acceptReq = new Request(
        "https://syntila.test/api/invitations/pinv-newuser/accept",
        {
          method: "POST",
          headers: { authorization: "Bearer newuser" },
        },
      );
      const acceptRes = await handleAcceptSpaceInvitation(
        acceptReq,
        customEnv as never,
        "pinv-newuser",
      );
      expect(acceptRes.status).toBe(200);

      // Verify membership
      const member = sqlite
        .prepare(
          "SELECT user_id, role FROM space_memberships WHERE space_id = 'proj-1' AND user_id = 'user-new'",
        )
        .get() as { user_id: string; role: string };
      expect(member).toEqual({ user_id: "user-new", role: "collaborator" });
    });

    it("prevents duplicate pending invitation to the same email", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-dup-1', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-d1', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const req = new Request(
        "https://syntila.test/api/spaces/proj-1/invitations",
        {
          method: "POST",
          headers: {
            authorization: "Bearer vitalii",
            "content-type": "application/json",
          },
          body: JSON.stringify({
            email: "ulikossnokia@gmail.com",
            role: "collaborator",
          }),
        },
      );

      const { handleCreateSpaceInvitation } =
        await import("../../src/domain/routes/spaces.js");
      await expect(
        handleCreateSpaceInvitation(req, env as never, "proj-1"),
      ).rejects.toThrow("A pending invitation already exists for this user");
    });

    it("prevents self invitations", async () => {
      const { env } = createTestEnv();
      const req = new Request(
        "https://syntila.test/api/spaces/proj-1/invitations",
        {
          method: "POST",
          headers: {
            authorization: "Bearer vitalii",
            "content-type": "application/json",
          },
          body: JSON.stringify({
            email: "vitalii@nohainc.com",
            role: "collaborator",
          }),
        },
      );

      const { handleCreateSpaceInvitation } =
        await import("../../src/domain/routes/spaces.js");
      await expect(
        handleCreateSpaceInvitation(req, env as never, "proj-1"),
      ).rejects.toThrow("You cannot invite yourself");
    });

    it("handles simultaneous accept and revoke race conditions", async () => {
      const { sqlite, env } = createTestEnv();
      const future = new Date(Date.now() + 86400000).toISOString();

      sqlite.exec(`
        INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
        VALUES ('pinv-race-1', 'proj-1', 'ulikossnokia@gmail.com', 'collaborator', 'hash-rc', 'user-vitalii', 'pending', '${future}', '${future}', '${future}');
      `);

      const { handleExpireSpaceInvitation } =
        await import("../../src/domain/routes/spaces.js");

      // Case A: Revoke happens first
      const revokeReq = new Request(
        "https://syntila.test/api/spaces/proj-1/invitations/pinv-race-1/expire",
        {
          method: "POST",
          headers: { authorization: "Bearer vitalii" },
        },
      );
      const revokeRes = await handleExpireSpaceInvitation(
        revokeReq,
        env as never,
        "proj-1",
        "pinv-race-1",
      );
      expect(revokeRes.status).toBe(200);

      // Subsequent accept attempt fails
      const acceptReq = new Request(
        "https://syntila.test/api/invitations/pinv-race-1/accept",
        {
          method: "POST",
          headers: { authorization: "Bearer ulikoss" },
        },
      );
      await expect(
        handleAcceptSpaceInvitation(acceptReq, env as never, "pinv-race-1"),
      ).rejects.toThrow("Space invitation not found");
    });
  });
});
