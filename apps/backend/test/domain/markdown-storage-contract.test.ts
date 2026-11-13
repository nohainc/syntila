import { pgD1 } from "./helpers/pg-d1";
import { basicThread } from "./helpers/seed";
vi.mock("../../src/domain/collaboration-events.js", () => ({
  publishCollaborationEvent: async (
    _env: unknown,
    _type: string,
    _space: string,
    _entity: string,
    options: { mutations?: { run: () => Promise<unknown> }[] } = {},
  ) => {
    for (const mutation of options.mutations ?? []) await mutation.run();
  },
}));
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, it, vi } from "./helpers/vitest-compat";

vi.mock("../../src/domain/routes/thread-policy.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: async () => ({
    context: { userId: "user-owner" },
    spaceId: "space-test",
  }),
}));

vi.mock("../../src/domain/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: async () => ({
    context: { userId: "user-owner" },
    spaceId: "space-test",
  }),
}));
import {
  handleCreateDiscussionMessage,
  handleEditDiscussionMessage,
  handleListDiscussionMessages,
} from "../../src/domain/routes/threads.js";
import {
  handleGetWorkRequest,
  handleListWorkRequests,
} from "../../src/domain/routes/work-lifecycle.js";
import { BUILTIN_WORKFLOW_CATALOG } from "@syntila/core";

it.each(
  [
    BUILTIN_WORKFLOW_CATALOG["direct:v1"]!,
    BUILTIN_WORKFLOW_CATALOG["direct:v2"]!,
    BUILTIN_WORKFLOW_CATALOG["chat:v1"]!,
  ].flatMap((definition) => [
    { definition, snapshotName: definition.name },
    { definition, snapshotName: undefined },
  ]),
)(
  "$definition.name v$definition.version history preserves names and Markdown (snapshot name: $snapshotName)",
  async ({ definition, snapshotName }) => {
    const sqlite = (pgD1().sqlite as unknown as DatabaseSync);
    sqlite.exec(
      "" /* D1 migration: schema is final in PostgreSQL */,
    );
    sqlite.exec(basicThread({ user: "user-owner", space: "space-test", thread: "stream-test" }));
    const source = '\n**Original**\n```bash\nprintf "hello"\n```\n  ';
    const result = '  ## Result\n\n```json\n{"ok":true}\n```\n';
    sqlite
      .prepare(
        "INSERT INTO work_requests(id, requested_by_user_id, thread_id, workflow_id, workflow_version, workflow_snapshot_json, snapshot_json, input_json, status, created_at, updated_at, mode) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'stateless')",
      )
      .run(
        "request-test",
        "user-owner",
        "stream-test",
        definition.id,
        definition.version,
        JSON.stringify({ ...definition, name: snapshotName }),
        "{}",
        JSON.stringify({
          originalRequest: source,
          isPhased: definition.id === "direct" && definition.version === 2,
        }),
        "completed",
        "2026-10-06T00:00:00Z",
        "2026-10-06T00:00:01Z",
      );
    sqlite
      .prepare(
        "INSERT INTO workflow_tasks(id, work_request_id, step_kind, status, output_json, error, started_at, created_at, finished_at, updated_at, execution_mode, timeout_ms, prompt_profile_version) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'stateless_read', 60000, 'v1')",
      )
      .run(
        "task-test",
        "request-test",
        definition.steps[0]!.kind,
        "completed",
        JSON.stringify({ text: result }),
        null,
        null,
        "2026-10-06T00:00:00Z",
        "2026-10-06T00:00:01Z",
        "2026-10-06T00:00:01Z",
      );
    const db = {
      prepare(sql: string) {
        let values: (string | number | null)[] = [];
        return {
          bind(...args: (string | number | null)[]) {
            values = args;
            return this;
          },
          async first() {
            return sqlite.prepare(sql).get(...values) ?? null;
          },
          async all() {
            return { results: sqlite.prepare(sql).all(...values) };
          },
        };
      },
    };
    try {
      const response = await handleListWorkRequests(
        new Request(
          "https://syntila.test/api/threads/stream-test/work-requests",
        ),
        { SYNTILA_DB: db } as unknown as Parameters<
          typeof handleListWorkRequests
        >[1],
        "stream-test",
      );
      const body = (await response.json()) as {
        workRequests: {
          prompt: string;
          isPhased: boolean;
          finalText: string;
          workflowName: string;
          workflowVersion: number;
          steps: { resultText: string }[];
        }[];
      };
      expect(body.workRequests[0]?.prompt).toBe(source);
      expect(body.workRequests[0]?.isPhased).toBe(
        definition.id === "direct" && definition.version === 2,
      );
      expect(body.workRequests[0]?.finalText).toBe(result);
      expect(body.workRequests[0]?.workflowName).toBe(definition.name);
      expect(body.workRequests[0]?.workflowVersion).toBe(definition.version);
      const detail = await handleGetWorkRequest(
        new Request("https://syntila.test/api/work-requests/request-test"),
        { SYNTILA_DB: db } as unknown as Parameters<
          typeof handleGetWorkRequest
        >[1],
        "request-test",
      );
      const detailBody = (await detail.json()) as {
        workRequest: {
          originalRequest: string;
          isPhased: boolean;
          workflowName: string;
          workflowVersion: number;
        };
        steps: { resultText: string }[];
      };
      expect(detailBody.workRequest.originalRequest).toBe(source);
      expect(detailBody.workRequest.isPhased).toBe(
        definition.id === "direct" && definition.version === 2,
      );
      expect(detailBody.workRequest.workflowName).toBe(definition.name);
      expect(detailBody.workRequest.workflowVersion).toBe(definition.version);
      expect(detailBody.steps[0]?.resultText).toBe(result);
    } finally {
      sqlite.close();
    }
  },
);

