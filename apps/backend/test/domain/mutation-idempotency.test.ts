import { hashToken } from "@syntila/security";
import { testTokens } from "./helpers/tokens";
import { describe, expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { MutationIdempotency } from "../../src/domain/routes/mutation-idempotency.js";
import {
  handleCreateSpace,
  handleCreateThread,
  handleCreateDiscussionMessage,
} from "../../src/domain/routes/handlers.js";
import type { SecurityEnv } from "../../src/domain/routes/handlers.js";

const key = "client-operation-000000001";
function request(body: unknown, idempotencyKey = key) {
  return new Request("https://cloud.test/api/resource", {
    method: "POST",
    headers: { "Idempotency-Key": idempotencyKey },
    body: JSON.stringify(body),
  });
}
function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES
    ('owner','owner@test','Owner','now','now'), ('other','other@test','Other','now','now')`);
  const env = {
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_DB: db,
    TEST_AUTHENTICATION: async () => ({
      userId: "owner",
      user: {
        id: "owner",
        email: "owner@test",
        displayName: "Owner",
        status: "active",
      },
      workspaceId: "",
      spaceRoles: {},
      sessionId: "session",
      clientType: "web",
    }),
  } as unknown as SecurityEnv;
  return { sqlite, db, env };
}
describe("durable mutation receipts", () => {
  it("canonicalizes object order, scopes by user/endpoint, rejects changed input and malformed keys", async () => {
    const f = fixture();
    const receipt = (await MutationIdempotency.from(
      request({ a: 1, b: 2 }),
      f.db,
      "owner",
      "scope",
      { a: 1, b: 2 },
    ))!;
    await receipt.commit({ id: "one" }, 201, (statements) =>
      f.db.batch(statements),
    );
    const same = (await MutationIdempotency.from(
      request({ b: 2, a: 1 }),
      f.db,
      "owner",
      "scope",
      { b: 2, a: 1 },
    ))!;
    expect(await (await same.replay())!.json()).toEqual({ id: "one" });
    for (const [user, scope] of [
      ["other", "scope"],
      ["owner", "another"],
    ]) {
      expect(
        await (await MutationIdempotency.from(
          request({ a: 1, b: 2 }),
          f.db,
          user!,
          scope!,
          { a: 1, b: 2 },
        ))!.replay(),
      ).toBeNull();
    }
    await expect(
      (await MutationIdempotency.from(
        request({ a: 3 }),
        f.db,
        "owner",
        "scope",
        { a: 3 },
      ))!.replay(),
    ).rejects.toMatchObject({ status: 409 });
    await expect(
      MutationIdempotency.from(
        request({}, "short"),
        f.db,
        "owner",
        "scope",
        {},
      ),
    ).rejects.toMatchObject({ status: 400 });
    f.sqlite.close();
  });
  it("rolls back domain writes and the receipt together on a failed batch", async () => {
    const f = fixture();
    const receipt = (await MutationIdempotency.from(
      request({}),
      f.db,
      "owner",
      "scope",
      {},
    ))!;
    await expect(
      receipt.commit({ id: "one" }, 201, (statements) =>
        f.db.batch([
          ...statements,
          f.db
            .prepare(
              "INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES(?,?,?,?,?)",
            )
            .bind("P", "missing-user", "Space", "now", "now"),
        ]),
      ),
    ).rejects.toThrow();
    expect(await receipt.replay()).toBeNull();
    expect(f.sqlite.prepare("SELECT count(*) AS n FROM spaces").get()?.n).toBe(
      0,
    );
    await receipt.commit({ id: "one" }, 201, (statements) =>
      f.db.batch(statements),
    );
    expect(await receipt.replay()).not.toBeNull();
    f.sqlite.close();
  });
  it("concurrent lost-response retries create one Thread, one Discussion and one event each", async () => {
    const f = fixture();
    const p = (
      (await (
        await handleCreateSpace(
          new Request("https://cloud.test/spaces", {
            method: "POST",
            body: JSON.stringify({ name: "Space" }),
          }),
          f.env,
        )
      ).json()) as { space: { id: string } }
    ).space.id;
    const responses = await Promise.all(
      Array.from({ length: 5 }, () =>
        handleCreateThread(request({ name: "Stream" }), f.env, p),
      ),
    );
    const bodies = (await Promise.all(responses.map((r) => r.json()))) as {
      thread: { id: string };
    }[];
    expect(new Set(bodies.map((b) => b.thread.id)).size).toBe(1);
    expect(responses.every((r) => r.status === 201)).toBe(true);
    const w = bodies[0]!.thread.id;
    const chats = await Promise.all(
      Array.from({ length: 5 }, () =>
        handleCreateDiscussionMessage(request({ body: "Hello" }), f.env, w),
      ),
    );
    const messages = (await Promise.all(chats.map((r) => r.json()))) as {
      message: { id: string };
    }[];
    expect(new Set(messages.map((b) => b.message.id)).size).toBe(1);
    expect(
      f.sqlite.prepare("SELECT count(*) AS n FROM discussion_messages").get()
        ?.n,
    ).toBe(1);
    expect(
      f.sqlite
        .prepare(
          "SELECT count(*) AS n FROM realtime_events WHERE event_type='discussion.created'",
        )
        .get()?.n,
    ).toBe(1);
    await expect(
      handleCreateThread(request({ name: "Changed" }), f.env, p),
    ).rejects.toMatchObject({ status: 409 });
    await expect(
      handleCreateDiscussionMessage(request({ body: "Changed" }), f.env, w),
    ).rejects.toMatchObject({ status: 409 });
    // Receipt survives deletion; retry cannot resurrect user data.
    f.sqlite
      .prepare("DELETE FROM discussion_messages WHERE id=?")
      .run(messages[0]!.message.id);
    expect(
      (
        await handleCreateDiscussionMessage(
          request({ body: "Hello" }),
          f.env,
          w,
        )
      ).status,
    ).toBe(201);
    expect(
      f.sqlite.prepare("SELECT count(*) AS n FROM discussion_messages").get()
        ?.n,
    ).toBe(0);
    f.sqlite.close();
  });
  it("rechecks authorization before disclosing a stored response", async () => {
    const f = fixture();
    const p = (
      (await (
        await handleCreateSpace(
          new Request("https://cloud.test/spaces", {
            method: "POST",
            body: JSON.stringify({ name: "Space" }),
          }),
          f.env,
        )
      ).json()) as { space: { id: string } }
    ).space.id;
    const token = await (await testTokens())("owner", { email: "owner@test" });
    const env: SecurityEnv = { ...f.env, TEST_AUTHENTICATION: undefined };
    const authorized = () => {
      const r = request({ name: "Stream" });
      r.headers.set("authorization", `Bearer ${token}`);
      return r;
    };
    await handleCreateThread(authorized(), env, p);
    f.sqlite.prepare("DELETE FROM space_memberships WHERE space_id=?").run(p);
    await expect(
      handleCreateThread(authorized(), env, p),
    ).rejects.toMatchObject({ status: 404 });
    f.sqlite.close();
  });
});
