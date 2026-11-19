import { pgD1 } from "./helpers/pg-d1";
import { member as membership, space, user } from "./helpers/seed";
import { describe, expect, it } from "./helpers/vitest-compat";
import { RealtimeGateway, parseRealtimeClientMessage } from "../../src/domain/realtime-gateway.js";
import { BoundedRealtimeQueue } from "../../src/domain/realtime-queue.js";
import type { RealtimeEventEnvelope } from "@syntila/protocol";

// ADR-033 decisions 6 and 9: cursor semantics and bounded queues.

// Collaboration signals carry identifiers only, so sized frames use an execution event.
const SPACE_KEY = JSON.stringify(["execution_workspace", "same"]);

describe("bounded queue", () => {
  it("is bounded in bytes as well as in items", () => {
    const queue = new BoundedRealtimeQueue(100, 100);
    expect(queue.enqueue({ frame: "x".repeat(60), durable: true })).toBe("queued");
    expect(queue.byteSize).toBe(60);
    // 120 bytes do not fit and there is no ephemeral frame to give up.
    expect(queue.enqueue({ frame: "y".repeat(60), durable: true })).toBe("resync-required");
    expect(queue.byteSize).toBe(60);
    expect(queue.enqueue({ frame: "z".repeat(10), durable: false })).toBe("queued");
    // A durable frame displaces the ephemeral one.
    expect(queue.enqueue({ frame: "w".repeat(35), durable: true })).toBe("queued");
    expect(queue.byteSize).toBe(95);
    expect(queue.depth).toBe(2);
  });

  it("drops an oversized ephemeral frame and asks for a resync for an oversized durable one", () => {
    const queue = new BoundedRealtimeQueue(10, 50);
    expect(queue.enqueue({ frame: "e".repeat(60), durable: false })).toBe("dropped");
    expect(queue.enqueue({ frame: "d".repeat(60), durable: true })).toBe("resync-required");
    expect([queue.depth, queue.byteSize]).toEqual([0, 0]);
  });

  it("keeps the byte count exact through coalescing, take, drain and clear", () => {
    const queue = new BoundedRealtimeQueue(10, 100);
    queue.enqueue({ frame: "a".repeat(10), durable: false, coalesceKey: "k" });
    expect(queue.enqueue({ frame: "b".repeat(30), durable: false, coalesceKey: "k" })).toBe("coalesced");
    expect(queue.byteSize).toBe(30);
    // A replacement that no longer fits removes the stale frame and is dropped.
    expect(queue.enqueue({ frame: "c".repeat(200), durable: false, coalesceKey: "k" })).toBe("dropped");
    expect([queue.depth, queue.byteSize]).toEqual([0, 0]);
    queue.enqueue({ frame: "abc", durable: true });
    queue.enqueue({ frame: "de", durable: true });
    expect(queue.take()?.frame).toBe("abc");
    expect(queue.byteSize).toBe(2);
    queue.drain();
    expect(queue.byteSize).toBe(0);
    queue.enqueue({ frame: "abc", durable: true });
    queue.clear();
    expect([queue.depth, queue.byteSize]).toEqual([0, 0]);
  });
});

describe("acknowledgement message", () => {
  it("parses a stream acknowledgement and rejects bad ones", () => {
    expect(
      parseRealtimeClientMessage({ type: "ack", stream: { kind: "space", id: "s" }, sequence: 4 }),
    ).toEqual({ type: "ack", stream: { kind: "space", id: "s" }, sequence: 4 });
    expect(() => parseRealtimeClientMessage({ type: "ack", stream: { kind: "space", id: "s" }, sequence: -1 })).toThrow();
    expect(() => parseRealtimeClientMessage({ type: "ack", stream: { kind: "nope", id: "s" }, sequence: 1 })).toThrow();
  });
});

