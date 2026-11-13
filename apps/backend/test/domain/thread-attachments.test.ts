import { pgD1 } from "./helpers/pg-d1";
import { basicThread, user, workRequest, message } from "./helpers/seed";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { beforeEach, describe, expect, it, vi } from "./helpers/vitest-compat";
const authorize = vi.fn(async (..._args: unknown[]) => ({
  context: { userId: "owner" },
  spaceId: "space",
}));
vi.mock("../../src/domain/routes/thread-policy.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: (...args: unknown[]) => authorize(...args),
}));
vi.mock("../../src/domain/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: (...args: unknown[]) => authorize(...args),
}));
vi.mock("../../src/domain/collaboration-events.js", () => ({
  publishCollaborationEvent: async (
    _env: unknown,
    _type: string,
    _space: string,
    _entity: string,
    options: { mutations: { run(): Promise<unknown> }[] },
  ) => {
    for (const mutation of options.mutations) await mutation.run();
  },
}));
import {
  handleUploadWorkRequestFile,
  handleDownloadThreadFile,
  fileTextPreview,
  normalizeDiscussionAttachments,
} from "../../src/domain/routes/work-request-files.js";
import {
  handleCreateDiscussionMessage,
  handleListDiscussionMessages,
  handleEditDiscussionMessage,
} from "../../src/domain/routes/threads.js";

