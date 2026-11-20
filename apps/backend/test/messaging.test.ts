import { expect, test } from "bun:test";
import { buildEnvelope, FrameError, parseCommandFrame, MESSAGING_PROTOCOL } from "../src/domain/messaging/envelope";
import { bucketFor, mayIssueCommand, mayUseStream } from "../src/domain/messaging/principal";
import { SubscriptionRegistry } from "../src/domain/messaging/subscription-registry";
import { commandToLegacy, legacyToEnvelope } from "../src/domain/messaging/bridge";

const human = { kind: "human", id: "alice" } as const;
const worker = { kind: "worker", id: "w1" } as const;
const thread = { kind: "thread", id: "t1" } as const;
const allow = async () => true;
const ev = (sequence: number) => buildEnvelope({ type: "message.created", stream: thread, sequence, payload: {} });

const frame = (extra: Record<string, unknown> = {}) => ({ protocol: MESSAGING_PROTOCOL, requestId: "r1", type: "command", command: "assignment.ack", payload: {}, ...extra });

test("a command frame is strict and never carries an identity", () => {
  expect(parseCommandFrame(JSON.stringify(frame())).command).toBe("assignment.ack");
  for (const bad of [{ protocol: "x" }, { actorId: "someone" }, { payload: { userId: "u" } }, { command: "Bad Command" }, { requestId: "" }, { payload: [] }])
    expect(() => parseCommandFrame(frame(bad))).toThrow(FrameError);
  expect(() => parseCommandFrame("x".repeat(300_000))).toThrow(FrameError);
});

test("principals have separate scopes, commands and rates", () => {
  expect(mayUseStream(worker, { kind: "worker_inbox", id: "w1" })).toBe(true);
  expect(mayUseStream(worker, { kind: "worker_inbox", id: "w2" })).toBe(false);
  expect(mayUseStream(worker, thread)).toBe(false);
  expect(mayUseStream(human, { kind: "user", id: "bob" })).toBe(false);
  expect(mayUseStream(human, thread)).toBe(true);
  expect(mayIssueCommand(human, "assignment.result")).toBe(false);
  expect(mayIssueCommand(worker, "assignment.result")).toBe(true);
  let now = 0;
  const bucket = bucketFor(human, () => now);
  let taken = 0;
  while (bucket.take()) taken++;
  expect(taken).toBe(60);
  now += 1000;
  expect(bucket.take()).toBe(true);
});

test("bootstrap loses no event: buffered events above the snapshot arrive once, in order", async () => {
  const r = new SubscriptionRegistry();
  const sub = await r.subscribe("c1", human, thread, allow, async () => 10);
  expect(sub).toMatchObject({ ok: true, headSequence: 10 });
  // events arrive while the client fetches its snapshot (taken at 12)
  for (const n of [13, 11, 12, 13]) expect(r.publish(ev(n))).toEqual([]);
  const applied = r.completeBootstrap("c1", thread, 12);
  expect(applied.map((e) => e.sequence)).toEqual([13]);
  expect(r.publish(ev(13))).toEqual([]); // duplicate
  expect(r.publish(ev(14)).map((d) => d.envelope.sequence)).toEqual([14]);
  expect(r.ack("c1", thread, 15)).toBe(false); // cannot ack what was never sent
  expect(r.ack("c1", thread, 14)).toBe(true);
});

test("a subscription is checked once and removed the moment access is revoked", async () => {
  const r = new SubscriptionRegistry();
  expect(await r.subscribe("c1", human, thread, async () => false, async () => 0)).toEqual({ ok: false, reason: "access_denied" });
  expect(await r.subscribe("c2", worker, thread, allow, async () => 0)).toEqual({ ok: false, reason: "stream_not_permitted" });
  await r.subscribe("c3", human, thread, allow, async () => 0);
  r.completeBootstrap("c3", thread, 0);
  const removed = r.revoke((p, s) => p.id === "alice" && s.kind === "thread" && s.id === "t1");
  expect(removed).toEqual([{ connectionId: "c3", stream: thread }]);
  expect(r.publish(ev(1))).toEqual([]);
  expect(r.count()).toBe(0);
});

