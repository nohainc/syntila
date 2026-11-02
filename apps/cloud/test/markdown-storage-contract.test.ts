vi.mock("../src/collaboration-events.js", () => ({
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
import { expect, it, vi } from "vitest";

vi.mock("../src/routes/thread-policy.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: async () => ({
    context: { userId: "user-owner" },
    spaceId: "space-test",
  }),
}));

vi.mock("../src/routes/handlers.js", async (original) => ({
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
} from "../src/routes/threads.js";
import {
  handleGetWorkRequest,
  handleListWorkRequests,
} from "../src/routes/work-lifecycle.js";
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
    const sqlite = new DatabaseSync(":memory:");
    sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0088_work_request_inputs.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    sqlite.exec(`
    CREATE TABLE conversation_turns(workflow_step_run_id TEXT, workflow_run_id TEXT, id TEXT, conversation_id TEXT, user_message_id TEXT, work_request_id TEXT, assignment_id TEXT, task_id TEXT, step_kind TEXT, workflow_id TEXT, workflow_version TEXT, worker_id TEXT, worker_type_id TEXT, worker_display_name TEXT, profile_id TEXT, profile_version TEXT, model_id TEXT, effort TEXT, worker_session_id TEXT, base_context_revision TEXT, status TEXT, started_at TEXT, completed_at TEXT, result_text TEXT, created_at TEXT);
    CREATE TABLE conversation_workflow_runs(id TEXT, conversation_id TEXT, user_message_id TEXT, work_request_id TEXT, workflow_id TEXT, workflow_version INTEGER, created_at TEXT, started_at TEXT, completed_at TEXT);
    CREATE TABLE conversation_workflow_step_runs(id TEXT, workflow_run_id TEXT, task_id TEXT, step_id TEXT, role TEXT, created_at TEXT);
    CREATE TABLE conversation_history_entries(id TEXT, turn_id TEXT, work_request_id TEXT, kind TEXT, text TEXT);
    CREATE TABLE users(id TEXT, display_name TEXT);
    CREATE TABLE account_execution_waiters(task_id TEXT, reason TEXT);
    CREATE TABLE threads(id TEXT, ai_history_cleared_at TEXT);
    CREATE TABLE conversation_work_requests(conversation_id TEXT, work_request_id TEXT, conversation_revision INTEGER);
    CREATE TABLE work_requests(id TEXT, requested_by_user_id TEXT, thread_id TEXT,
      workflow_id TEXT, workflow_version INTEGER, workflow_snapshot_json TEXT, snapshot_json TEXT,
      input_json TEXT, status TEXT, created_at TEXT, updated_at TEXT);
    CREATE TABLE workflow_tasks(id TEXT, work_request_id TEXT, step_kind TEXT, step_id TEXT GENERATED ALWAYS AS (step_kind) VIRTUAL, status TEXT,
      output_json TEXT, error TEXT, started_at TEXT, created_at TEXT, finished_at TEXT, updated_at TEXT);
    CREATE TABLE worker_assignments(run_id TEXT, id TEXT, task_id TEXT, work_request_id TEXT, created_at TEXT, error_json TEXT,
      workspace_worker_id TEXT, worker_type_id TEXT, model TEXT, engine_version TEXT, permission_snapshot_json TEXT,
      status TEXT, attempt_id TEXT, dispatched_at TEXT, acknowledged_at TEXT, running_at TEXT,
      start_permit_required INTEGER, start_permit_issued_at TEXT, startup_stage TEXT, startup_stage_at TEXT,
      cloud_queue_reason TEXT, cloud_queue_since TEXT);
    CREATE TABLE workspace_worker_inventory(worker_id TEXT, worker_type_id TEXT,
      provider_tool_name TEXT, provider_tool_version TEXT);
    CREATE TABLE worker_activity_history(
      history_id TEXT, assignment_id TEXT, workspace_id TEXT, attempt_id TEXT,
      execution_id TEXT, worker_id TEXT, source_event_id TEXT,
      provider_sequence INTEGER, event_type TEXT, status TEXT, activity_id TEXT,
      title TEXT, details_json TEXT, occurred_at TEXT, duration_ms INTEGER,
      tool_id TEXT, tool_name TEXT
    );
    INSERT INTO users VALUES('user-owner', 'Owner');
  `);
    sqlite.exec(`ALTER TABLE workflow_tasks ADD COLUMN attempt INTEGER;
    ALTER TABLE worker_assignments ADD COLUMN session_policy TEXT;
    ALTER TABLE worker_assignments ADD COLUMN updated_at TEXT;
    CREATE TABLE runs(id TEXT, work_request_id TEXT, created_at TEXT, policy_snapshot_json TEXT);
    CREATE TABLE worker_catalog(worker_type_id TEXT, display_name TEXT);`);
    const source = '\n**Original**\n```bash\nprintf "hello"\n```\n  ';
    const result = '  ## Result\n\n```json\n{"ok":true}\n```\n';
    sqlite
      .prepare(
        "INSERT INTO work_requests VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "request-test",
        "user-owner",
        "stream-test",
        definition.id,
        definition.version,
        JSON.stringify({ ...definition, name: snapshotName }),
        "{}",
        JSON.stringify({ originalRequest: source }),
        "completed",
        "2026-10-06T00:00:00Z",
        "2026-10-06T00:00:01Z",
      );
    sqlite
      .prepare(
        "INSERT INTO workflow_tasks(id, work_request_id, step_kind, status, output_json, error, started_at, created_at, finished_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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
          finalText: string;
          workflowName: string;
          workflowVersion: number;
          steps: { resultText: string }[];
        }[];
      };
      expect(body.workRequests[0]?.prompt).toBe(source);
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
          workflowName: string;
          workflowVersion: number;
        };
        steps: { resultText: string }[];
      };
      expect(detailBody.workRequest.originalRequest).toBe(source);
      expect(detailBody.workRequest.workflowName).toBe(definition.name);
      expect(detailBody.workRequest.workflowVersion).toBe(definition.version);
      expect(detailBody.steps[0]?.resultText).toBe(result);
    } finally {
      sqlite.close();
    }
  },
);

it("persists and returns exact Markdown through Chat create, edit and list", async () => {
  const sqlite = new DatabaseSync(":memory:");
  sqlite.exec(`CREATE TABLE users (id TEXT, display_name TEXT);
    CREATE TABLE discussion_messages (id TEXT, thread_id TEXT, attachments_json TEXT NOT NULL DEFAULT '[]',
    author_user_id TEXT, body TEXT, references_json TEXT, edited_at TEXT, created_at TEXT,
    event_type TEXT, kind TEXT, work_request_id TEXT, worker_display_name TEXT, reply_to_json TEXT);
    CREATE TABLE space_audit_log (id TEXT, space_id TEXT, actor_type TEXT,
      actor_id TEXT, action TEXT, target_type TEXT, target_id TEXT, details_json TEXT, created_at TEXT);`);
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
