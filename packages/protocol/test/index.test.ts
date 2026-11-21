import { describe, expect, it } from "vitest";
import {
  isDurableRealtimeEventType,
  isEphemeralRealtimeEventType,
  isReplayableRealtimeEvent,
  parseRealtimeEvent,
} from "../src/index.js";

describe("realtime event contract", () => {
  const event = {
    eventId: "event-1",
    type: "run.completed",
    version: "1.0",
    timestamp: "2026-09-23T10:00:00.000Z",
    workspaceId: "workspace-1",
    spaceId: "space-1",
    runId: "run-1",
    sequence: 7,
    payload: { entityId: "run-1", status: "completed", summary: "Done" },
  };
  const activity = {
    ...event,
    type: "assignment.activity",
    assignmentId: "assignment-1",
    attemptId: "attempt-1",
    workspaceRuntimeId: "runtime-1",
    payload: {
      entityId: "assignment-1",
      workerId: "chatgpt",
      sourceEventId: "event-1",
      executionId: "execution-1",
      activityId: "tool-1",
      activitySequence: 4,
      activityType: "tool.started",
      activityStatus: "running",
      title: "Running tool",
      details: { toolName: "shell" },
    },
  };

  it("preserves the acceptance submission correlation ID", () => {
    const accepted = {
      ...event,
      type: "work_request.created",
      payload: {
        workRequestId: "request",
        threadId: "thread",
        submissionId: "opaque-submission",
        status: "queued",
      },
    };
    expect(parseRealtimeEvent(accepted)).toEqual(accepted);
  });

  it("accepts scoped Worker-first Work events and rejects missing or mismatched scope", () => {
    const workerEvent = {
      ...event,
      workspaceId: undefined,
      version: "1.1",
      type: "work_request.completed",
      spaceId: "space-1",
      stream: { kind: "space", id: "space-1" },
      payload: { workRequestId: "request", threadId: "thread", status: "completed" },
    };
    expect(parseRealtimeEvent(workerEvent)).toEqual(workerEvent);
    expect(() => parseRealtimeEvent({ ...workerEvent, stream: { kind: "space", id: "other" } })).toThrow();
    expect(() => parseRealtimeEvent({ ...workerEvent, payload: { status: "completed" } })).toThrow();
    expect(() => parseRealtimeEvent({ ...workerEvent, type: "run.completed" })).toThrow();
  });

  it("accepts current durable and ephemeral events", () => {
    expect(parseRealtimeEvent(JSON.stringify(event))).toEqual(event);
    expect(isDurableRealtimeEventType("run.completed")).toBe(true);
    expect(isEphemeralRealtimeEventType("stream.delta")).toBe(true);
    expect(isEphemeralRealtimeEventType("assignment.activity")).toBe(true);
  });

  it("accepts normalized activity payloads without raw provider content", () => {
    const parsed = parseRealtimeEvent(activity);
    expect(parsed).toEqual(activity);
    expect(isReplayableRealtimeEvent(parsed)).toBe(false);
    expect(
      isReplayableRealtimeEvent({
        ...parsed,
        payload: { ...parsed.payload, activityType: "model.status" },
      }),
    ).toBe(false);
  });

  it.each([
    ["missing attempt correlation", { ...activity, attemptId: undefined }],
    [
      "unknown activity type",
      {
        ...activity,
        payload: { ...activity.payload, activityType: "provider.unknown" },
      },
    ],
    [
      "oversized activity payload",
      {
        ...activity,
        payload: {
          ...activity.payload,
          details: Object.fromEntries(
            Array.from({ length: 10 }, (_, index) => [
              `field${index}`,
              "x".repeat(2048),
            ]),
          ),
        },
      },
    ],
  ])("rejects %s", (_name, input) => {
    expect(() => parseRealtimeEvent(input)).toThrow();
  });

  it("retains unknown events from a compatible minor version", () => {
    const unknown = parseRealtimeEvent({
      ...event,
      type: "future.new.fact",
      version: "1.1",
    });
    expect(unknown.type).toBe("future.new.fact");
  });

  it.each([
    ["missing sequence", { ...event, sequence: undefined }],
    ["negative sequence", { ...event, sequence: -1 }],
    ["major version", { ...event, version: "2.0" }],
    [
      "raw secret",
      { ...event, payload: { ...event.payload, rawApiKey: "secret" } },
    ],
    ["oversized delta", { ...event, payload: { delta: "x".repeat(8193) } }],
  ])("rejects %s", (_name, input) => {
    expect(() => parseRealtimeEvent(input)).toThrow();
  });
});

describe("collaboration streams", () => {
  const event = {
    eventId: "collab",
    type: "discussion.created",
    version: "1.1",
    timestamp: "2026-10-06T00:00:00.000Z",
    spaceId: "same-id",
    threadId: "w",
    stream: { kind: "space", id: "same-id" },
    sequence: 1,
    payload: { entityId: "m", threadId: "w" },
  };
  it("accepts ID-only collaboration signals with no execution Workspace", () => {
    expect(parseRealtimeEvent(event)).toEqual(event);
    expect(isDurableRealtimeEventType("discussion.created")).toBe(true);
    expect(isDurableRealtimeEventType("workspace_space_grant.updated")).toBe(
      true,
    );
  });
  it.each([
    { ...event, workspaceId: "same-id" },
    { ...event, stream: undefined },
    { ...event, stream: { kind: "space", id: "wrong-space" } },
    { ...event, stream: { kind: "execution_workspace", id: "same-id" } },
    { ...event, version: "1.0" },
    {
      ...event,
      payload: { entityId: "m", threadId: "w", text: "large history" },
    },
    { ...event, payload: { entityId: "m" } },
    { ...event, type: "work_request.created" },
  ])(
    "rejects ambiguous ownership or oversized entity-bearing signals",
    (input) => {
      expect(() => parseRealtimeEvent(input)).toThrow();
    },
  );
});

it("People updates carry only a peer ID in the authenticated user stream", () => {
  const signal = {
    eventId: "people-1",
    type: "people.updated",
    version: "1.1",
    timestamp: "2026-09-23T10:00:00.000Z",
    sequence: 1,
    stream: { kind: "user", id: "a" },
    payload: { entityId: "b" },
  };
  expect(parseRealtimeEvent(signal)).toEqual(signal);
  expect(() =>
    parseRealtimeEvent({
      ...signal,
      stream: { kind: "space", id: "A" },
      spaceId: "A",
    }),
  ).toThrow();
  expect(() =>
    parseRealtimeEvent({
      ...signal,
      payload: { entityId: "b", email: "private@test" },
    }),
  ).toThrow();
});
