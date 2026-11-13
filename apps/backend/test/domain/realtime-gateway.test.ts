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

  it("parses scoped control messages and rejects missing workspace scope", () => {
    expect(
      parseRealtimeClientMessage({
        type: "subscribe",
        scope: { workspaceId: "workspace-1", spaceId: "space-1" },
      }),
    ).toEqual({
      type: "subscribe",
      scope: { workspaceId: "workspace-1", spaceId: "space-1" },
    });
    expect(() =>
      parseRealtimeClientMessage({ type: "subscribe", scope: {} }),
    ).toThrow("workspaceId");
    expect(() => parseRealtimeClientMessage({ type: "unknown" })).toThrow();
  });

  it("validates durable cursors by execution Workspace ID", () => {
    expect(
      parseRealtimeClientMessage({
        type: "realtime.hello",
        lastDurableSequences: { "workspace-1": 8, "workspace-2": 3 },
      }),
    ).toEqual({
      type: "realtime.hello",
      lastDurableSequences: { "workspace-1": 8, "workspace-2": 3 },
    });
    expect(() =>
      parseRealtimeClientMessage({
        type: "realtime.hello",
        lastDurableSequences: { "workspace-1": -1 },
      }),
    ).toThrow("Workspace IDs to non-negative integers");
  });

  it("matches events only within the requested scope", () => {
    expect(
      eventMatchesScope(
        {
          eventId: "event-1",
          type: "run.completed",
          version: "1.0",
          timestamp: "2026-09-23T00:00:00.000Z",
          workspaceId: "workspace-1",
          spaceId: "space-1",
          sequence: 1,
          payload: {},
        },
        { workspaceId: "workspace-1", spaceId: "space-1" },
      ),
    ).toBe(true);
    expect(
      eventMatchesScope(
        {
          eventId: "event-1",
          type: "run.completed",
          version: "1.0",
          timestamp: "2026-09-23T00:00:00.000Z",
          workspaceId: "workspace-2",
          sequence: 1,
          payload: {},
        },
        { workspaceId: "workspace-1" },
      ),
    ).toBe(false);
    expect(scopeKey({ workspaceId: "workspace-1" })).toBe(
      "workspaceId=workspace-1&spaceId=&runId=",
    );
  });

  it("parses user, Space, and execution Workspace scopes", () => {
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
    expect(
      parseRealtimeClientMessage({
        type: "subscribe",
        scope: {
          kind: "execution_workspace",
          executionWorkspaceId: "workspace-1",
        },
      }),
    ).toEqual({
      type: "subscribe",
      scope: {
        kind: "execution_workspace",
        executionWorkspaceId: "workspace-1",
      },
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
  });

  it("matches scopes by Space and execution Workspace identity", () => {
    const event = {
      eventId: "event-1",
      type: "run.completed",
      version: "1.0",
      timestamp: "2026-09-23T00:00:00.000Z",
      workspaceId: "workspace-1",
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
      eventMatchesScope(event, {
        kind: "execution_workspace",
        executionWorkspaceId: "workspace-1",
      }),
    ).toBe(true);
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

  it("requires Workspace ownership and validates active Space grants", async () => {
    const queries: string[] = [];
    const db = {
      prepare(query: string) {
        queries.push(query);
        return {
          bind(...args: unknown[]) {
            return {
              first: async () => {
                if (query.includes("execution_workspaces"))
                  return args[0] === "workspace-1" ? { owner: 1 } : null;
                if (query.includes("workspace_space_grants"))
                  return args[0] === "space-1" && args[1] === "workspace-1"
                    ? { granted: 1 }
                    : null;
                return null;
              },
            };
          },
        };
      },
    } as never;
    await expect(
      authorizeRealtimeScope(db, "user-1", {
        workspaceId: "workspace-1",
        spaceId: "space-1",
      }),
    ).resolves.toEqual({ allowed: true });
    await expect(
      authorizeRealtimeScope(db, "user-1", {
        workspaceId: "workspace-1",
        spaceId: "space-2",
      }),
    ).resolves.toEqual({ allowed: false, reason: "space_access_denied" });
    expect(
      queries.some((query) => query.includes("workspace_space_grants")),
    ).toBe(true);
    expect(
      queries.some((query) => query.includes("workspace_memberships")),
    ).toBe(false);
  });

  it("revalidates suspended users and removed subscriptions", async () => {
    const db = {
      prepare(query: string) {
        return {
          bind() {
            return {
              first: async () => {
                if (query.includes("FROM users")) return { status: "active" };
                if (query.includes("execution_workspaces")) return null;
                return null;
              },
            };
          },
        };
      },
    } as never;
    await expect(
      isRealtimeIdentityAuthorized(db, "user-1", [
        { workspaceId: "workspace-removed" },
      ]),
    ).resolves.toBe(false);
  });
});

describe("independent synchronization cursor delivery", () => {
  it("accepts stream cursors alongside legacy execution Workspace cursors", () => {
    const key = JSON.stringify(["space", "same"]);
    expect(
      parseRealtimeClientMessage({
        type: "realtime.hello",
        lastDurableSequences: { same: 10 },
        lastDurableStreamSequences: { [key]: 2 },
      }),
    ).toMatchObject({
      lastDurableSequences: { same: 10 },
      lastDurableStreamSequences: { [key]: 2 },
    });
    for (const bad of [
      { invalid: 1 },
      { '["space","p"]': -1 },
      { '["bogus","p"]': 1 },
    ]) {
      expect(() =>
        parseRealtimeClientMessage({
          type: "realtime.hello",
          lastDurableStreamSequences: bad,
        }),
      ).toThrow();
    }
  });
  it("matches collaboration signals to user/Space/Thread scopes without inventing Workspace access", () => {
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
    expect(
      eventMatchesScope(event, {
        kind: "execution_workspace",
        executionWorkspaceId: "same",
      }),
    ).toBe(false);
    expect(eventMatchesScope(event, { workspaceId: "same" })).toBe(false);
  });
});
