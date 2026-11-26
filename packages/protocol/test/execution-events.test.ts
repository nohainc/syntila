import { describe, expect, it } from "vitest";
import { normalizeActivityPayload, parseExecutionEvent } from "../src/index.js";

const baseEvent = {
  protocol: "syntila.execution-events",
  protocolVersion: "1.0",
  schemaVersion: 1,
  eventId: "event-1",
  eventType: "tool.started",
  category: "activity",
  delivery: "replayable",
  threadId: "thread-1",
  workRequestId: "request-1",
  runId: "run-1",
  taskId: "task-1",
  assignmentId: "assignment-1",
  attemptId: "attempt-1",
  executionId: "execution-1",
  workerId: "chatgpt",
  sequence: 12,
  occurredAt: "2026-10-14T12:00:00.000Z",
  payload: {
    title: "Running tests",
    status: "running",
    activityId: "tool-1",
    details: { toolName: "test" },
  },
};

describe("normalized execution event contract", () => {
  it("accepts fully correlated replayable activity", () => {
    expect(parseExecutionEvent(baseEvent)).toEqual(baseEvent);
  });

  it("requires terminal delivery for lifecycle outcomes", () => {
    const event = {
      ...baseEvent,
      eventType: "execution.failed",
      category: "lifecycle",
      delivery: "terminal",
      payload: { title: "Execution failed", status: "failed" },
    };
    expect(parseExecutionEvent(event)).toEqual(event);
    expect(() =>
      parseExecutionEvent({ ...event, delivery: "ephemeral" }),
    ).toThrow();
  });

  it("keeps execution.started as replayable activity", () => {
    const event = {
      ...baseEvent,
      eventType: "execution.started",
      payload: { title: "Starting execution", status: "running" },
    };
    expect(parseExecutionEvent(event)).toEqual(event);
  });

  it("rejects incomplete correlation and provider content", () => {
    expect(() =>
      parseExecutionEvent({ ...baseEvent, attemptId: undefined }),
    ).toThrow();
    expect(() =>
      parseExecutionEvent({
        ...baseEvent,
        payload: { ...baseEvent.payload, details: { command: "npm test" } },
      }),
    ).toThrow();
  });

  it("keeps explicit tool metadata and filters unsafe provider details", () => {
    expect(
      normalizeActivityPayload({
        title: "Running command",
        status: "running",
        activityId: "tool-1",
        toolId: "tool-1",
        toolName: "shell",
        details: {
          toolKind: "command_execution",
          command: "should be dropped",
          credential: "should be dropped",
        },
      }),
    ).toEqual({
      title: "Running command",
      status: "running",
      activityId: "tool-1",
      toolId: "tool-1",
      toolName: "shell",
      details: { toolKind: "command_execution" },
    });
  });
});
