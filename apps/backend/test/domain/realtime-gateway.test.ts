import { pgD1, recordStatements } from "./helpers/pg-d1";
import { space, user } from "./helpers/seed";
import { describe, expect, it } from "./helpers/vitest-compat";
import {
  authorizeRealtimeScope,
  eventMatchesScope,
  isRealtimeIdentityAuthorized,
  parseRealtimeClientMessage,
  realtimeAuthenticationError,
  reconnectDelayMs,
  requiresRealtimeReconnect,
  scopeKey,
} from "../../src/domain/realtime-gateway.js";
import { BoundedRealtimeQueue } from "../../src/domain/realtime-queue.js";

const identity = {
  userId: "user-1",
  email: "user@example.com",
  name: "User",
  sessionId: "session-1",
};

describe("realtime gateway contract", () => {
  it("rejects signed-out or suspended identities and accepts active sessions", () => {
    expect(realtimeAuthenticationError(null)).toBe("Authentication required");
    expect(realtimeAuthenticationError(identity, "suspended")).toBe(
      "User account is suspended",
    );
    expect(realtimeAuthenticationError(identity, "active")).toBeNull();
  });

  it("parses user, Space, and Thread scopes and rejects unknown scopes", () => {
    expect(
      parseRealtimeClientMessage({
        type: "subscribe",
        scope: { kind: "user" },
      }),
    ).toEqual({ type: "subscribe", scope: { kind: "user" } });
    expect(
      parseRealtimeClientMessage({
        type: "subscribe",
        scope: { kind: "space", spaceId: "space-1" },
      }),
    ).toEqual({
      type: "subscribe",
      scope: { kind: "space", spaceId: "space-1" },
    });
    expect(scopeKey({ kind: "space", spaceId: "space-1" })).toBe(
      "space=space-1",
    );
    expect(scopeKey({ kind: "thread", threadId: "thread-1" })).toBe(
      "thread=thread-1",
    );
    expect(
      parseRealtimeClientMessage({
        type: "subscribe",
        scope: { kind: "thread", threadId: "thread-1" },
      }),
    ).toEqual({
      type: "subscribe",
      scope: { kind: "thread", threadId: "thread-1" },
    });
    expect(() =>
      parseRealtimeClientMessage({ type: "subscribe", scope: {} }),
    ).toThrow();
    expect(() => parseRealtimeClientMessage({ type: "unknown" })).toThrow();
  });

  it("matches scopes by user, Space, and Thread identity", () => {
    const event = {
      eventId: "event-1",
      type: "run.completed",
      version: "1.1",
      timestamp: "2026-09-23T00:00:00.000Z",
      spaceId: "space-1",
      sequence: 1,
      payload: {},
    } as const;
    expect(eventMatchesScope(event, { kind: "user" })).toBe(true);
    expect(
      eventMatchesScope(event, { kind: "space", spaceId: "space-1" }),
    ).toBe(true);
    expect(
      eventMatchesScope(event, { kind: "space", spaceId: "space-2" }),
    ).toBe(false);
    expect(
      eventMatchesScope(
        { ...event, threadId: "thread-1" },
        { kind: "thread", threadId: "thread-1" },
      ),
    ).toBe(true);
    expect(
      eventMatchesScope(
        { ...event, threadId: "thread-2" },
        { kind: "thread", threadId: "thread-1" },
      ),
    ).toBe(false);
  });

  it("uses bounded exponential reconnect backoff with jitter", () => {
    expect(reconnectDelayMs(0, 0)).toBe(375);
    expect(reconnectDelayMs(3, 1)).toBe(5000);
    expect(reconnectDelayMs(99, 0)).toBe(22500);
  });

  it("detects durable sequence gaps for HTTP resync", () => {
    expect(requiresRealtimeReconnect(null, 4)).toBe(false);
    expect(requiresRealtimeReconnect(3, 4)).toBe(false);
    expect(requiresRealtimeReconnect(3, 5)).toBe(true);
  });

  it("coalesces ephemeral progress and preserves durable frames in a bounded queue", () => {
    const queue = new BoundedRealtimeQueue(2);
    expect(
      queue.enqueue({
        frame: "progress-1",
        durable: false,
        coalesceKey: "run-1",
      }),
    ).toBe("queued");
    expect(
      queue.enqueue({
        frame: "progress-2",
        durable: false,
        coalesceKey: "run-1",
      }),
    ).toBe("coalesced");
    expect(queue.enqueue({ frame: "domain-1", durable: true })).toBe("queued");
    expect(queue.enqueue({ frame: "domain-2", durable: true })).toBe("queued");
    expect(queue.enqueue({ frame: "domain-3", durable: true })).toBe(
      "resync-required",
    );
    expect(queue.drain().map((item) => item.frame)).toEqual([
      "domain-1",
      "domain-2",
    ]);
  });

  it("drops noisy ephemeral frames once the queue is full", () => {
    const queue = new BoundedRealtimeQueue(1);
    expect(queue.enqueue({ frame: "status-1", durable: false })).toBe("queued");
    expect(queue.enqueue({ frame: "status-2", durable: false })).toBe(
      "dropped",
    );
    expect(queue.depth).toBe(1);
  });

  it("revalidates suspended users and removed subscriptions", async () => {
    const { db, sqlite } = await pgD1();
    await sqlite.exec(user("user-1"));
    await expect(
      isRealtimeIdentityAuthorized(db, "user-1", [
        { kind: "space", spaceId: "space-removed" },
      ]),
    ).resolves.toBe(false);
    // Control: the same user with no subscriptions to revalidate stays authorized.
    await expect(isRealtimeIdentityAuthorized(db, "user-1", [])).resolves.toBe(true);
    await sqlite.exec("UPDATE users SET status = 'suspended' WHERE id = 'user-1'");
    await expect(isRealtimeIdentityAuthorized(db, "user-1", [])).resolves.toBe(false);
  });
});

describe("independent synchronization cursor delivery", () => {
  it("matches collaboration signals to user/Space/Thread scopes", () => {
    const event = {
      eventId: "e",
      type: "discussion.created",
      version: "1.1",
      timestamp: "2026-10-06T00:00:00.000Z",
      stream: { kind: "space", id: "same" },
      spaceId: "same",
      threadId: "w",
      sequence: 1,
      payload: { entityId: "m", threadId: "w" },
    } as const;
    expect(eventMatchesScope(event, { kind: "user" })).toBe(true);
    expect(eventMatchesScope(event, { kind: "space", spaceId: "same" })).toBe(
      true,
    );
    expect(eventMatchesScope(event, { kind: "thread", threadId: "w" })).toBe(
      true,
    );
  });
});
