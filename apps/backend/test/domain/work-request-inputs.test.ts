import { describe, expect, it, vi } from "./helpers/vitest-compat";

vi.mock("../../src/domain/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: async () => ({
    context: { userId: "owner" },
    spaceId: "space",
  }),
}));
vi.mock("../../src/domain/worker-agents.js", () => ({
  // A live session of the Worker it names when the token is right.
  authenticateAgentSession: async (_env: unknown, input: { workerId: string; sessionToken: string }) =>
    input.sessionToken === "agent-secret" ? { workerInstanceId: input.workerId } : null,
}));
vi.mock("../../src/domain/event-publisher.js", () => ({
  // Applies the domain writes the route commits together with its signal.
  createEventPublisher: (env: unknown) => ({
    publish: async (input?: { mutate?: (tx: never) => Promise<unknown> }) => {
      if (!input?.mutate) return;
      const { dataOf } = await import("../../src/platform/data.js");
      await dataOf(env as never).tx("test.publish", (tx) => input.mutate!(tx as never));
    },
  }),
}));

import { pgD1 } from "./helpers/pg-d1";
import { basicThread } from "./helpers/seed";
import {
  handleDownloadAgentInput,
  handleFailWorkRequestInputUpload,
  handleUploadWorkRequestInput,
  loadWorkRequestInputs,
  withInputFacts,
  insertWorkRequestInputs,
} from "../../src/domain/routes/work-request-inputs.js";
import { dataOf } from "../../src/platform/data.js";
import { computePackageDigest } from "@syntila/security";

const fileA = "wrf-11111111-2222-3333-4444-555555555555";
const fileB = "wrf-11111111-2222-3333-4444-666666666666";

async function fixture() {
  const { sqlite, db } = await pgD1();
  await sqlite.exec("PRAGMA foreign_keys = OFF");
  await sqlite.exec(basicThread({ user: "owner", space: "space", thread: "thread", threadName: "T" }));
  await sqlite.exec(`INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name)
    VALUES ('worker-a','','owner','chatgpt','A'), ('worker-b','','owner','chatgpt','B')`);
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
  await sqlite
    .prepare(
      `INSERT INTO work_requests (id, thread_id, requested_by_user_id, mode,
        workflow_id, workflow_version, workflow_snapshot_json, status,
        input_json, created_at, updated_at)
       VALUES ('wr', 'thread', 'owner', 'stateless', 'direct', 2, '{}',
        'queued', ?, 'now', 'now')`,
    )
    .run(JSON.stringify({ attachments }));
  await dataOf({ SYNTILA_DB: db } as never).tx("test.inputs", (tx) =>
    insertWorkRequestInputs(tx, {
      workRequestId: "wr",
      threadId: "thread",
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
  const agent = (path: string, init?: RequestInit, workerId = "worker-a") =>
    new Request(`https://t/api/worker-agent/inputs${path}`, {
      ...init,
      headers: {
        authorization: "Bearer agent-secret",
        "x-worker-id": workerId,
        "x-worker-session-id": "session-1",
        ...(init?.headers ?? {}),
      },
    });
  const states = async () =>
    (await loadWorkRequestInputs(db as unknown as D1Database, "wr")).map(
      (row) => [row.fileId, row.state],
    );
  return { sqlite, env, put, agent, states };
}

describe("Input Delivery v1", () => {
  it("lets any Worker that runs a Step of the request download its file", async () => {
    const { sqlite, env, put, agent, states } = await fixture();
    try {
      expect(await states()).toEqual([
        [fileA, "awaiting_upload"],
        [fileB, "awaiting_upload"],
      ]);
      expect((await put(fileA, "hello")).status).toBe(200);
      expect(await states()).toEqual([
        [fileA, "uploaded"],
        [fileB, "awaiting_upload"],
      ]);
      // A Worker with no Step on the request cannot read it.
      await expect(handleDownloadAgentInput(agent(`/${fileA}/content`), env, fileA)).rejects.toThrow("Input not found");
      for (const worker of ["worker-a", "worker-b"])
        await sqlite.exec(`INSERT INTO worker_assignments(id,space_id,thread_id,work_request_id,worker_type_id,worker_instance_id,worker_snapshot_json,status,created_at,updated_at)
          VALUES ('asg-${worker}','space','thread','wr','chatgpt','${worker}','{}','created',now(),now())`);
      const digest = await computePackageDigest(new TextEncoder().encode("hello"));
      for (const worker of ["worker-a", "worker-b"]) {
        const res = await handleDownloadAgentInput(agent(`/${fileA}/content`, undefined, worker), env, fileA);
        expect(await res.text()).toBe("hello");
        expect(res.headers.get("x-content-digest")).toBe(digest);
      }
      await expect(
        handleDownloadAgentInput(agent(`/${fileA}/content`, { headers: { authorization: "Bearer wrong" } }), env, fileA),
      ).rejects.toThrow("Invalid Worker session");
      // The stored request input stays immutable; dispatch and history merge
      // the verified digest from the delivery record.
      const stored = JSON.parse(
        String(
          (
            await sqlite
              .prepare("SELECT input_json AS v FROM work_requests WHERE id='wr'")
              .get() as { v: string }
          ).v,
        ),
      );
      expect(stored.attachments[0]).not.toHaveProperty("contentDigest");
      const merged = withInputFacts(
        stored,
        await loadWorkRequestInputs((env as { SYNTILA_DB: D1Database }).SYNTILA_DB, "wr"),
      ) as { attachments: Record<string, unknown>[] };
      expect(merged.attachments[0]).toMatchObject({
        fileId: fileA,
        contentDigest: digest,
        previewText: "hello",
      });
    } finally {
      await sqlite.close();
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
      await sqlite.close();
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
      await sqlite.close();
    }
  });

  it("rejects uploads for a cancelled request", async () => {
    const { sqlite, put } = await fixture();
    try {
      await put(fileA, "hello");
      await sqlite.exec("UPDATE work_requests SET cancel_requested_at = 'now'");
      await expect(put(fileB, "abc")).rejects.toThrow("no longer waiting");
    } finally {
      await sqlite.close();
    }
  });
});