function fixture() {
  const sqlite = (pgD1().sqlite as unknown as DatabaseSync);
  sqlite.exec(basicThread({ user: "owner", space: "space", thread: "thread" }));
  for (const migration of [
    "0094_account_plans.sql",
    "0098_user_file_reservations.sql",
  ])
    sqlite.exec(
      "" /* D1 migration: schema is final in PostgreSQL */,
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
  const objects = new Map<
    string,
    {
      bytes: Uint8Array;
      customMetadata?: Record<string, string>;
      httpMetadata?: Record<string, string>;
    }
  >();
  const bucket = {
    async put(
      key: string,
      value: ArrayBuffer | string,
      options: {
        customMetadata?: Record<string, string>;
        httpMetadata?: Record<string, string>;
      },
    ) {
      objects.set(key, {
        bytes:
          typeof value === "string"
            ? new TextEncoder().encode(value)
            : new Uint8Array(value),
        ...options,
      });
    },
    async head(key: string) {
      const object = objects.get(key);
      return object ? { ...object, size: object.bytes.length } : null;
    },
    async delete(keys: string | string[]) {
      for (const key of [keys].flat()) objects.delete(key);
    },
    async get(key: string) {
      const object = objects.get(key);
      return object
        ? {
            ...object,
            size: object.bytes.length,
            body: object.bytes,
            json: async () =>
              JSON.parse(new TextDecoder().decode(object.bytes)),
          }
        : null;
    },
  };
  const env = { SYNTILA_DB: db, SYNTILA_ARTIFACTS: bucket } as never;
  async function upload(text = "hello **file**") {
    const response = await handleUploadWorkRequestFile(
      new Request(
        "https://test/api/threads/thread/work-request-files?name=note.txt&purpose=discussion",
        {
          method: "POST",
          headers: {
            "content-type": "text/plain",
            "content-length": String(new TextEncoder().encode(text).byteLength),
          },
          body: text,
        },
      ),
      env,
      "thread",
    );
    return (
      (await response.json()) as { file: { fileId: string; sizeBytes: number } }
    ).file;
  }
  return { sqlite, env, upload, objects };
}
const request = (body: unknown, method = "POST") =>
  new Request("https://test/api/messages", {
    method,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
beforeEach(() => authorize.mockClear());

describe("Thread attachments", () => {
  it.each([
    ["Free", null, 25_000_000],
    ["Plus", "paid", 100_000_000],
  ])(
    "%s accepts exactly its file limit and rejects one byte more with file_too_large",
    async (_plan, tier, limit) => {
      const f = fixture();
      try {
        if (tier)
          f.sqlite.exec(
            "INSERT INTO account_plans(user_id,tier,status,source,created_at,updated_at) VALUES('owner','paid','active','manual','now','now')",
          );
        const send = (size: number, body: BodyInit) =>
          handleUploadWorkRequestFile(
            new Request("https://test?name=boundary.bin", {
              method: "POST",
              headers: { "content-length": String(size) },
              body,
            }),
            f.env,
            "thread",
          );
        const response = await send(limit, new Uint8Array(limit));
        expect(response.status).toBe(201);
        const { file } = (await response.json()) as {
          file: { sizeBytes: number };
        };
        expect(file.sizeBytes).toBe(limit);
        // One byte over is refused from the declared length, before any bytes
        // are read, with a code distinct from a full account.
        await expect(send(limit + 1, "small")).rejects.toMatchObject({
          status: 413,
          code: "file_too_large",
        });
        // The refusal reserved and stored nothing.
        expect(
          f.sqlite
            .prepare("SELECT COUNT(*) AS n FROM user_file_reservations")
            .get(),
        ).toEqual({ n: 0 });
      } finally {
        f.sqlite.close();
      }
    },
  );

  it("never trusts a declared size: short, long and truncated bodies store nothing", async () => {
    const f = fixture();
    try {
      const send = (declared: number, body: string) =>
        handleUploadWorkRequestFile(
          new Request("https://test?name=lie.bin", {
            method: "POST",
            headers: { "content-length": String(declared) },
            body,
          }),
          f.env,
          "thread",
        );
      await expect(send(10, "short")).rejects.toMatchObject({
        code: "upload_size_mismatch",
      });
      await expect(send(3, "longer than declared")).rejects.toMatchObject({
        code: "upload_size_mismatch",
      });
      expect(f.objects.size).toBe(0);
      expect(
        f.sqlite.prepare("SELECT COUNT(*) AS n FROM user_files").get(),
      ).toEqual({ n: 0 });
      expect(
        f.sqlite
          .prepare("SELECT COUNT(*) AS n FROM user_file_reservations")
          .get(),
      ).toEqual({ n: 0 });
      expect((await send(5, "hello")).status).toBe(201);
    } finally {
      f.sqlite.close();
    }
  });

  it("accepts a file-only human message, retains previews through history and edits, and downloads the original", async () => {
    const f = fixture();
    try {
      const file = await f.upload();
      expect(authorize.mock.calls[0]?.[3]).toBe("discuss");
      await expect(
        handleDownloadThreadFile(
          new Request("https://test"),
          f.env,
          "thread",
          file.fileId,
        ),
      ).rejects.toThrow("File not found");
      const response = await handleCreateDiscussionMessage(
        request({
          body: "",
          attachments: [{ kind: "file", ...file, previewText: "forged" }],
        }),
        f.env,
        "thread",
      );
      const { message } = (await response.json()) as {
        message: {
          id: string;
          body: string;
          attachments: { previewText: string; name: string }[];
        };
      };
      expect(message.body).toBe("");
      expect(message.attachments[0]).toMatchObject({
        name: "note.txt",
        previewText: "hello **file**",
      });
      const edited = await handleEditDiscussionMessage(
        request({ body: "new caption" }, "PATCH"),
        f.env,
        message.id,
      );
      expect(
        ((await edited.json()) as { message: { attachments: unknown } }).message
          .attachments,
      ).toEqual(message.attachments);
      const history = await handleListDiscussionMessages(
        new Request("https://test"),
        f.env,
        "thread",
      );
      expect(
        ((await history.json()) as { messages: { attachments: unknown }[] })
          .messages[0]?.attachments,
      ).toEqual(message.attachments);
      const download = await handleDownloadThreadFile(
        new Request("https://test"),
        f.env,
        "thread",
        file.fileId,
      );
      expect(await download.text()).toBe("hello **file**");
      expect(download.headers.get("cache-control")).toBe("private, no-store");
      await expect(
        handleDownloadThreadFile(
          new Request("https://test"),
          f.env,
          "other-thread",
          file.fileId,
        ),
      ).rejects.toThrow("File not found");
      await expect(
        normalizeDiscussionAttachments(
          f.env,
          [{ kind: "file", ...file }],
          "other-thread",
          "owner",
        ),
      ).rejects.toThrow("not found");
      await expect(
        normalizeDiscussionAttachments(
          f.env,
          [{ kind: "file", ...file }],
          "thread",
          "other-user",
        ),
      ).rejects.toThrow("not found");
    } finally {
      f.sqlite.close();
    }
  });
  it("stores image previews once and rejects oversized or non-JPEG preview payloads", async () => {
    const f = fixture();
    try {
      const form = new FormData();
      form.set("file", new Blob(["original"]), "photo.png");
      form.set("mediaType", "image/png");
      form.set("previewImage", "/9j/AAAA");
      const encoded = new Response(form);
      const payload = await encoded.arrayBuffer();
      const response = await handleUploadWorkRequestFile(
        new Request("https://test?name=photo.png&purpose=discussion", {
          method: "POST",
          headers: {
            "content-type": encoded.headers.get("content-type")!,
            "content-length": String(payload.byteLength),
          },
          body: payload,
        }),
        f.env,
        "thread",
      );
      const { file } = (await response.json()) as {
        file: { fileId: string; sizeBytes: number };
      };
      const normalized = await normalizeDiscussionAttachments(
        f.env,
        [{ kind: "file", ...file }],
        "thread",
        "owner",
      );
      expect(normalized[0]).toMatchObject({ previewImage: "/9j/AAAA" });
      expect(f.objects.size).toBe(2);
      for (const preview of ["<svg>unsafe</svg>", "/9j/" + "A".repeat(32000)]) {
        form.set("previewImage", preview);
        const bad = new Response(form);
        const badBody = await bad.arrayBuffer();
        await expect(
          handleUploadWorkRequestFile(
            new Request("https://test", {
              method: "POST",
              headers: {
                "content-type": bad.headers.get("content-type")!,
                "content-length": String(badBody.byteLength),
              },
              body: badBody,
            }),
            f.env,
            "thread",
          ),
        ).rejects.toThrow("Invalid image preview");
      }
      expect(f.objects.size).toBe(2);
    } finally {
      f.sqlite.close();
    }
  });
  it("bounds text previews, rejects invalid references, and requires either a message or file", async () => {
    expect(
      fileTextPreview(
        "a.txt",
        "text/plain",
        new TextEncoder().encode("a".repeat(2000)).buffer,
      ),
    ).toHaveLength(1200);
    expect(
      fileTextPreview("a.pdf", "application/pdf", new ArrayBuffer(0)),
    ).toBeUndefined();
    const f = fixture();
    try {
      await expect(
        handleCreateDiscussionMessage(request({ body: "" }), f.env, "thread"),
      ).rejects.toThrow();
      await expect(
        normalizeDiscussionAttachments(
          f.env,
          Array(11).fill({}),
          "thread",
          "owner",
        ),
      ).rejects.toThrow("10");
      await expect(
        normalizeDiscussionAttachments(
          f.env,
          [{ kind: "file", fileId: "../secret" }],
          "thread",
          "owner",
        ),
      ).rejects.toThrow("Invalid attachment");
      await expect(
        handleUploadWorkRequestFile(
          new Request("https://test", {
            method: "POST",
            headers: { "content-length": "25000001" },
            body: new Uint8Array(1),
          }),
          f.env,
          "thread",
        ),
      ).rejects.toMatchObject({ code: "file_too_large" });
    } finally {
      f.sqlite.close();
    }
  });
});
