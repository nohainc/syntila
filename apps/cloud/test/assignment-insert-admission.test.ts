import { expect, it, vi } from "vitest";
import { dispatchTaskAssignment } from "../src/assignment-dispatcher.js";
import { conversationFixture } from "./helpers/conversation.js";

const scheduler = vi.hoisted(() => ({ selectSpaceExecutionTarget: vi.fn() }));
vi.mock("../src/scheduler.js", () => scheduler);

async function fixture() {
  const f = await conversationFixture();
  f.sqlite.exec(
    "INSERT INTO runs(id,space_id,status,created_at,updated_at) VALUES('RUN','P','running','now','now')",
  );
  scheduler.selectSpaceExecutionTarget.mockResolvedValue({
    spaceId: "P",
    workspaceId: "WS",
    workspaceRuntimeIdentityId: "RT",
    workspaceSpaceGrantId: null,
    workerId: "worker-a",
    workerTypeId: "chatgpt",
    engineVersion: "1.3.0",
    model: null,
    maxConcurrentAssignments: 1,
    effectivePermissions: ["repository:read"],
    permissionSnapshot: {
      profileDefinitionId: "chatgpt-codex",
      profileReleaseVersion: 3,
    },
    selectionExplanation: {},
    executionClass: "stateless_read",
    readOnly: true,
  });
  const fetch = vi.fn(async (_url: string, _init?: RequestInit) =>
    Response.json({}),
  );
  const insertMetadata: number[] = [];
  const db = {
    prepare(sql: string) {
      const stmt = f.db.prepare(sql);
      let values: unknown[] = [];
      const wrapped = {
        bind(...next: unknown[]) {
          values = next;
          return wrapped;
        },
        async first() {
          const before = Number(
            f.sqlite.prepare("SELECT total_changes() AS n").get()!.n,
          );
          const row = await stmt.bind(...values).first();
          if (sql.includes("INSERT INTO worker_assignments"))
            insertMetadata.push(
              Number(f.sqlite.prepare("SELECT total_changes() AS n").get()!.n) -
                before,
            );
          return row;
        },
        async all() {
          return stmt.bind(...values).all();
        },
        async run() {
          const before = f.sqlite.prepare("SELECT total_changes() AS n").get()!
            .n as number;
          const result = await stmt.bind(...values).run();
          const after = f.sqlite.prepare("SELECT total_changes() AS n").get()!
            .n as number;
          if (sql.includes("INSERT INTO worker_assignments"))
            insertMetadata.push(after - before);
          // Match actual D1 metadata, including writes in production triggers.
          return { ...result, meta: { changes: after - before } };
        },
      };
      return wrapped;
    },
  } as unknown as D1Database;
  return {
    ...f,
    fetch,
    insertMetadata,
    dispatch: () =>
      dispatchTaskAssignment(
        {
          SYNTILA_DB: db,
          SYNTILA_WORKSPACE_GATEWAY: {
            idFromName: () => "WS",
            get: () => ({ fetch }),
          } as unknown as DurableObjectNamespace,
        },
        {
          workspaceId: "WS",
          runId: "RUN",
          taskId: "T",
          task: {
            id: "T",
            spaceId: "P",
            requestedByUserId: "U",
            role: "collaborator",
            objective: "test",
            workRequestId: "R",
            sessionPolicy: "stateless",
          },
        },
      ),
  };
}

it.each([
  [60 * 1024, true],
  [300 * 1024, false],
])(
  "keeps a %i byte history entry in context: %s, and dispatches either way",
  async (bytes, kept) => {
    const f = await fixture();
    try {
      const conversation = f.sqlite
        .prepare("SELECT id FROM conversations")
        .get()!;
      f.sqlite
        .prepare(
          `INSERT INTO conversation_history_entries
        (conversation_id,sequence,kind,event_type,actor_type,source_id,text,metadata_json,occurred_at)
        SELECT ?1,MAX(sequence)+1,'user_message','user_message','user','large-history',?2,'{}','now'
        FROM conversation_history_entries WHERE conversation_id=?1`,
        )
        .run(String(conversation.id), "x".repeat(bytes));
      scheduler.selectSpaceExecutionTarget.mockResolvedValue({
        ...(await scheduler.selectSpaceExecutionTarget()),
        conversationId: conversation.id,
        workRequestId: "R",
        baseContextRevision: 0,
      });
      // History over the transport budget is left out, never a failure: the
      // Worker's CLI reports a real context overflow itself.
      const result = await f.dispatch();
      expect(result.accepted).toBe(true);
      const payload = JSON.parse(String(f.fetch.mock.calls[0]?.[1]?.body));
      const context = JSON.stringify(payload.payload);
      expect(context.includes("x".repeat(1024))).toBe(kept);
      expect(new TextEncoder().encode(context).byteLength).toBeLessThanOrEqual(
        256 * 1024,
      );
    } finally {
      f.sqlite.close();
    }
  },
);

it("dispatches an inserted assignment despite conversation and history trigger writes", async () => {
  const f = await fixture();
  try {
    const before = Number(
      f.sqlite.prepare("SELECT total_changes() AS n").get()!.n,
    );
    const result = await f.dispatch();
    expect(result.accepted).toBe(true);
    expect(f.insertMetadata).toEqual([3]);
    expect(f.fetch).toHaveBeenCalledTimes(1);
    expect(
      f.sqlite
        .prepare("SELECT status FROM worker_assignments WHERE id=?")
        .get(result.assignmentId),
    ).toEqual({ status: "dispatched" });
    expect(
      f.sqlite
        .prepare(
          "SELECT assignment_id FROM conversation_turns WHERE assignment_id=?",
        )
        .get(result.assignmentId),
    ).toEqual({ assignment_id: result.assignmentId });
    expect(
      f.sqlite
        .prepare(
          "SELECT count(*) AS n FROM conversation_history_entries WHERE turn_id=?",
        )
        .get(`turn-${result.assignmentId}`),
    ).toEqual({ n: 1 });
    expect(
      Number(f.sqlite.prepare("SELECT total_changes() AS n").get()!.n) - before,
    ).toBeGreaterThan(1);
    const payload = JSON.parse(String(f.fetch.mock.calls[0]?.[1]?.body));
    expect(payload.payload.snapshot.maxConcurrentAssignments).toBe(1);
  } finally {
    f.sqlite.close();
  }
});

it("rejects an insert refused by an atomic capacity guard without sending to the Service", async () => {
  const f = await fixture();
  try {
    // Model a capacity race after selection: the insert itself admits no row.
    f.sqlite.exec(
      "CREATE TRIGGER full_capacity BEFORE INSERT ON worker_assignments BEGIN SELECT RAISE(IGNORE); END",
    );
    const result = await f.dispatch();
    expect(result).toMatchObject({
      accepted: false,
      status: "failed",
      assignmentId: "",
    });
    expect(result.error).toContain("capacity");
    expect(f.fetch).not.toHaveBeenCalled();
    expect(
      f.sqlite.prepare("SELECT count(*) AS n FROM worker_assignments").get(),
    ).toEqual({ n: 0 });
    expect(
      f.sqlite.prepare("SELECT count(*) AS n FROM conversation_turns").get(),
    ).toEqual({ n: 0 });
  } finally {
    f.sqlite.close();
  }
});
