import { describe, expect, it, vi } from "./helpers/vitest-compat";
import {
  sendSpaceInvitationEmail,
  resolveAppUrl,
} from "../../src/domain/invitation-email.js";
import { handleCreateSpaceInvitation } from "../../src/domain/routes/spaces.js";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

describe("Invitation Email Delivery", () => {
  it("resolves app URL from SYNTILA_APP_URL, BETTER_AUTH_URL, or request URL", () => {
    const req = new Request(
      "https://syntila.internal/api/spaces/proj-1/invitations",
    );
    expect(
      resolveAppUrl(req, {
        SYNTILA_APP_URL: "https://app.syntila.dev/",
      } as never),
    ).toBe("https://app.syntila.dev");
    expect(
      resolveAppUrl(req, {
        BETTER_AUTH_URL: "https://auth.syntila.dev/",
      } as never),
    ).toBe("https://auth.syntila.dev");
    expect(resolveAppUrl(req, {} as never)).toBe("https://syntila.internal");
  });

  it("sends formatted email via SYNTILA_EMAIL binding", async () => {
    const sentEmails: Array<{
      to: string;
      from: { email: string; name: string };
      subject: string;
      text: string;
      html: string;
    }> = [];

    const mockEmail = {
      send: vi.fn(async (msg: unknown) => {
        sentEmails.push(msg as (typeof sentEmails)[0]);
      }),
    };

    const env = {
      SYNTILA_EMAIL: mockEmail,
      SYNTILA_EMAIL_FROM: "invitations@conclaveax.com",
    };

    const ok = await sendSpaceInvitationEmail(env as never, {
      recipientEmail: "ulikossnokia@gmail.com",
      inviterName: "Vitalii Noha",
      spaceName: "Syntila Development",
      role: "collaborator",
      appUrl: "https://app.syntila.dev/?invitation=pinv-123",
    });

    expect(ok).toBe(true);
    expect(mockEmail.send).toHaveBeenCalledOnce();
    const sent = sentEmails[0]!;
    expect(sent).toMatchObject({
      to: "ulikossnokia@gmail.com",
      from: {
        email: "invitations@conclaveax.com",
        name: "Syntila",
      },
      subject: "Vitalii Noha invited you to Syntila Development",
    });
    expect(sent.text).toContain(
      'Vitalii Noha invited you to join "Syntila Development" as a collaborator on Syntila.',
    );
    expect(sent.text).toContain("https://app.syntila.dev/?invitation=pinv-123");
    expect(sent.text).toContain(
      "Sign in with ulikossnokia@gmail.com to accept.",
    );
    expect(sent.html).toContain("<strong>Vitalii Noha</strong>");
    expect(sent.html).toContain("<strong>Syntila Development</strong>");
    expect(sent.html).toContain(
      'href="https://app.syntila.dev/?invitation=pinv-123"',
    );
  });

  it("rejects markup in recipient addresses before delivery", async () => {
    const mockEmail = {
      send: vi.fn(async (_msg: unknown) => undefined),
    };

    const env = {
      SYNTILA_EMAIL: mockEmail,
    };

    await sendSpaceInvitationEmail(env as never, {
      recipientEmail: "malicious<script>@example.com",
      inviterName: "<script>alert('xss')</script>",
      spaceName: "Space <img src=x onerror=alert(1)>",
      role: "viewer",
      appUrl: "https://app.syntila.dev/?invitation=pinv-xss",
    });

    expect(mockEmail.send).not.toHaveBeenCalled();
  });

  it("returns false when production delivery is unavailable", async () => {
    await expect(
      sendSpaceInvitationEmail({ SYNTILA_ENVIRONMENT: "production" } as never, {
        recipientEmail: "person@example.com",
        inviterName: "Vitalii Noha",
        spaceName: "Syntila",
        role: "collaborator",
        appUrl: "https://app.syntila.dev",
      }),
    ).resolves.toBe(false);
  });

  it("uses the fallback once for an explicit sender rejection", async () => {
    const send = vi
      .fn()
      .mockRejectedValueOnce({ code: "E_SENDER_NOT_VERIFIED" })
      .mockResolvedValueOnce({ messageId: "message-2" });
    const ok = await sendSpaceInvitationEmail(
      { SYNTILA_EMAIL: { send } } as never,
      {
        recipientEmail: "person@example.com",
        inviterName: "Vitalii Noha",
        spaceName: "Syntila",
        role: "collaborator",
        appUrl: "https://app.syntila.dev",
      },
    );

    expect(ok).toBe(true);
    expect(send).toHaveBeenCalledTimes(2);
    expect(send.mock.calls[1]?.[0]).toMatchObject({
      from: { email: "vitalii@conclaveax.com", name: "Syntila" },
    });
  });

  it("does not expose raw provider details in delivery logs", async () => {
    const error = new Error(
      "token=reset-secret https://app.syntila.test/reset?token=secret body=private message",
    );
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      await expect(
        sendSpaceInvitationEmail(
          {
            SYNTILA_EMAIL: {
              send: vi.fn().mockRejectedValue(error),
            },
          } as never,
          {
            recipientEmail: "person@example.com",
            inviterName: "Vitalii Noha",
            spaceName: "Syntila",
            role: "collaborator",
            appUrl: "https://app.syntila.dev",
          },
        ),
      ).resolves.toBe(false);
      const output = log.mock.calls.flat().map(String).join(" ");
      expect(output).not.toContain("reset-secret");
      expect(output).not.toContain("https://app.syntila.test/reset");
      expect(output).not.toContain("private message");
    } finally {
      log.mockRestore();
    }
  });

  it("sends email and creates invitation on handleCreateSpaceInvitation", async () => {
    const { sqlite, db } = sqliteD1();
    const now = new Date().toISOString();

    sqlite.exec(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at)
      VALUES ('user-vitalii', 'vitalii@nohainc.com', 'Vitalii Noha', 'active', '${now}', '${now}');
      INSERT INTO spaces (id, name, owner_user_id, created_at, updated_at)
      VALUES ('proj-1', 'Syntila Development', 'user-vitalii', '${now}', '${now}');
      INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at)
      VALUES ('pm-1', 'proj-1', 'user-vitalii', 'owner', '${now}', '${now}');
    `);

    const sentEmails: unknown[] = [];
    const env = {
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: db,
      SYNTILA_APP_URL: "https://app.syntila.dev",
      SYNTILA_EMAIL: {
        send: vi.fn(async (msg: unknown) => {
          sentEmails.push(msg);
        }),
      },
      TEST_AUTHENTICATION: async () => ({
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
      }),
    };

    const req = new Request(
      "https://syntila.internal/api/spaces/proj-1/invitations",
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

    const res = await handleCreateSpaceInvitation(req, env as never, "proj-1");
    expect(res.status).toBe(201);
    expect(sentEmails).toHaveLength(1);
    expect(sentEmails[0]).toMatchObject({
      to: "ulikossnokia@gmail.com",
      subject: "Vitalii Noha invited you to Syntila Development",
      from: {
        email: "syntila@conclaveax.com",
        name: "Syntila",
      },
    });
  });

  it("keeps a pending invitation when email delivery is rejected", async () => {
    const { sqlite, db } = sqliteD1();
    const now = new Date().toISOString();

    sqlite.exec(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at)
      VALUES ('user-vitalii', 'vitalii@nohainc.com', 'Vitalii Noha', 'active', '${now}', '${now}');
      INSERT INTO spaces (id, name, owner_user_id, created_at, updated_at)
      VALUES ('proj-1', 'Syntila Development', 'user-vitalii', '${now}', '${now}');
      INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at)
      VALUES ('pm-1', 'proj-1', 'user-vitalii', 'owner', '${now}', '${now}');
    `);

    const env = {
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: db,
      SYNTILA_APP_URL: "https://app.syntila.dev",
      SYNTILA_EMAIL: {
        send: vi.fn().mockRejectedValue({ code: "E_RECIPIENT_NOT_ALLOWED" }),
      },
      TEST_AUTHENTICATION: async () => ({
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
      }),
    };

    const req = new Request(
      "https://syntila.internal/api/spaces/proj-1/invitations",
      {
        method: "POST",
        headers: {
          authorization: "Bearer vitalii",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          email: "person@example.com",
          role: "collaborator",
        }),
      },
    );

    const res = await handleCreateSpaceInvitation(req, env as never, "proj-1");
    expect(res.status).toBe(201);
    const invitation = await db
      .prepare(
        "SELECT status FROM space_invitations WHERE space_id = ?1 AND email = ?2",
      )
      .bind("proj-1", "person@example.com")
      .first<{ status: string }>();
    expect(invitation).toEqual({ status: "pending" });
  });
});