async function harness() {
  const frames: Record<string, unknown>[] = [];
  const socket = {
    readyState: 1,
    bufferedAmount: 0,
    backpressured: false,
    onDrain: undefined as undefined | (() => void),
    sendStatus: 1,
    send(text: string) {
      frames.push(JSON.parse(text));
      return socket.sendStatus;
    },
    close() {
      frames.push({ type: "closed" });
    },
  };
  const enqueued = new Map<string, number>();
  const { db, sqlite } = await pgD1();
  await sqlite.exec(user("owner") + user("other") + space("same", "other") + membership("same", "owner", "collaborator"));
  const writes: unknown[] = [];
  const state = {
    storage: {
      list: async () => new Map(),
      put: async (_key: string, value: unknown) => void writes.push(value),
      delete: async () => {},
    },
  };
  const gateway = new RealtimeGateway(state as never, { SYNTILA_DB: db } as never);
  const clients = Reflect.get(gateway, "clients") as Map<string, any>;
  const client = {
    socket,
    identity: { userId: "owner" },
    subscriptions: new Map([["user", { kind: "user" }]]),
    lastEnqueuedSequences: enqueued,
    appliedSequences: new Map<string, number>(),
    queue: new BoundedRealtimeQueue(),
    flushScheduled: false,
    resyncPending: false as boolean | undefined,
  };
  clients.set("client", client);
  Reflect.get(gateway, "bindDrain").call(gateway, client);
  const publish = (event: RealtimeEventEnvelope) =>
    gateway.fetch(new Request("https://realtime.internal/publish", { method: "POST", body: JSON.stringify(event) }));
  const event = (sequence: number, size = 100): RealtimeEventEnvelope => ({
    eventId: `run-${sequence}`,
    type: "run.completed",
    version: "1.0",
    timestamp: "2026-10-06T00:00:00.000Z",
    workspaceId: "same",
    stream: { kind: "execution_workspace", id: "same" },
    sequence,
    payload: { entityId: "same", message: "m".repeat(size) },
  });
  const handle = (message: unknown) =>
    (Reflect.get(gateway, "handleClientMessage") as (id: string, data: unknown) => Promise<void>).call(
      gateway,
      "client",
      JSON.stringify(message),
    );
  const metrics = async () => (await (await gateway.fetch(new Request("https://realtime.internal/metrics"))).json()) as Record<string, number>;
  const eventSequences = () =>
    frames.filter((f) => f.type === "event").map((f) => (f.event as { sequence: number }).sequence);
  return { frames, socket, client, enqueued, writes, publish, event, handle, metrics, eventSequences };
}

