import { describe, expect, it } from "vitest";
import { handleProfileAvatarSync } from "../src/email-relay.js";

async function signBody(secret: string, body: string, ts = Math.floor(Date.now() / 1000).toString()) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = Buffer.from(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${ts}.${body}`)),
  ).toString("base64url");
  return { ts, sig };
}

describe("handleProfileAvatarSync", () => {
  it("updates users.avatar_url in D1 when signed with EMAIL_RELAY_SECRET", async () => {
    const updates: Array<{ avatarUrl: unknown; userId: unknown }> = [];
    const fakeDb = {
      prepare(sql: string) {
        expect(sql).toContain("UPDATE users SET avatar_url");
        return {
          bind(avatarUrl: unknown, _updatedAt: unknown, userId: unknown) {
            return {
              async run() {
                updates.push({ avatarUrl, userId });
                return { meta: { changes: 1 } };
              },
            };
          },
        };
      },
    } as unknown as D1Database;

    const body = JSON.stringify({
      userId: "user-123",
      avatarUrl: "r2://user-avatars/user-123/uuid-1-thumbnail",
    });
    const secret = "relay-secret-123";
    const { ts, sig } = await signBody(secret, body);

    const response = await handleProfileAvatarSync(
      new Request("https://app.syntila.app/api/internal/profile-avatar", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-syntila-timestamp": ts,
          "x-syntila-signature": sig,
        },
        body,
      }),
      { EMAIL_RELAY_SECRET: secret, SYNTILA_DB: fakeDb },
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, updated: true });
    expect(updates).toEqual([
      {
        userId: "user-123",
        avatarUrl: "r2://user-avatars/user-123/uuid-1-thumbnail",
      },
    ]);
  });

  it("rejects requests with an invalid signature", async () => {
    const fakeDb = {} as D1Database;
    const body = JSON.stringify({
      userId: "user-123",
      avatarUrl: "r2://user-avatars/user-123/uuid-1-thumbnail",
    });
    const ts = Math.floor(Date.now() / 1000).toString();

    const response = await handleProfileAvatarSync(
      new Request("https://app.syntila.app/api/internal/profile-avatar", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-syntila-timestamp": ts,
          "x-syntila-signature": "invalid-sig",
        },
        body,
      }),
      { EMAIL_RELAY_SECRET: "relay-secret-123", SYNTILA_DB: fakeDb },
    );

    expect(response.status).toBe(401);
  });
});
