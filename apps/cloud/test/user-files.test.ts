import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { beforeEach, describe, expect, it, vi } from "vitest";

let userId = "owner";
vi.mock("../src/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: async () => ({
    context: { userId },
    spaceId: "space",
  }),
}));
vi.mock("../src/routes/http-security.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeRequest: async () => ({ userId }),
}));

import {
  handleUploadWorkRequestFile,
  workRequestFileKey,
} from "../src/routes/work-request-files.js";
import {
  handleDeleteUserFile,
  handleDownloadUserFile,
  handleSyncUserFiles,
  handleListUserFiles,
  pruneOrphanUserFiles,
} from "../src/routes/user-files.js";

function fixture() {
  const sqlite = new DatabaseSync(":memory:");
  sqlite.exec(`CREATE TABLE users(id TEXT PRIMARY KEY);
    INSERT INTO users VALUES ('owner'), ('other');
    CREATE TABLE threads(id TEXT, space_id TEXT, name TEXT);
    INSERT INTO threads VALUES ('thread', 'space', 'Plan');
    CREATE TABLE spaces(id TEXT, name TEXT);
    INSERT INTO spaces VALUES ('space', 'Team');
    CREATE TABLE space_memberships(space_id TEXT, user_id TEXT);
    INSERT INTO space_memberships VALUES ('space', 'owner');
    CREATE TABLE discussion_messages(thread_id TEXT, attachments_json TEXT NOT NULL DEFAULT '[]');
    CREATE TABLE work_requests(thread_id TEXT, input_json TEXT);`);
  sqlite.exec(
    readFileSync(
      new URL("../migrations-v8/0086_user_files.sql", import.meta.url),
      "utf8",
    ),
  );
  for (const migration of [
    "0094_account_plans.sql",
    "0098_user_file_reservations.sql",
  ])
    sqlite.exec(
      readFileSync(
        new URL(`../migrations-v8/${migration}`, import.meta.url),
        "utf8",
      ),
    );
  const db = {
    async batch(statements: { run(): Promise<unknown> }[]) {
      const results = [];
      for (const statement of statements) results.push(await statement.run());
      return results;
    },
    prepare(sql: string) {
      let values: unknown[] = [];
      return {
        bind(...args: unknown[]) {
          values = args;
          return this;
        },
        async run() {
          return sqlite.prepare(sql).run(...(values as []));
        },
        async first() {
          return sqlite.prepare(sql).get(...(values as [])) ?? null;
        },
        async all() {
          return { results: sqlite.prepare(sql).all(...(values as [])) };
        },
      };
    },
  };
  const objects = new Map<string, Uint8Array>();
  const metadata = new Map<
    string,
    {
      customMetadata?: Record<string, string>;
      httpMetadata?: { contentType?: string };
    }
  >();
  const bucket = {
    async get(key: string) {
      const value = objects.get(key);
      return value
        ? {
            body: new Blob([new Uint8Array(value)]).stream(),
            ...metadata.get(key),
          }
        : null;
    },
    async head(key: string) {
      const value = objects.get(key);
      return value
        ? {
            key,
            size: value.byteLength,
            uploaded: new Date("2026-01-01"),
            ...metadata.get(key),
          }
        : null;
    },
    async list({ cursor }: { cursor?: string }) {
      const keys = [...objects.keys()]
        .sort()
        .filter((key) => !cursor || key > cursor);
      const page = keys.slice(0, 1);
      return {
        objects: await Promise.all(page.map((key) => this.head(key))),
        truncated: keys.length > 1,
        cursor: page.at(-1),
      };
    },
    async put(
      key: string,
      value: ArrayBuffer | string,
      options?: {
        customMetadata?: Record<string, string>;
        httpMetadata?: { contentType?: string };
      },
    ) {
      metadata.set(key, options ?? {});
      objects.set(
        key,
        typeof value === "string"
          ? new TextEncoder().encode(value)
          : new Uint8Array(value),
      );
    },
    async delete(keys: string | string[]) {
      for (const key of [keys].flat()) objects.delete(key);
    },
  };
  const env = { SYNTILA_DB: db, SYNTILA_ARTIFACTS: bucket } as never;
  async function upload(text = "hello") {
    return handleUploadWorkRequestFile(
      new Request(
        "https://test/api/threads/thread/work-request-files?name=a.bin",
        {
          method: "POST",
          headers: {
            "content-type": "application/octet-stream",
            "content-length": String(new TextEncoder().encode(text).byteLength),
          },
          body: text,
        },
      ),
      env,
      "thread",
    );
  }
  async function list() {
    const response = await handleListUserFiles(
      new Request("https://test/api/files"),
      env,
    );
    return (await response.json()) as {
      files: {
        fileId: string;
        sizeBytes: number;
        inUse: boolean;
        threadName: string | null;
      }[];
      usage: { usedBytes: number; fileCount: number; quotaBytes: number };
    };
  }
  return { sqlite, env, objects, upload, list, bucket };
}