describe("a slow client", () => {
  it("keeps memory bounded by items and sends one sync signal", async () => {
    const f = await harness();
    f.socket.bufferedAmount = 10_000_000; // the socket never drains
    for (let sequence = 1; sequence <= 600; sequence++) await f.publish(f.event(sequence, 2_000));
    const signals = f.frames.filter((frame) => frame.type === "reconnect.required");
    expect(signals).toHaveLength(1);
    expect(signals[0]).toMatchObject({ reason: "connection_queue_limit", stream: { kind: "execution_workspace", id: "same" } });
    expect(f.eventSequences()).toEqual([]); // nothing was pushed into a blocked socket
    expect(f.client.queue.depth).toBe(0); // cleared, and nothing joins it until the client resyncs
    expect(f.client.queue.byteSize).toBe(0);
    expect(f.client.resyncPending).toBe(true);
    const metrics = await f.metrics();
    expect(metrics.queueOverflows).toBe(1);
    expect(metrics.maxQueueDepth).toBeLessThanOrEqual(128);
    expect(metrics.maxQueueBytes).toBeLessThanOrEqual(1024 * 1024);
  });

  it("keeps memory bounded by bytes when frames are large", async () => {
    const f = await harness();
    f.socket.bufferedAmount = 10_000_000;
    for (let sequence = 1; sequence <= 200; sequence++) await f.publish(f.event(sequence, 30_000));
    const metrics = await f.metrics();
    expect(metrics.maxQueueDepth).toBeLessThan(128); // the byte limit came first
    expect(metrics.maxQueueBytes).toBeLessThanOrEqual(1024 * 1024);
    expect(metrics.queueOverflows).toBe(1);
  });

  it("forgets what it counted as enqueued and takes frames again after the client's hello", async () => {
    const f = await harness();
    f.socket.bufferedAmount = 10_000_000;
    for (let sequence = 1; sequence <= 140; sequence++) await f.publish(f.event(sequence));
    expect(f.enqueued.size).toBe(0); // cleared frames were never sent, so they are not "enqueued"
    f.socket.bufferedAmount = 0;
    await f.handle({ type: "realtime.hello", lastDurableStreamSequences: { [SPACE_KEY]: 149 } });
    expect(f.client.resyncPending).toBe(false);
    await f.publish(f.event(150));
    expect(f.eventSequences()).toEqual([150]);
  });

  it("resumes the queue when the runtime reports a drain", async () => {
    const f = await harness();
    f.socket.bufferedAmount = 10_000_000;
    f.socket.backpressured = true;
    for (const sequence of [1, 2, 3]) await f.publish(f.event(sequence));
    expect(f.eventSequences()).toEqual([]);
    expect(f.client.queue.depth).toBe(3);
    f.socket.bufferedAmount = 0;
    f.socket.backpressured = false;
    f.socket.onDrain!();
    expect(f.eventSequences()).toEqual([1, 2, 3]);
    expect(f.client.queue.depth).toBe(0);
  });

  it("closes a socket whose runtime dropped a frame", async () => {
    const f = await harness();
    f.socket.sendStatus = 0;
    await f.publish(f.event(1));
    expect(f.frames.at(-1)).toEqual({ type: "closed" });
  });
});

describe("cursor semantics", () => {
  it("keeps the enqueued position apart from the applied acknowledgement", async () => {
    const f = await harness();
    for (const sequence of [1, 2, 3]) await f.publish(f.event(sequence));
    expect(f.enqueued.get(SPACE_KEY)).toBe(3);
    expect(f.client.appliedSequences.size).toBe(0); // delivery is not an acknowledgement

    await f.handle({ type: "ack", stream: { kind: "execution_workspace", id: "same" }, sequence: 2 });
    expect(f.client.appliedSequences.get(SPACE_KEY)).toBe(2);
    expect(f.enqueued.get(SPACE_KEY)).toBe(3);
    await f.handle({ type: "ack", stream: { kind: "execution_workspace", id: "same" }, sequence: 1 }); // never moves back
    expect(f.client.appliedSequences.get(SPACE_KEY)).toBe(2);
  });

  it("takes the client's hello as its applied position", async () => {
    const f = await harness();
    await f.handle({ type: "realtime.hello", lastDurableStreamSequences: { [SPACE_KEY]: 7 } });
    expect(f.client.appliedSequences.get(SPACE_KEY)).toBe(7);
    expect(f.enqueued.get(SPACE_KEY)).toBe(7);
  });

  it("answers an invalid acknowledgement without changing anything", async () => {
    const f = await harness();
    await f.handle({ type: "ack", stream: { kind: "execution_workspace", id: "same" }, sequence: -3 });
    expect(f.frames.at(-1)).toMatchObject({ type: "subscription.denied" });
    expect(f.client.appliedSequences.size).toBe(0);
  });

  it("does not write cursors to storage per event", async () => {
    const f = await harness();
    for (let sequence = 1; sequence <= 50; sequence++) await f.publish(f.event(sequence));
    expect(f.eventSequences()).toHaveLength(50);
    expect(f.writes.length).toBeLessThanOrEqual(1); // at most the first sync of the subscription list
    expect(JSON.stringify(f.writes)).not.toContain("cursors");
  });
});
