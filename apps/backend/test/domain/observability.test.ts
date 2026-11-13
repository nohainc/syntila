import { describe, expect, it, vi } from "./helpers/vitest-compat";
import {
  isTrustedRealtimeOrigin,
  logDiagnosticEvent,
  requestIdFor,
  sanitizeDiagnostics,
  structuredLogRecord,
  tryLogDiagnosticEvent,
  tryLogTraceEvent,
} from "../../src/domain/observability.js";
import { parseDiagnosticEvent } from "@syntila/protocol";

describe("observability", () => {
  it("redacts secrets and bounds diagnostic values", () => {
    const result = sanitizeDiagnostics({
      apiKey: "do-not-export",
      nested: { authorization: "Bearer secret" },
      output: "x".repeat(600),
      items: Array.from({ length: 60 }, (_, index) => index),
    }) as Record<string, unknown>;

    expect(result.apiKey).toBe("[redacted]");
    expect((result.nested as Record<string, unknown>).authorization).toBe(
      "[redacted]",
    );
    expect(String(result.output)).toHaveLength(513);
    expect(result.items).toHaveLength(50);
  });

  it("never emits human or runtime credentials from credential-shaped fields", () => {
    const humanCredential = "syntila_dhs_human-secret";
    const runtimeCredential = "syntila_workspace_tok_runtime-secret";
    const record = structuredLogRecord(
      "info",
      "workspace.auth",
      {},
      {
        humanCredential,
        runtimeCredential,
        authorization: `Bearer ${humanCredential}`,
        nested: { bearer: runtimeCredential },
      },
    );
    expect(JSON.stringify(record)).not.toContain(humanCredential);
    expect(JSON.stringify(record)).not.toContain(runtimeCredential);
  });

  it("keeps end-to-end correlation fields in structured records", () => {
    const record = structuredLogRecord("info", "assignment.completed", {
      requestId: "request-1",
      eventId: "event-1",
      workspaceId: "workspace-1",
      runId: "run-1",
      taskId: "task-1",
      attemptId: "attempt-1",
      assignmentId: "assignment-1",
      workspaceRuntimeId: "host-1",
      workerId: "worker-1",
    });

    expect(record.correlation).toMatchObject({
      requestId: "request-1",
      eventId: "event-1",
      assignmentId: "assignment-1",
    });
  });

  it("creates a bounded correlated diagnostic event", () => {
    const event = logDiagnosticEvent({
      requestId: "request-1",
      assignmentId: "assignment-1",
      workspaceId: "workspace-1",
      component: "cloud",
      operation: "assignment",
      stage: "transport",
      severity: "error",
      errorCode: "provider_unavailable",
      retryable: true,
      context: {
        providerToolVersion: "1.2.3",
        status: "gateway_unavailable",
      },
    });

    expect(parseDiagnosticEvent(event)).toMatchObject({
      schemaVersion: 1,
      requestId: "request-1",
      assignmentId: "assignment-1",
      stage: "transport",
      retryable: true,
    });
  });

  it("rejects unexpected diagnostic context instead of redacting it", () => {
    expect(() =>
      logDiagnosticEvent({
        component: "cloud",
        operation: "assignment",
        stage: "provider_execution",
        severity: "error",
        retryable: false,
        context: {
          prompt: "private input",
          nested: { response: "private output" },
        } as never,
      }),
    ).toThrow();
  });

  it("keeps malformed telemetry from changing execution", () => {
    expect(
      tryLogDiagnosticEvent({
        component: "cloud",
        operation: "assignment",
        stage: "provider_execution",
        severity: "error",
        retryable: true,
        context: { modelId: "models/provider/model" } as never,
      }),
    ).toBeNull();
  });

  it("uses Cloudflare's generated Ray ID to correlate forwarded requests", () => {
    const request = new Request(
      "https://app.syntila.test/api/workspace-gateway/connect",
      { headers: { "cf-ray": "ray-123-lhr" } },
    );
    expect(requestIdFor(request)).toBe("ray-123-lhr");
    expect(requestIdFor(new Request(request))).toBe("ray-123-lhr");
  });

  it("requires a trusted Origin for browser realtime upgrades", () => {
    expect(
      isTrustedRealtimeOrigin(
        new Request("https://app.syntila.test/api/realtime", {
          headers: { origin: "https://evil.example" },
        }),
      ),
    ).toBe(false);
    expect(
      isTrustedRealtimeOrigin(
        new Request("https://api.syntila.test/api/realtime", {
          headers: { origin: "https://app.syntila.test" },
        }),
        ["https://app.syntila.test"],
      ),
    ).toBe(true);
  });

  it("emits a correlated latency-trace stage with bounded timing context", () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    try {
      tryLogTraceEvent({
        traceStage: "gateway_queued",
        requestId: "work-request-1",
        assignmentId: "assignment-1",
        runId: "run-1",
        taskId: "task-1",
        attemptId: "attempt-1",
        durationMs: 12.6,
        context: { transport: "websocket" },
      });
      expect(log).toHaveBeenCalledTimes(1);
      const record = JSON.parse(String(log.mock.calls[0]?.[0])) as {
        message: string;
        details: { event: unknown };
      };
      const event = parseDiagnosticEvent(record.details.event);
      expect(record.message).toBe("diagnostic.event");
      expect(event.stage).toBe("trace");
      expect(event.assignmentId).toBe("assignment-1");
      expect(event.context?.traceStage).toBe("gateway_queued");
      expect(event.context?.durationMs).toBe(13);
      expect(event.context?.transport).toBe("websocket");
      expect(event.context?.monotonicMs).toBeGreaterThanOrEqual(0);
    } finally {
      log.mockRestore();
    }
  });

  it("emits traces with the epoch-based Workers performance clock", () => {
    const clock = vi
      .spyOn(performance, "now")
      .mockReturnValue(1_791_982_359_278);
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    try {
      tryLogTraceEvent({
        traceStage: "cloud_accepted",
        requestId: "r1",
        durationMs: 12,
      });
      expect(log).toHaveBeenCalledTimes(1);
      const event = parseDiagnosticEvent(
        JSON.parse(String(log.mock.calls[0]?.[0])).details.event,
      );
      expect(event.context?.traceStage).toBe("cloud_accepted");
      expect(event.context?.durationMs).toBe(12);
      expect(event.context?.monotonicMs).toBeUndefined();
    } finally {
      clock.mockRestore();
      log.mockRestore();
    }
  });

  it("never lets a malformed trace event throw into the dispatch path", () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    try {
      expect(() =>
        tryLogTraceEvent({
          traceStage: "gateway_queued",
          assignmentId: "not a safe token!",
        }),
      ).not.toThrow();
      expect(log).not.toHaveBeenCalled();
    } finally {
      log.mockRestore();
    }
  });
});
