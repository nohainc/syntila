import { deleteAccountAvatars } from "../../src/domain/avatar-storage.js";
import { afterEach, beforeEach, describe, expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { handleGetAvatar, handleUploadAvatar } from "../../src/domain/routes/profile.js";
import type { SecurityEnv } from "../../src/domain/routes/http-security.js";

class MemoryAvatarBucket {
  readonly values = new Map<string, { bytes: Uint8Array; mediaType: string }>();

  async put(
    key: string,
    body: ArrayBuffer,
    options: { httpMetadata?: { contentType?: string } },
  ) {
    this.values.set(key, {
      bytes: new Uint8Array(body),
      mediaType:
        options.httpMetadata?.contentType ?? "application/octet-stream",
    });
  }

  async list({ prefix }: { prefix: string }) {
    return {
      objects: [...this.values.keys()]
        .filter((key) => key.startsWith(prefix))
        .map((key) => ({ key })),
      truncated: false,
    };
  }

  async get(key: string) {
    const value = this.values.get(key);
    if (!value) return null;
    return {
      body: new Response(value.bytes.buffer as ArrayBuffer).body!,
      httpMetadata: { contentType: value.mediaType },
      httpEtag: `"${key}"`,
    };
  }

  async delete(key: string | string[]) {
    for (const item of Array.isArray(key) ? key : [key])
      this.values.delete(item);
  }
}

describe("profile avatars", () => {
  let store: ReturnType<typeof sqliteD1>;
  let bucket: MemoryAvatarBucket;
  let env: SecurityEnv;

  beforeEach(() => {
    store = sqliteD1();
    store.sqlite.exec(
      `INSERT INTO users(id,email,display_name,created_at,updated_at)
       VALUES ('a','a@test','Alice','now','now'),('b','b@test','Bob','now','now')`,
    );
    bucket = new MemoryAvatarBucket();
    env = {
      SYNTILA_DB: store.db,
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_ARTIFACTS: bucket as never,
      TEST_AUTHENTICATION: async (request: Request) => ({
        userId: request.headers.get("authorization") ?? "",
      }),
    } as unknown as SecurityEnv;
  });

  afterEach(() => store.sqlite.close());

  function uploadBody(type = "image/png") {
    const form = new FormData();
    form.set(
      "original",
      new File([new Uint8Array([9, 8, 7, 6])], "original", { type }),
    );
    form.set(
      "thumbnail",
      new File([new Uint8Array([1, 2, 3])], "thumbnail", { type: "image/png" }),
    );
    return form;
  }

  const request = (
    userId: string,
    init: RequestInit = {},
    url = "https://syntila.test/api/profile/avatar",
  ) =>
    (() => {
      const headers = new Headers(init.headers);
      headers.set("authorization", userId);
      return new Request(url, { ...init, headers });
    })();

  it("stores the avatar privately and serves it to the owner", async () => {
    const upload = await handleUploadAvatar(
      request("a", {
        method: "PUT",
        body: uploadBody(),
      }),
      env,
    );
    expect(upload.status).toBe(200);
    expect(bucket.values.size).toBe(2);
    expect(
      [...bucket.values.entries()].find(([key]) =>
        key.endsWith("-original"),
      )?.[1].bytes,
    ).toEqual(new Uint8Array([9, 8, 7, 6]));
    const payload = (await upload.json()) as { avatarUrl: string };
    expect(payload.avatarUrl).toMatch(
      /^https:\/\/syntila\.test\/api\/users\/a\/avatar\?v=[0-9a-f-]+$/,
    );
    expect(
      store.sqlite.prepare("SELECT avatar_url FROM users WHERE id='a'").get(),
    ).toMatchObject({ avatar_url: expect.stringMatching(/^r2:\/\//) });

    const avatar = await handleGetAvatar(
      request("a", {}, payload.avatarUrl),
      env,
      "a",
    );
    expect(avatar.status).toBe(200);
    expect(avatar.headers.get("content-type")).toBe("image/png");
    expect([...new Uint8Array(await avatar.arrayBuffer())]).toEqual([1, 2, 3]);
  });

  it("replaces both files and rejects missing variants without changing storage", async () => {
    await handleUploadAvatar(
      request("a", { method: "PUT", body: uploadBody() }),
      env,
    );
    const oldKeys = [...bucket.values.keys()];
    await handleUploadAvatar(
      request("a", { method: "PUT", body: uploadBody() }),
      env,
    );
    expect(bucket.values.size).toBe(2);
    for (const key of oldKeys) expect(bucket.values.has(key)).toBe(false);
    await expect(
      handleUploadAvatar(
        request("a", { method: "PUT", body: new FormData() }),
        env,
      ),
    ).rejects.toMatchObject({ status: 400 });
    expect(bucket.values.size).toBe(2);
  });

  it("deletes all account variants and leftovers without touching other accounts", async () => {
    await handleUploadAvatar(
      request("a", { method: "PUT", body: uploadBody() }),
      env,
    );
    await bucket.put(
      "user-avatars/a/interrupted-original",
      new ArrayBuffer(1),
      {},
    );
    await bucket.put("user-avatars/b/retained", new ArrayBuffer(1), {});
    await deleteAccountAvatars(bucket as never, "a");
    expect([...bucket.values.keys()]).toEqual(["user-avatars/b/retained"]);
  });

  it("rolls back both files when persistence fails", async () => {
    store.sqlite.exec(
      "CREATE TRIGGER fail_avatar BEFORE UPDATE ON users BEGIN SELECT RAISE(ABORT, 'failed'); END",
    );
    await expect(
      handleUploadAvatar(
        request("a", { method: "PUT", body: uploadBody() }),
        env,
      ),
    ).rejects.toThrow();
    expect(bucket.values.size).toBe(0);
  });

  it("does not expose avatars to unrelated users", async () => {
    await handleUploadAvatar(
      request("a", {
        method: "PUT",
        body: uploadBody("image/jpeg"),
      }),
      env,
    );
    await expect(
      handleGetAvatar(
        request("b", {}, "https://syntila.test/api/users/a/avatar"),
        env,
        "a",
      ),
    ).rejects.toMatchObject({ status: 404 });

    store.sqlite.exec(
      "INSERT INTO people_relationships(user_low_id,user_high_id,established_at) VALUES ('a','b','now')",
    );
    const shared = await handleGetAvatar(
      request("b", {}, "https://syntila.test/api/users/a/avatar"),
      env,
      "a",
    );
    expect(shared.status).toBe(200);
  });
});