test("the bridge maps unified commands to legacy messages and back, without trusting client ids", () => {
  const f = parseCommandFrame(frame({ payload: { assignmentId: "a1", attemptId: "t1", accepted: true } }));
  const legacy = commandToLegacy(f, "worker:w1", { protocolName: "p", protocolVersion: "5.1" });
  expect(legacy).toMatchObject({ type: "assignment.ack", assignmentId: "a1", attemptId: "t1", executionWorkspaceId: "worker:w1", payload: { accepted: true } });
  const out = legacyToEnvelope({ type: "assignment.cancel", assignmentId: "a1", messageId: "m1", payload: { reason: "x" } }, "w1");
  expect(out).toMatchObject({ protocol: MESSAGING_PROTOCOL, eventId: "m1", stream: { kind: "assignment", id: "a1" }, payload: { reason: "x", assignmentId: "a1" } });
});

import { MessagingSession } from "../src/domain/messaging/session";

test("a session subscribes, bootstraps, acknowledges and is denied what it may not read", async () => {
  const registry = new SubscriptionRegistry();
  const space = { kind: "space", id: "s1" } as const;
  const session = new MessagingSession("c1", human, {
    registry, authorize: async (_p, s) => s.id === "s1", head: async () => 5, supports: (s) => s.kind === "space" || s.kind === "user",
  });
  const cmd = (command: string, payload: Record<string, unknown>, requestId = "r") => JSON.stringify({ protocol: MESSAGING_PROTOCOL, requestId, type: "command", command, payload });
  expect((await session.handle(cmd("subscription.subscribe", { stream: space })))[0]).toMatchObject({ type: "subscription.ready", payload: { headSequence: 5 } });
  expect((await session.handle(cmd("subscription.subscribe", { stream: { kind: "space", id: "other" } })))[0]).toMatchObject({ type: "subscription.denied", payload: { reason: "access_denied" } });
  expect((await session.handle(cmd("subscription.subscribe", { stream: thread })))[0]).toMatchObject({ payload: { reason: "stream_not_supported" } });
  expect((await session.handle(cmd("assignment.result", {})))[0]).toMatchObject({ payload: { code: "command_not_permitted" } });
  expect((await session.handle(cmd("session.ping", { actorId: "x" })))[0]).toMatchObject({ payload: { code: "forged_identity" } });
  registry.publish({ ...ev(6), stream: space });
  expect(await session.handle(cmd("subscription.snapshot_applied", { stream: space, snapshotSequence: 5 }))).toHaveLength(1);
  expect(await session.handle(cmd("event.ack", { stream: space, sequence: 6 }))).toEqual([]);
  expect((await session.handle(cmd("event.ack", { stream: space, sequence: 99 })))[0]).toMatchObject({ type: "sync.required" });
});

test("a cursor resumes from the events it missed, or falls back to a snapshot", async () => {
  const mk = (replay: (s: unknown, a: number, t: number) => Promise<any>) => {
    const registry = new SubscriptionRegistry();
    return new MessagingSession("c2", human, {
      registry, authorize: async () => true, head: async () => 10, supports: () => true, replay: replay as never,
    });
  };
  const cmd = (payload: Record<string, unknown>) => JSON.stringify({ protocol: MESSAGING_PROTOCOL, requestId: "r", type: "command", command: "subscription.subscribe", payload });
  const stream = { kind: "thread", id: "t1" } as const;
  const log = async (_s: unknown, after: number, through: number) => Array.from({ length: through - after }, (_, i) => ({ ...ev(after + 1 + i), stream }));

  const resumed = await mk(log).handle(cmd({ stream, cursor: 7 }));
  expect(resumed[0]).toMatchObject({ payload: { resumed: true, headSequence: 10 } });
  expect(resumed.slice(1).map((e) => e.sequence)).toEqual([8, 9, 10]);

  expect((await mk(log).handle(cmd({ stream, cursor: 10 })))).toHaveLength(1);
  const gap = await mk(async () => null).handle(cmd({ stream, cursor: 3 }));
  expect(gap.map((e) => e.type)).toEqual(["subscription.ready", "sync.required"]);
  expect(gap[1]).toMatchObject({ payload: { reason: "replay_unavailable" } });
  expect((await mk(log).handle(cmd({ stream, cursor: 11 })))[1]).toMatchObject({ payload: { reason: "cursor_ahead" } });
  expect((await mk(log).handle(cmd({ stream, cursor: -1 })))[1]).toMatchObject({ payload: { reason: "cursor_invalid" } });
});
