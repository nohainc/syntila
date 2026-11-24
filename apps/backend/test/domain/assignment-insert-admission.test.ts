import { expect, it, vi } from "./helpers/vitest-compat";
import { dispatchTaskAssignment } from "../../src/domain/assignment-dispatcher.js";
import { conversationFixture } from "./helpers/conversation.js";

const scheduler = vi.hoisted(() => ({ selectSpaceExecutionTarget: vi.fn() }));
vi.mock("../../src/domain/scheduler.js", () => scheduler);

async function fixture() {
  const f = await conversationFixture();
  await f.sqlite.exec(`
    INSERT INTO runs(id,space_id,status,created_at,updated_at) VALUES('RUN','P','running','now','now');
    INSERT INTO worker_credentials(id,worker_instance_id,public_key,key_fingerprint) VALUES('cred-a','worker-a','${"a".repeat(43)}','${"a".repeat(64)}');
    INSERT INTO worker_agent_sessions(worker_instance_id,session_id,session_epoch,credential_id,token_digest,lease_expires_at) VALUES('worker-a','sess-a',1,'cred-a','digest',now() + interval '5 minutes');
    INSERT INTO worker_profiles(worker_type_id,schema_version,profile_json,revision,digest,updated_at) VALUES('chatgpt',1,'{"schemaVersion":1,"profileDefinitionId":"chatgpt-codex"}',3,'${"a".repeat(64)}',now()) ON CONFLICT (worker_type_id) DO NOTHING;`);
  const fetch = vi.fn(async (_url: string, _init?: RequestInit) =>
    Response.json({}),
  );
  const workerTarget = {
    workerId: "worker-a", workerTypeId: "chatgpt", workerName: "ChatGPT", spaceId: "P", threadId: "W",
    model: null, reasoningEffort: null, readOnly: true, permissions: ["repository:read"],
    profile: { definitionId: "chatgpt-codex", revision: 3, digest: "a".repeat(64) }, mcpWorker: null,
  };
  return {
    ...f,
    fetch,
    dispatch: (extra: Record<string, unknown> = {}) =>
      dispatchTaskAssignment(
        {
          SYNTILA_DB: f.db,
          SYNTILA_WORKER_GATEWAY: {
            idFromName: () => "worker-a",
            get: () => ({ fetch }),
            getByName: () => ({ fetch }),
          } as unknown as DurableObjectNamespace,
        },
        {
          workspaceId: null,
          runId: "RUN",
          taskId: "T",
          task: {
            id: "T",
            spaceId: "P",
            threadId: "W",
            requestedByUserId: "U",
            role: "collaborator",
            objective: "test",
            workRequestId: "R",
            workBindingId: "chat",
            sessionPolicy: "stateless",
            workerTarget,
            ...extra,
          },
        } as any,
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
      const conversation = (await f.sqlite
        .prepare("SELECT id FROM conversations")
        .get())!;
      await f.sqlite
        .prepare(
          `INSERT INTO conversation_history_entries
        (conversation_id,sequence,kind,event_type,actor_type,source_id,text,metadata_json,occurred_at)
        SELECT ?1,MAX(sequence)+1,'user_message','user_message','user','large-history',?2,'{}','now'
        FROM conversation_history_entries WHERE conversation_id=?1`,
        )
        .run(String(conversation.id), "x".repeat(bytes));
      // History over the transport budget is left out, never a failure: the
      // Worker's CLI reports a real context overflow itself.
      const result = await f.dispatch({
        conversationId: String(conversation.id),
        baseContextRevision: 0,
      });
      expect(result.accepted).toBe(true);
      const payload = JSON.parse(String(f.fetch.mock.calls[0]?.[1]?.body));
      const context = JSON.stringify(payload.payload);
      expect(context.includes("x".repeat(1024))).toBe(kept);
      expect(new TextEncoder().encode(context).byteLength).toBeLessThanOrEqual(
        256 * 1024,
      );
    } finally {
      await f.sqlite.close();
    }
  },
);

it("dispatches an inserted assignment despite conversation and history trigger writes", async () => {
  const f = await fixture();
  try {
    const result = await f.dispatch();
    expect(result.accepted).toBe(true);
    expect(f.fetch).toHaveBeenCalledTimes(1);
    expect(
      await f.sqlite
        .prepare("SELECT status FROM worker_assignments WHERE id=?")
        .get(result.assignmentId),
    ).toEqual({ status: "dispatched" });
    expect(
      await f.sqlite
        .prepare(
          "SELECT assignment_id FROM conversation_turns WHERE assignment_id=?",
        )
        .get(result.assignmentId),
    ).toEqual({ assignment_id: result.assignmentId });
    expect(
      await f.sqlite
        .prepare(
          "SELECT count(*) AS n FROM conversation_history_entries WHERE turn_id=?",
        )
        .get(`turn-${result.assignmentId}`),
    ).toEqual({ n: 1 });
  } finally {
    await f.sqlite.close();
  }
});

it("rejects an insert refused by an atomic capacity guard without sending to the Service", async () => {
  const f = await fixture();
  try {
    // Model a capacity race after selection: the insert itself admits no row.
    (await f.sqlite.exec(
      `CREATE FUNCTION full_capacity_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$;
       CREATE TRIGGER full_capacity BEFORE INSERT ON worker_assignments FOR EACH ROW EXECUTE FUNCTION full_capacity_fn()`,
    ));
    const result = await f.dispatch();
    expect(result).toMatchObject({
      accepted: false,
      status: "failed",
      assignmentId: "",
    });
    expect(result.error).toContain("capacity");
    expect(f.fetch).not.toHaveBeenCalled();
    expect(
      await f.sqlite.prepare("SELECT count(*) AS n FROM worker_assignments").get(),
    ).toEqual({ n: 0 });
    expect(
      await f.sqlite.prepare("SELECT count(*) AS n FROM conversation_turns").get(),
    ).toEqual({ n: 0 });
  } finally {
    await f.sqlite.close();
  }
});