beforeEach(() => {
  userId = "owner";
});

describe("My Files", () => {
  it("reconciles paginated storage, recovers legacy uploads and removes only missing owned records", async () => {
    const { sqlite, env, upload, list, objects } = fixture();
    for (const text of ["one", "two", "three"]) await upload(text);
    const files = (await list()).files;
    const missing = files[0]!.fileId;
    const legacy = files[1]!.fileId;
    const resized = files[2]!.fileId;
    sqlite.prepare("DELETE FROM user_files WHERE id = ?").run(legacy);
    objects.delete(workRequestFileKey(missing));
    objects.set(workRequestFileKey(resized), new Uint8Array(12));
    userId = "other";
    await upload("private");
    const other = (await list()).files[0]!.fileId;
    objects.delete(workRequestFileKey(other));
    userId = "owner";
    let next: { phase: string; cursor?: string } | null = { phase: "storage" };
    let batches = 0;
    while (next) {
      const response = await handleSyncUserFiles(
        new Request(
          `https://test/api/files/sync?${new URLSearchParams(next)}`,
          { method: "POST" },
        ),
        env,
      );
      next = ((await response.json()) as { next: typeof next }).next;
      batches++;
    }
    expect(batches).toBeGreaterThan(2);
    const result = await list();
    expect(result.files.map((f) => f.fileId).sort()).toEqual(
      [legacy, resized].sort(),
    );
    expect(result.usage.usedBytes).toBe(
      objects.get(workRequestFileKey(legacy))!.byteLength + 12,
    );
    expect(
      sqlite.prepare("SELECT id FROM user_files WHERE id = ?").get(other),
    ).toBeTruthy();
    expect(objects.has(workRequestFileKey(legacy))).toBe(true);
    await handleSyncUserFiles(
      new Request("https://test/api/files/sync", { method: "POST" }),
      env,
    );
    expect((await list()).usage).toEqual(result.usage);
  });

  it("continues record batches without skipping rows removed in earlier batches", async () => {
    const { sqlite, env, list } = fixture();
    for (let i = 0; i < 51; i++) {
      sqlite
        .prepare(
          `INSERT INTO user_files VALUES (?, 'owner', 'thread', 'space', 'missing', 'x', 1, '2026-01-01')`,
        )
        .run(`wrf-${crypto.randomUUID()}`);
    }
    const first = await handleSyncUserFiles(
      new Request("https://test/api/files/sync?phase=records", {
        method: "POST",
      }),
      env,
    );
    const { next } = (await first.json()) as {
      next: { phase: string; cursor: string };
    };
    expect((await list()).usage.fileCount).toBe(1);
    const last = await handleSyncUserFiles(
      new Request(`https://test/api/files/sync?${new URLSearchParams(next)}`, {
        method: "POST",
      }),
      env,
    );
    expect(((await last.json()) as { next: unknown }).next).toBeNull();
    expect((await list()).usage.fileCount).toBe(0);
  });

  it("does not prune records when storage reads fail", async () => {
    const { env, upload, list, bucket } = fixture();
    await upload();
    bucket.head = async () => {
      throw new Error("Storage unavailable");
    };
    await expect(
      handleSyncUserFiles(
        new Request("https://test/api/files/sync?phase=records", {
          method: "POST",
        }),
        env,
      ),
    ).rejects.toThrow("Storage unavailable");
    expect((await list()).usage.fileCount).toBe(1);
  });

  it("counts each user's uploads and lists only the caller's files", async () => {
    const { upload, list } = fixture();
    expect((await upload("hello")).status).toBe(201);
    expect((await upload("abc")).status).toBe(201);
    const mine = await list();
    expect(mine.usage).toEqual({
      usedBytes: 8,
      fileCount: 2,
      reservedBytes: 0,
      quotaBytes: 1_000_000_000,
      maxFileBytes: 25_000_000,
    });
    expect(mine.files.map((file) => file.sizeBytes).sort()).toEqual([3, 5]);
    expect(mine.files[0]!.threadName).toBe("Plan");
    userId = "other";
    expect((await list()).usage.fileCount).toBe(0);
  });

  it("rejects an upload that would exceed the total quota", async () => {
    const { sqlite, upload, objects } = fixture();
    sqlite
      .prepare(
        `INSERT INTO user_files VALUES ('wrf-x', 'owner', 'thread', 'space', 'big', 'x', ?, '2026-01-01')`,
      )
      .run(1_000_000_000 - 4);
    await expect(upload("hello")).rejects.toMatchObject({
      status: 413,
      code: "storage_quota_exceeded",
    });
    expect(objects.size).toBe(0);
    expect((await upload("abcd")).status).toBe(201);
  });

  it("downloads owned bytes with safe attachment headers and hides unavailable files", async () => {
    const { upload, env, objects, sqlite } = fixture();
    const { file } = (await (await upload("hello")).json()) as {
      file: { fileId: string };
    };
    sqlite
      .prepare("UPDATE user_files SET name = ? WHERE id = ?")
      .run('a"\r\né.txt', file.fileId);
    const download = (id = file.fileId) =>
      handleDownloadUserFile(
        new Request(`https://test/api/files/${id}`),
        env,
        id,
      );
    const response = await download();
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("hello");
    expect(response.headers.get("content-type")).toBe(
      "application/octet-stream",
    );
    expect(response.headers.get("content-disposition")).toBe(
      "attachment; filename=\"a____.txt\"; filename*=UTF-8''a%22%0D%0A%C3%A9.txt",
    );
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    userId = "other";
    await expect(download()).rejects.toMatchObject({ status: 404 });
    userId = "owner";
    await expect(download("invalid")).rejects.toMatchObject({ status: 404 });
    sqlite.prepare("DELETE FROM user_files WHERE id = ?").run(file.fileId);
    await expect(download()).rejects.toMatchObject({ status: 404 });
    sqlite
      .prepare(
        "INSERT INTO user_files VALUES (?, 'owner', 'thread', 'space', 'a', 'text/plain', 5, '2026-01-01')",
      )
      .run(file.fileId);
    objects.delete(workRequestFileKey(file.fileId));
    await expect(download()).rejects.toMatchObject({ status: 404 });
  });

  it("lets only the owner delete a file, freeing its bytes and quota", async () => {
    const { upload, list, env, objects } = fixture();
    const { file } = (await (await upload()).json()) as {
      file: { fileId: string };
    };
    const remove = () =>
      handleDeleteUserFile(
        new Request(`https://test/api/files/${file.fileId}`, {
          method: "DELETE",
        }),
        env,
        file.fileId,
      );
    userId = "other";
    await expect(remove()).rejects.toThrow("File not found");
    userId = "owner";
    expect((await remove()).status).toBe(200);
    expect(objects.has(workRequestFileKey(file.fileId))).toBe(false);
    expect((await list()).usage.usedBytes).toBe(0);
  });

  it("prunes day-old uploads that nothing references and keeps cited ones", async () => {
    const { sqlite, upload, list, env } = fixture();
    const ids: string[] = [];
    for (const text of ["one", "two"])
      ids.push(
        ((await (await upload(text)).json()) as { file: { fileId: string } })
          .file.fileId,
      );
    sqlite
      .prepare(`INSERT INTO work_requests VALUES ('thread', ?)`)
      .run(JSON.stringify({ attachments: [{ kind: "file", fileId: ids[0] }] }));
    expect((await list()).files.find((f) => f.fileId === ids[0])!.inUse).toBe(
      true,
    );
    expect(await pruneOrphanUserFiles(env)).toBe(0);
    const later = new Date(Date.now() + 2 * 24 * 60 * 60 * 1000);
    expect(await pruneOrphanUserFiles(env, later)).toBe(1);
    expect((await list()).files.map((f) => f.fileId)).toEqual([ids[0]]);
  });
});
