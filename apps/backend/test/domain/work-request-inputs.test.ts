import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "./helpers/vitest-compat";

vi.mock("../../src/domain/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: async () => ({
    context: { userId: "owner" },
    spaceId: "space",
  }),
}));
vi.mock("../../src/domain/workspace-gateway/runtime-authenticator.js", () => ({
  WorkspaceRuntimeAuthenticator: class {
    async authenticateRuntime(runtimeId: string, credential: string) {
      return credential === "secret"
        ? {
            executionWorkspaceId:
              runtimeId === "runtime-ws" ? "ws" : "other-ws",
          }
        : null;
    }
  },
}));
vi.mock("../../src/domain/event-publisher.js", () => ({
  // Applies the domain writes the route commits together with its signal.
  createEventPublisher: () => ({
    publish: async (input?: { mutations?: { run(): Promise<unknown> }[] }) => {
      for (const statement of input?.mutations ?? []) await statement.run();
    },
  }),
}));

import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { basicThread, workspace } from "./helpers/seed";
import {
  handleConfirmRuntimeInput,
  handleDownloadRuntimeInput,
  handleFailWorkRequestInputUpload,
  handleListRuntimeInputs,
  handleReportRuntimeInputAttempt,
  handleUploadWorkRequestInput,
  loadWorkRequestInputs,
  withInputFacts,
  workRequestInputStatements,
} from "../../src/domain/routes/work-request-inputs.js";
import { computePackageDigest } from "@syntila/security";

const fileA = "wrf-11111111-2222-3333-4444-555555555555";
const fileB = "wrf-11111111-2222-3333-4444-666666666666";