it("persists and returns exact Markdown through Chat create, edit and list", async () => {
  const sqlite = (pgD1().sqlite as unknown as DatabaseSync);
  sqlite.exec(basicThread({ user: "user-owner", space: "space-test", thread: "stream-test" }));
  const db = {
    prepare(sql: string) {
      let values: (string | null)[] = [];
      return {
        bind(...args: (string | null)[]) {
          values = args;
          return this;
        },
        async run() {
          sqlite.prepare(sql).run(...values);
          return { success: true };
        },
        async first() {
          return sqlite.prepare(sql).get(...values) ?? null;
        },
        async all() {
          return { results: sqlite.prepare(sql).all(...values) };
        },
      };
    },
  };
  const env = { SYNTILA_DB: db } as unknown as Parameters<
    typeof handleCreateDiscussionMessage
  >[1];
  const request = (body: string, method = "POST") =>
    new Request("https://syntila.test/api/messages", {
      method,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ body }),
    });
  const source =
    '  ## Heading\n\n**bold** [link](https://example.com)\n\n```json\n{"ready":true}\n```\n  ';
  try {
    const created = await handleCreateDiscussionMessage(
      request(source),
      env,
      "stream-test",
    );
    const { message } = (await created.json()) as {
      message: { id: string; body: string };
    };
    expect(message.body).toBe(source);
    expect(
      sqlite.prepare("SELECT body FROM discussion_messages").get()?.body,
    ).toBe(source);
    const edited = `\n> Edited\n${source}\n- [ ] Task\n`;
    const response = await handleEditDiscussionMessage(
      request(edited, "PATCH"),
      env,
      message.id,
    );
    expect(
      ((await response.json()) as { message: { body: string } }).message.body,
    ).toBe(edited);
    const listed = await handleListDiscussionMessages(
      new Request("https://syntila.test/api/messages"),
      env,
      "stream-test",
    );
    expect(
      ((await listed.json()) as { messages: { body: string }[] }).messages[0]
        ?.body,
    ).toBe(edited);
    expect(
      sqlite.prepare("SELECT body FROM discussion_messages").get()?.body,
    ).toBe(edited);
  } finally {
    sqlite.close();
  }
});
