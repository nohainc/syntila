import { describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { member, space, user, workspace } from "./helpers/seed";
import { dataOf } from "../../src/platform/data.js";
import { createEventPublisher, type DomainEventInput } from "../../src/domain/event-publisher.js";
import { OutboxDispatcher } from "../../src/domain/outbox-dispatcher.js";

// ADR-033 (P2): commit first, notify second.

/** A realtime gateway namespace that records deliveries and can be made to fail. */
function gateway() {
  const calls: { name: string; eventId: string }[] = [];
  const state = { failing: false };
  const namespace = {
    getByName(name: string) {
      return {
        async fetch(request: Request) {
          if (state.failing) throw new Error("gateway down");
          const body = (await request.json()) as { eventId: string };
          calls.push({ name, eventId: body.eventId });
          return Response.json({ delivered: true });
        },
      };
    },
  } as unknown as DurableObjectNamespace;
  return { calls, state, namespace };
}

async function fixture(options: { withGateway?: boolean; max?: number } = {}) {
  const { db, sqlite } = await pgD1(options.max ? { max: options.max } : {});
  await sqlite.exec(
    [user("alice"), user("bob"), space("sp", "alice"), member("sp", "alice"), member("sp", "bob", "collaborator")].join("\n"),
  );
  const gw = gateway();
  const env = { SYNTILA_DB: db, ...(options.withGateway === false ? {} : { SYNTILA_REALTIME_GATEWAY: gw.namespace }) } as never;
  const q = dataOf({ SYNTILA_DB: db } as never).read;
  const event = (id: string, extra: Partial<DomainEventInput> = {}): DomainEventInput => ({
    eventId: id,
    type: "space.updated",
    spaceId: "sp",
    stream: { kind: "space", id: "sp" },
    payload: { entityId: "sp" },
    ...extra,
  });
  const outbox = async () =>
    (await sqlite.prepare("SELECT event_id, status, attempts, last_error, audience_json FROM outbox ORDER BY id").all()) as {
      event_id: string; status: string; attempts: number; last_error: string | null; audience_json: unknown;
    }[];
  const makeDue = () => sqlite.exec("UPDATE outbox SET next_attempt_at = now() - interval '1 second' WHERE status = 'pending'");
  return { sqlite, db, env, gw, q, event, outbox, makeDue, publish: (input: DomainEventInput, e: never = env) => createEventPublisher(e).publish(input) };
}

describe("one transaction: domain change, sequence, event and outbox", () => {
  it("commits all four together", async () => {
    const f = await fixture({ withGateway: false });
    await f.publish(f.event("e1", { mutate: (tx) => tx.run`UPDATE spaces SET name = 'renamed' WHERE id = 'sp'` }));
    const [space] = (await f.sqlite.prepare("SELECT name FROM spaces WHERE id = 'sp'").all()) as { name: string }[];
    const events = (await f.sqlite.prepare("SELECT sequence FROM realtime_events").all()) as { sequence: number }[];
    const cursor = (await f.sqlite.prepare("SELECT next_sequence FROM realtime_event_cursors").all()) as { next_sequence: number }[];
    expect(space!.name).toBe("renamed");
    expect(events.map((e) => Number(e.sequence))).toEqual([1]);
    expect(Number(cursor[0]!.next_sequence)).toBe(2);
    expect((await f.outbox()).map((o) => [o.event_id, o.status])).toEqual([["e1", "pending"]]);
  });

  it("rolls all four back when the domain write fails", async () => {
    const f = await fixture({ withGateway: false });
    await expect(
      f.publish(
        f.event("e1", {
          mutate: async (tx) => {
            await tx.run`UPDATE spaces SET name = 'renamed' WHERE id = 'sp'`;
            throw new Error("boom");
          },
        }),
      ),
    ).rejects.toThrow("boom");
    const [space] = (await f.sqlite.prepare("SELECT name FROM spaces WHERE id = 'sp'").all()) as { name: string }[];
    expect(space!.name).toBe("sp");
    expect(await f.sqlite.prepare("SELECT 1 FROM realtime_events").all()).toHaveLength(0);
    expect(await f.sqlite.prepare("SELECT 1 FROM realtime_event_cursors").all()).toHaveLength(0);
    expect(await f.outbox()).toHaveLength(0);
  });

  it("gives each event exactly one stream and one outbox row, also when published twice", async () => {
    const f = await fixture({ withGateway: false });
    await f.publish(f.event("e1"));
    const again = await f.publish(f.event("e1"));
    expect(again.persisted).toBe(false);
    expect(await f.outbox()).toHaveLength(1);
    const multi = await f.sqlite
      .prepare("SELECT event_id FROM realtime_events GROUP BY event_id HAVING count(DISTINCT (stream_kind, COALESCE(stream_id, workspace_id))) > 1")
      .all();
    expect(multi).toHaveLength(0);
  });

  it("accepts the thread, worker_inbox and assignment streams and rejects unknown kinds", async () => {
    const f = await fixture({ withGateway: false });
    for (const kind of ["thread", "worker_inbox", "assignment"] as const)
      await f.publish(
        f.event(
          `e-${kind}`,
          kind === "thread"
            ? { type: "thread.updated", threadId: "t-1", stream: { kind, id: "t-1" }, payload: { entityId: "sp", threadId: "t-1" } }
            : { stream: { kind, id: `${kind}-1` } },
        ),
      );
    const kinds = (await f.sqlite.prepare("SELECT stream_kind FROM realtime_events ORDER BY stream_kind").all()) as { stream_kind: string }[];
    expect(kinds.map((k) => k.stream_kind)).toEqual(["assignment", "thread", "worker_inbox"]);
    await expect(
      f.sqlite.exec(
        `INSERT INTO realtime_events (event_id, stream_kind, stream_id, sequence, event_type, payload_json, idempotency_key, occurred_at)
         VALUES ('bad', 'bogus', 'x', 1, 'space.updated', '{}', 'bad', now())`,
      ),
    ).rejects.toThrow();
  });

  it("numbers concurrent writers of one stream without gaps", async () => {
    const f = await fixture({ withGateway: false, max: 10 });
    await Promise.all(Array.from({ length: 40 }, (_, i) => f.publish(f.event(`e${i}`))));
    const events = (await f.sqlite.prepare("SELECT sequence FROM realtime_events ORDER BY sequence").all()) as { sequence: number }[];
    expect(events.map((e) => Number(e.sequence))).toEqual(Array.from({ length: 40 }, (_, i) => i + 1));
    const [cursor] = (await f.sqlite.prepare("SELECT next_sequence FROM realtime_event_cursors").all()) as { next_sequence: number }[];
    expect(Number(cursor!.next_sequence)).toBe(41);
    expect(await f.outbox()).toHaveLength(40);
  });
});

describe("delivery from the outbox", () => {
  it("delivers inline right after commit and marks the row delivered", async () => {
    const f = await fixture();
    const result = await f.publish(f.event("e1"));
    expect(result.deliveredSubscribers).toBe(2);
    expect(f.gw.calls.map((c) => c.name).sort()).toEqual(["user:alice", "user:bob"]);
    expect((await f.outbox()).map((o) => [o.status, Number(o.attempts)])).toEqual([["delivered", 1]]);
    // A repeated publish does not deliver again.
    expect((await f.publish(f.event("e1"))).deliveredSubscribers).toBe(0);
    expect(f.gw.calls).toHaveLength(2);
  });

  it("loses nothing when the process dies between commit and send", async () => {
    const f = await fixture({ withGateway: false }); // the commit happens, the send never does
    await f.publish(f.event("e1"));
    await f.publish(f.event("e2"));
    expect((await f.outbox()).map((o) => o.status)).toEqual(["pending", "pending"]);

    // A new process starts with a dispatcher. The fresh rows are still inside
    // the grace period that belongs to the inline path.
    const dispatcher = new OutboxDispatcher({ SYNTILA_DB: f.db, SYNTILA_REALTIME_GATEWAY: f.gw.namespace } as never);
    expect(await dispatcher.deliverDue()).toBe(0);
    await f.makeDue();
    expect(await dispatcher.deliverDue()).toBe(2);
    expect(f.gw.calls.filter((c) => c.name === "user:alice").map((c) => c.eventId)).toEqual(["e1", "e2"]);
    expect((await f.outbox()).map((o) => o.status)).toEqual(["delivered", "delivered"]);
    expect(await dispatcher.deliverDue()).toBe(0);
  });

  it("retries a failed delivery with backoff and marks it dead after the last attempt", async () => {
    const f = await fixture();
    f.gw.state.failing = true;
    const result = await f.publish(f.event("e1"));
    expect(result.deliveredSubscribers).toBe(0);
    const [row] = await f.outbox();
    expect([row!.status, Number(row!.attempts)]).toEqual(["pending", 1]);
    expect(row!.last_error).toContain("failed");

    const dispatcher = new OutboxDispatcher({ SYNTILA_DB: f.db, SYNTILA_REALTIME_GATEWAY: f.gw.namespace } as never);
    expect(await dispatcher.deliverDue()).toBe(0); // backoff has not passed
    f.gw.state.failing = false;
    await f.makeDue();
    expect(await dispatcher.deliverDue()).toBe(1);
    expect((await f.outbox())[0]!.status).toBe("delivered");

    // A row that keeps failing ends as dead.
    await f.publish(f.event("e2"));
    f.gw.state.failing = true;
    await f.sqlite.exec("UPDATE outbox SET status = 'pending', delivered_at = NULL, attempts = 11, next_attempt_at = now() - interval '1 second' WHERE event_id = 'e2'");
    await dispatcher.deliverDue();
    expect((await f.outbox()).find((o) => o.event_id === "e2")!.status).toBe("dead");
  });

  it("delivers to the audience captured at commit, not the current members", async () => {
    const f = await fixture({ withGateway: false });
    await f.publish(f.event("e1", { recipientUserIds: ["bob"], additionalRecipientUserIds: ["carol"] }));
    await f.makeDue();
    const dispatcher = new OutboxDispatcher({ SYNTILA_DB: f.db, SYNTILA_REALTIME_GATEWAY: f.gw.namespace } as never);
    expect(await dispatcher.deliverDue()).toBe(1);
    expect(f.gw.calls.map((c) => c.name).sort()).toEqual(["user:bob", "user:carol"]);
  });

  it("does not hand one row to two dispatchers", async () => {
    const f = await fixture({ withGateway: false });
    for (let i = 0; i < 6; i++) await f.publish(f.event(`e${i}`));
    await f.makeDue();
    const env = { SYNTILA_DB: f.db, SYNTILA_REALTIME_GATEWAY: f.gw.namespace } as never;
    await Promise.all([new OutboxDispatcher(env).deliverDue(), new OutboxDispatcher(env).deliverDue()]);
    const perUser = f.gw.calls.filter((c) => c.name === "user:alice").map((c) => c.eventId).sort();
    expect(perUser).toEqual(["e0", "e1", "e2", "e3", "e4", "e5"]);
  });
});

describe("outbox sweep", () => {
  const insertEvent = (id: string, sequence: number) =>
    `INSERT INTO realtime_events (event_id, stream_kind, stream_id, sequence, event_type, payload_json, idempotency_key, occurred_at, space_id)
     VALUES ('${id}', 'space', 'sp', ${sequence}, 'space.updated', '{"entityId":"sp"}', '${id}', now(), 'sp');`;

  it("repairs events without an outbox row and reports sequence gaps", async () => {
    const f = await fixture({ withGateway: false });
    await f.sqlite.exec(insertEvent("direct-1", 1) + insertEvent("direct-3", 3));
    const dispatcher = new OutboxDispatcher(f.env);
    const first = await dispatcher.sweep();
    expect(first!.repaired).toBe(2);
    expect(first!.gaps).toEqual([{ kind: "space", id: "sp", sequence: 3, previous: 1 }]);
    expect((await dispatcher.sweep())!.repaired).toBe(0);
    expect((await f.outbox()).map((o) => o.event_id).sort()).toEqual(["direct-1", "direct-3"]);
  });
});

describe("Worker command inbox", () => {
  async function commandFixture() {
    const f = await fixture({ withGateway: false });
    await f.sqlite.exec(`
      ${workspace("WS", "alice")}
      INSERT INTO workspace_runtime_identities(id,workspace_id,credential_token_hash,installation_id,created_at) VALUES('RT','WS','h','inst',now());
      INSERT INTO workspace_worker_inventory (worker_id, workspace_id, owner_user_id, worker_type_id, activation_state, readiness_state,
        local_concurrency_limit, revision, created_at, updated_at, last_seen_at)
      VALUES ('worker-cmd-01', 'WS', 'alice', 'chatgpt', 'enabled', 'ready', 1, 1, now(), now(), now());`);
    const assignment = (id: string) =>
      f.sqlite.exec(`INSERT INTO worker_assignments
        (id,space_id,execution_workspace_id,runtime_identity_id,worker_type_id,workspace_worker_id,status,permission_snapshot_json,session_policy,created_at,updated_at)
        VALUES ('${id}','sp','WS','RT','chatgpt','worker-cmd-01','created','{}','stateless',now(),now())`);
    const command = (id: string) =>
      f.sqlite
        .prepare(`INSERT INTO agent_commands (command_id, worker_instance_id, assignment_id, attempt_id, type, payload_ref, expires_at)
          SELECT 'cmd-${id}', a.worker_instance_id, a.id, 'attempt-${id}', 'assignment.dispatch', 'worker_assignments:' || a.id, now() + interval '1 hour'
            FROM worker_assignments a WHERE a.id = '${id}' ON CONFLICT (assignment_id, type) DO NOTHING`)
        .run();
    const status = async (id: string) =>
      ((await f.sqlite.prepare("SELECT status, sent_at, acked_at, worker_instance_id FROM agent_commands WHERE assignment_id = ?").get(id)) as
        { status: string; sent_at: unknown; acked_at: unknown; worker_instance_id: string | null });
    const move = (id: string, to: string) => f.sqlite.exec(`UPDATE worker_assignments SET status = '${to}', updated_at = now() WHERE id = '${id}'`);
    return { ...f, assignment, command, status, move };
  }

  it("addresses the command to the Worker Instance and exists once per assignment", async () => {
    const f = await commandFixture();
    await f.assignment("a1");
    expect((await f.command("a1")).changes).toBe(1);
    expect((await f.command("a1")).changes).toBe(0);
    const row = await f.status("a1");
    expect(row).toMatchObject({ status: "pending", worker_instance_id: "worker-cmd-01" });
  });

  it("follows the assignment forward only", async () => {
    const f = await commandFixture();
    for (const id of ["a1", "a2", "a3", "a4"]) {
      await f.assignment(id);
      await f.command(id);
    }
    await f.move("a1", "dispatched");
    expect(await f.status("a1")).toMatchObject({ status: "sent" });
    expect((await f.status("a1")).sent_at).not.toBeNull();
    await f.move("a1", "running");
    expect(await f.status("a1")).toMatchObject({ status: "acked" });
    expect((await f.status("a1")).acked_at).not.toBeNull();
    await f.move("a1", "failed"); // the outcome is the assignment's; the command stays acked
    expect(await f.status("a1")).toMatchObject({ status: "acked" });

    await f.move("a2", "failed");
    expect(await f.status("a2")).toMatchObject({ status: "failed" });
    await f.move("a3", "dispatched");
    await f.move("a3", "timed_out");
    expect(await f.status("a3")).toMatchObject({ status: "expired" });
    await f.move("a4", "cancelled");
    expect(await f.status("a4")).toMatchObject({ status: "cancelled" });
  });

  it("expires commands past their deadline in the sweep", async () => {
    const f = await commandFixture();
    await f.assignment("a1");
    await f.sqlite.exec(`INSERT INTO agent_commands (command_id, assignment_id, type, payload_ref, created_at, expires_at)
      VALUES ('cmd-old', 'a1', 'assignment.dispatch', 'worker_assignments:a1', now() - interval '2 minutes', now() - interval '1 minute')`);
    const swept = await new OutboxDispatcher(f.env).sweep();
    expect(swept!.expiredCommands).toBe(1);
    expect(await f.status("a1")).toMatchObject({ status: "expired" });
  });
});