async function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec("PRAGMA foreign_keys = OFF");
  sqlite.exec(basicThread({ user: "owner", space: "space", thread: "thread", threadName: "T" }) + workspace("ws", "owner"));
  sqlite.exec(
    "" /* D1 migration: schema is final in PostgreSQL */,
  );
  const attachments = [
    {
      kind: "file",
      fileId: fileA,
      name: "a.txt",
      mediaType: "text/plain",
      sizeBytes: 5,
    },
    {
      kind: "file",
      fileId: fileB,
      name: "b.txt",
      mediaType: "text/plain",
      sizeBytes: 3,
    },
  ];
  sqlite
    .prepare(
      `INSERT INTO work_requests (id, thread_id, requested_by_user_id, mode,
        workflow_id, workflow_version, workflow_snapshot_json, status,
        primary_workspace_id, input_json, created_at, updated_at)
       VALUES ('wr', 'thread', 'owner', 'stateless', 'direct', 2, '{}',
        'queued', 'ws', ?, 'now', 'now')`,
    )
    .run(JSON.stringify({ attachments }));
  await (db as unknown as D1Database).batch(
    workRequestInputStatements(db as unknown as D1Database, {
      workRequestId: "wr",
      threadId: "thread",
      workspaceId: "ws",
      userId: "owner",
      attachments,
      now: new Date().toISOString(),
    }),
  );
  const objects = new Map<
    string,
    { bytes: Uint8Array; customMetadata?: Record<string, string> }
  >();
  const env = {
    SYNTILA_DB: db,
    SYNTILA_ARTIFACTS: {
      async put(
        key: string,
        value: ArrayBuffer | string,
        options: { customMetadata?: Record<string, string> },
      ) {
        objects.set(key, {
          bytes:
            typeof value === "string"
              ? new TextEncoder().encode(value)
              : new Uint8Array(value),
          customMetadata: options.customMetadata,
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
    },
  } as never;
  const put = (fileId: string, text: string) =>
    handleUploadWorkRequestInput(
      new Request(`https://t/api/work-requests/wr/inputs/${fileId}`, {
        method: "PUT",
        headers: {
          "content-type": "text/plain",
          "content-length": String(new TextEncoder().encode(text).byteLength),
        },
        body: text,
      }),
      env,
      "wr",
      fileId,
    );
  const runtime = (
    path: string,
    init?: RequestInit,
    runtimeId = "runtime-ws",
  ) =>
    new Request(
      `https://t/api/workspace-runtime/inputs${path}?workspaceRuntimeId=${runtimeId}`,
      {
        ...init,
        headers: { authorization: "Bearer secret", ...(init?.headers ?? {}) },
      },
    );
  const states = async () =>
    (await loadWorkRequestInputs(db as unknown as D1Database, "wr")).map(
      (row) => [row.fileId, row.state],
    );
  return { sqlite, env, put, runtime, states };
}

describe("Input Delivery v1", () => {
  it("delivers files one by one as they are uploaded", async () => {
    const { sqlite, env, put, runtime, states } = await fixture();
    try {
      expect(await states()).toEqual([
        [fileA, "awaiting_upload"],
        [fileB, "awaiting_upload"],
      ]);
      expect((await put(fileA, "hello")).status).toBe(200);
      // The first file is downloadable while the second is still uploading.
      const listed = (await (
        await handleListRuntimeInputs(runtime(""), env)
      ).json()) as { inputs: Record<string, unknown>[] };
      const digest = await computePackageDigest(
        new TextEncoder().encode("hello"),
      );
      expect(listed.inputs).toEqual([
        expect.objectContaining({
          fileId: fileA,
          workRequestId: "wr",
          sizeBytes: 5,
          contentDigest: digest,
        }),
      ]);
      const content = await handleDownloadRuntimeInput(
        runtime(`/${fileA}/content`),
        env,
        fileA,
      );
      expect(await content.text()).toBe("hello");
      expect(content.headers.get("x-content-digest")).toBe(digest);
      // Another Workspace cannot read it.
      await expect(
        handleDownloadRuntimeInput(
          runtime(`/${fileA}/content`, undefined, "runtime-other"),
          env,
          fileA,
        ),
      ).rejects.toThrow("Input not found");
      await expect(
        handleConfirmRuntimeInput(
          runtime(`/${fileA}/delivered`, {
            method: "POST",
            body: JSON.stringify({ contentDigest: "sha256:wrong" }),
          }),
          env,
          fileA,
        ),
      ).rejects.toThrow("does not match");
      await handleConfirmRuntimeInput(
        runtime(`/${fileA}/delivered`, {
          method: "POST",
          body: JSON.stringify({ contentDigest: digest }),
        }),
        env,
        fileA,
      );
      expect(await states()).toEqual([
        [fileA, "delivered"],
        [fileB, "awaiting_upload"],
      ]);
      // The stored request input stays immutable; dispatch and history merge
      // the verified digest from the delivery record.
      const stored = JSON.parse(
        String(
          (
            sqlite
              .prepare(
                "SELECT input_json AS v FROM work_requests WHERE id='wr'",
              )
              .get() as { v: string }
          ).v,
        ),
      );
      expect(stored.attachments[0]).not.toHaveProperty("contentDigest");
      const merged = withInputFacts(
        stored,
        await loadWorkRequestInputs(
          (env as { SYNTILA_DB: D1Database }).SYNTILA_DB,
          "wr",
        ),
      ) as { attachments: Record<string, unknown>[] };
      expect(merged.attachments[0]).toMatchObject({
        fileId: fileA,
        contentDigest: digest,
        previewText: "hello",
      });
      // A delivered file is immutable.
      expect(await (await put(fileA, "HELLO")).json()).toEqual({
        fileId: fileA,
        state: "delivered",
      });
    } finally {
      sqlite.close();
    }
  });

  it("rejects a size mismatch and lets the upload restart", async () => {
    const { sqlite, put, states } = await fixture();
    try {
      await expect(put(fileB, "toolong")).rejects.toThrow(
        "size does not match",
      );
      expect(await states()).toContainEqual([fileB, "awaiting_upload"]);
      expect((await put(fileB, "abc")).status).toBe(200);
      expect(await states()).toContainEqual([fileB, "uploaded"]);
    } finally {
      sqlite.close();
    }
  });

  it("counts download attempts and fails the input on the final one", async () => {
    const { sqlite, env, put, runtime, states } = await fixture();
    try {
      await put(fileA, "hello");
      const attempt = (final: boolean) =>
        handleReportRuntimeInputAttempt(
          runtime(`/${fileA}/attempt`, {
            method: "POST",
            body: JSON.stringify({ final, message: "digest mismatch" }),
          }),
          env,
          fileA,
        );
      await attempt(false);
      expect(await states()).toContainEqual([fileA, "uploaded"]);
      await attempt(true);
      const rows = sqlite
        .prepare(
          "SELECT state, delivery_attempts AS n, error_message AS e FROM work_request_inputs WHERE id = ?",
        )
        .get(fileA) as { state: string; n: number; e: string };
      expect(rows).toEqual({
        state: "failed",
        n: 1,
        e: "a.txt could not be delivered to the Workspace: digest mismatch",
      });
    } finally {
      sqlite.close();
    }
  });

  it("records an upload the client gave up on", async () => {
    const { sqlite, env, states } = await fixture();
    try {
      await handleFailWorkRequestInputUpload(
        new Request(`https://t/api/work-requests/wr/inputs/${fileB}/failed`, {
          method: "POST",
          body: JSON.stringify({ message: "network" }),
        }),
        env,
        "wr",
        fileB,
      );
      expect(await states()).toContainEqual([fileB, "failed"]);
    } finally {
      sqlite.close();
    }
  });

  it("stops listing inputs of a cancelled request", async () => {
    const { sqlite, env, put, runtime } = await fixture();
    try {
      await put(fileA, "hello");
      sqlite.exec("UPDATE work_requests SET cancel_requested_at = 'now'");
      const listed = (await (
        await handleListRuntimeInputs(runtime(""), env)
      ).json()) as { inputs: unknown[] };
      expect(listed.inputs).toEqual([]);
      await expect(put(fileB, "abc")).rejects.toThrow("no longer waiting");
    } finally {
      sqlite.close();
    }
  });
});
