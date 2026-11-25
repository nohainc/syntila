import { describe, expect, it } from "vitest";
import {
  ASSIGNMENT_STARTUP_STAGE_RANK,
  ASSIGNMENT_STARTUP_STAGES,
  DIAGNOSTIC_PROBE_ECHO_MAX_CHARS,
  parseWorkspaceRuntimeMessage,
  SERVICE_PROBE_PAYLOAD_CAPABILITY,
  WORKSPACE_RUNTIME_PROTOCOL_NAME,
  WORKSPACE_RUNTIME_PROTOCOL_VERSION,
} from "../src/index.js";

const base = {
  protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
  protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
  messageId: "message-1",
  timestamp: "2026-09-24T12:00:00.000Z",
  payload: { snapshot: { workerTypeId: "chatgpt" }, input: {} },
};

describe("Workspace Runtime protocol", () => {
  it("carries no file content in the input wake-up", () => {
    const wake = {
      ...base,
      type: "input.available",
      executionWorkspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      payload: {},
    };
    expect(parseWorkspaceRuntimeMessage(wake).type).toBe("input.available");
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...wake,
        payload: { contentBase64: "aGVsbG8=" },
      }),
    ).toThrow(/payload/);
  });

  it("uses Workspace lifecycle message names", () => {
    expect(
      parseWorkspaceRuntimeMessage({ ...base, type: "workspace.hello" }).type,
    ).toBe("workspace.hello");
  });

  it("requires both execution and runtime identity on assignments", () => {
    expect(() =>
      parseWorkspaceRuntimeMessage({ ...base, type: "assignment.start" }),
    ).toThrow(/executionWorkspaceId/);
    expect(
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "assignment.start",
        executionWorkspaceId: "workspace-a",
        workspaceRuntimeId: "runtime-a",
        workerId: "worker-a",
        runId: "run-a",
        taskId: "task-a",
        attemptId: "attempt-a",
        assignmentId: "assignment-a",
        idempotencyKey: "idem-a",
        payload: { snapshot: { workerTypeId: "chatgpt" }, input: {} },
      }).type,
    ).toBe("assignment.start");
  });

  it("accepts bounded structured activity assignments", () => {
    expect(
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "assignment.activity",
        executionWorkspaceId: "workspace-a",
        workspaceRuntimeId: "runtime-a",
        workerId: "worker-a",
        runId: "run-a",
        taskId: "task-a",
        attemptId: "attempt-a",
        assignmentId: "assignment-a",
        idempotencyKey: "idem-a",
        payload: {
          assignmentId: "assignment-a",
          executionId: "execution-a",
          workerId: "chatgpt",
          eventId: "event-a",
          sequence: 3,
          timestamp: "2026-10-12T12:00:00.000Z",
          eventType: "tool.started",
          status: "running",
          title: "Running tool",
          activityId: "tool-a",
          details: { toolName: "shell" },
        },
      }).type,
    ).toBe("assignment.activity");
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "assignment.activity",
        executionWorkspaceId: "workspace-a",
        workspaceRuntimeId: "runtime-a",
        workerId: "worker-a",
        runId: "run-a",
        taskId: "task-a",
        attemptId: "attempt-a",
        assignmentId: "assignment-a",
        idempotencyKey: "idem-a",
        payload: {
          assignmentId: "assignment-a",
          executionId: "execution-a",
          workerId: "chatgpt",
          eventId: "event-a",
          sequence: 3,
          timestamp: "2026-10-12T12:00:00.000Z",
          eventType: "tool.started",
          status: "running",
          title: "Running tool",
          details: { prompt: "do not forward" },
        },
      }),
    ).toThrow();
  });

  it("requires explicit Engine and provider startup evidence", () => {
    const correlation = {
      executionWorkspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      workerId: "worker-a",
      runId: "run-a",
      taskId: "task-a",
      attemptId: "attempt-a",
      assignmentId: "assignment-a",
      idempotencyKey: "idem-a",
    };
    expect(
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "assignment.start.ack",
        ...correlation,
        payload: {
          started: true,
          engineStarted: true,
          providerStarted: true,
        },
      }).type,
    ).toBe("assignment.start.ack");
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "assignment.start.ack",
        ...correlation,
        payload: {
          started: true,
          engineStarted: true,
          providerStarted: false,
        },
      }),
    ).toThrow();
  });

  it("validates assignment startup progress payloads", () => {
    const parse = (payload: unknown) =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "assignment.startup",
        executionWorkspaceId: "workspace-a",
        workspaceRuntimeId: "runtime-a",
        workerId: "worker-a",
        runId: "run-a",
        taskId: "task-a",
        attemptId: "attempt-a",
        assignmentId: "assignment-a",
        idempotencyKey: "idem-a",
        payload,
      });
    expect(parse({ stage: "profile_ready" }).type).toBe("assignment.startup");
    expect(
      parse({
        stage: "queued_for_slot",
        queuePosition: 2,
        activeSlots: 1,
        slotLimit: 1,
        waitingForSession: true,
        queueWaitTimeoutMs: 120000,
        profileDigest: "a".repeat(64),
        profileRevision: 3,
      }).type,
    ).toBe("assignment.startup");
    expect(ASSIGNMENT_STARTUP_STAGES).not.toContain("provider_started");
    expect(ASSIGNMENT_STARTUP_STAGE_RANK.slot_reserved).toBeGreaterThan(
      ASSIGNMENT_STARTUP_STAGE_RANK.queued_for_slot,
    );
    expect(() => parse({ stage: "bogus" })).toThrow();
    expect(() => parse({ stage: "slot_reserved", extra: 1 })).toThrow();
    expect(() =>
      parse({ stage: "profile_ready", profileDigest: "xyz" }),
    ).toThrow();
    expect(() =>
      parse({ stage: "queued_for_slot", queuePosition: 0 }),
    ).toThrow();
  });

  it("validates Service readiness payloads", () => {
    const parse = (payload: unknown) =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "workspace.readiness",
        executionWorkspaceId: "workspace-a",
        workspaceRuntimeId: "runtime-a",
        payload,
      });
    expect(
      parse({ state: "ready", readyForAssignments: true, syncGeneration: 3 })
        .type,
    ).toBe("workspace.readiness");
    expect(
      parse({
        state: "draining",
        readyForAssignments: false,
        syncGeneration: 3,
        reason: "shutdown",
      }).type,
    ).toBe("workspace.readiness");
    // Only the ready state may accept assignments.
    expect(() =>
      parse({ state: "paused", readyForAssignments: true, syncGeneration: 1 }),
    ).toThrow();
    expect(() =>
      parse({ state: "bogus", readyForAssignments: false, syncGeneration: 1 }),
    ).toThrow();
    expect(() =>
      parse({ state: "ready", readyForAssignments: true, syncGeneration: -1 }),
    ).toThrow();
    expect(() =>
      parse({
        state: "ready",
        readyForAssignments: true,
        syncGeneration: 1,
        extra: true,
      }),
    ).toThrow();
  });

  it("validates start permit request and grant payloads", () => {
    const correlation = {
      executionWorkspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      workerId: "worker-a",
      runId: "run-a",
      taskId: "task-a",
      attemptId: "attempt-a",
      assignmentId: "assignment-a",
      idempotencyKey: "idem-a",
    };
    const parse = (type: string, payload: unknown) =>
      parseWorkspaceRuntimeMessage({ ...base, type, ...correlation, payload });
    expect(parse("assignment.start.permit.request", {}).type).toBe(
      "assignment.start.permit.request",
    );
    expect(() =>
      parse("assignment.start.permit.request", { extra: true }),
    ).toThrow();
    expect(
      parse("assignment.start.permit.grant", {
        granted: true,
        permitId: "permit-a",
        expiresAt: "2026-01-01T00:00:30.000Z",
      }).type,
    ).toBe("assignment.start.permit.grant");
    expect(() =>
      parse("assignment.start.permit.grant", { granted: true }),
    ).toThrow();
    expect(
      parse("assignment.start.permit.grant", {
        granted: false,
        reason: "revoked",
      }).type,
    ).toBe("assignment.start.permit.grant");
    expect(() =>
      parse("assignment.start.permit.grant", { granted: false }),
    ).toThrow();
  });

  it("accepts only canonical execution permissions in assignment snapshots", () => {
    const assignment = {
      ...base,
      type: "assignment.start",
      executionWorkspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      workerId: "worker-a",
      runId: "run-a",
      taskId: "task-a",
      attemptId: "attempt-a",
      assignmentId: "assignment-a",
      idempotencyKey: "idem-a",
      payload: {
        snapshot: {
          workerTypeId: "chatgpt",
          permissions: ["repository:read", "repository:write"],
          permissionSnapshot: {
            permissions: ["repository:read", "repository:write"],
          },
        },
        input: {},
      },
    };
    expect(parseWorkspaceRuntimeMessage(assignment).type).toBe(
      "assignment.start",
    );
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...assignment,
        payload: {
          snapshot: {
            workerTypeId: "chatgpt",
            permissions: ["workspace:read"],
            permissionSnapshot: { permissions: ["workspace:read"] },
          },
          input: {},
        },
      }),
    ).toThrow();
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...assignment,
        payload: {
          snapshot: {
            workerTypeId: "chatgpt",
            permissions: ["repository:read"],
            permissionSnapshot: { permissions: ["repository:write"] },
          },
          input: {},
        },
      }),
    ).toThrow(/permission fields must match/);
  });

  it("rejects removed Checkout control-plane messages", () => {
    for (const type of [
      "checkout.provision",
      "checkout.status",
      "checkout.recover",
      "checkout.archive",
      "checkout.finalize",
    ]) {
      expect(() => parseWorkspaceRuntimeMessage({ ...base, type })).toThrow();
    }
  });

  it("accepts logical Thread readiness without a local path", () => {
    expect(
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "thread.status",
        payload: {
          spaceId: "space-1",
          threadId: "thread-1",
          workingDirectoryState: "ready",
        },
      }).type,
    ).toBe("thread.status");
  });

  it("accepts an optional bounded Workspace-wide parallelSlots total", () => {
    const parse = (payload: unknown) =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "worker.inventory",
        payload,
      });
    expect(parse({ workers: [], fullSnapshot: true }).type).toBe(
      "worker.inventory",
    );
    expect(
      parse({ workers: [], parallelSlots: 5, fullSnapshot: true }).type,
    ).toBe("worker.inventory");
    for (const parallelSlots of [0, -1, 1.5, 1025, "5"]) {
      expect(() =>
        parse({ workers: [], parallelSlots, fullSnapshot: true }),
      ).toThrow();
    }
  });

  it("accepts only path-free Allowed Folder summaries", () => {
    const parse = (allowedFolders: unknown) =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "worker.inventory",
        payload: { workers: [], allowedFolders, fullSnapshot: true },
      });
    const folder = {
      id: "folder-0123456789abcdef",
      displayName: "api",
      status: "read_only",
      checkedAt: "2026-10-25T12:00:00.123456Z",
    };
    expect(parse([folder]).type).toBe("worker.inventory");
    expect(parse([]).type).toBe("worker.inventory");
    for (const invalid of [
      [{ ...folder, path: "/Users/me/api" }],
      [{ ...folder, id: "../etc" }],
      [{ ...folder, status: "writable" }],
      [{ ...folder, displayName: "" }],
      [{ ...folder, displayName: "a\nb" }],
      Array.from({ length: 33 }, () => folder),
    ]) {
      expect(() => parse(invalid)).toThrow();
    }
  });

  it("accepts only bounded safe Worker inventory projections", () => {
    const worker = {
      workerId: "worker-a",
      workerTypeId: "chatgpt",
      activationState: "enabled",
      readinessState: "setup_required",
      readinessIssueCode: "setup_required",
      engineVersion: "1.0.0",
      profileDefinitionId: "chatgpt-codex",
      profileReleaseVersion: 1,
      providerToolName: "codex",
      providerToolVersion: null,
      localConcurrencyLimit: 1,
      revision: 1,
      createdAt: "2026-09-24T12:00:00.000Z",
      updatedAt: "2026-09-24T12:00:00.000Z",
      lastSeenAt: "2026-09-24T12:00:00.000Z",
    };
    expect(
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "worker.inventory",
        payload: { workers: [worker], fullSnapshot: true },
      }).type,
    ).toBe("worker.inventory");
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "worker.inventory",
        payload: {
          workers: [{ ...worker, capabilities: ["code"] }],
          fullSnapshot: true,
        },
      }),
    ).toThrow();
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "worker.inventory",
        payload: {
          workers: [{ ...worker, providerToolPath: "/local/only/codex" }],
          fullSnapshot: true,
        },
      }),
    ).toThrow();
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "worker.inventory",
        payload: {
          workers: [{ ...worker, providerToolName: "/Users/local/codex" }],
          fullSnapshot: true,
        },
      }),
    ).toThrow();
    expect(
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "worker.inventory",
        payload: {
          workers: [
            {
              ...worker,
              readinessState: "not_probed",
              readinessIssueCode: "probe_required",
            },
          ],
          fullSnapshot: true,
        },
      }).type,
    ).toBe("worker.inventory");
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "worker.inventory",
        payload: {
          workers: [{ ...worker, readinessIssueCode: "api_key=secret" }],
          fullSnapshot: true,
        },
      }),
    ).toThrow();
    for (const obsoleteField of ["providerToolPath"]) {
      expect(() =>
        parseWorkspaceRuntimeMessage({
          ...base,
          type: "worker.inventory",
          payload: {
            workers: [{ ...worker, [obsoleteField]: "must-not-sync" }],
            fullSnapshot: true,
          },
        }),
      ).toThrow();
    }
    for (const providerCliName of ["codex", "antigravity"]) {
      expect(() =>
        parseWorkspaceRuntimeMessage({
          ...base,
          type: "worker.inventory",
          payload: {
            workers: [{ ...worker, workerTypeId: providerCliName }],
            fullSnapshot: true,
          },
        }),
      ).toThrow();
    }
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "worker.inventory",
        payload: {
          workers: [{ ...worker, apiKey: "never-sync-this" }],
          fullSnapshot: true,
        },
      }),
    ).toThrow();
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...base,
        protocolVersion: "5.0",
        type: "worker.inventory",
        payload: { workers: [worker], fullSnapshot: true },
      }),
    ).toThrow(/requires Workspace protocol 5.1/);
  });

  it("requires logical Worker types in Cloud assignment snapshots", () => {
    const assignment = {
      ...base,
      type: "assignment.start",
      executionWorkspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      workerId: "worker-a",
      runId: "run-a",
      taskId: "task-a",
      attemptId: "attempt-a",
      assignmentId: "assignment-a",
      idempotencyKey: "idem-a",
      payload: { snapshot: { workerTypeId: "chatgpt" }, input: {} },
    };
    expect(parseWorkspaceRuntimeMessage(assignment).type).toBe(
      "assignment.start",
    );
    for (const providerCliName of ["codex", "antigravity"]) {
      expect(() =>
        parseWorkspaceRuntimeMessage({
          ...assignment,
          payload: { snapshot: { workerTypeId: providerCliName }, input: {} },
        }),
      ).toThrow();
    }
  });

  it("accepts only canonical assignment error codes", () => {
    const identity = {
      executionWorkspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      workerId: "worker-a",
      runId: "run-a",
      taskId: "task-a",
      attemptId: "attempt-a",
      assignmentId: "assignment-a",
      idempotencyKey: "idem-a",
    };
    const assignmentError = {
      ...base,
      ...identity,
      type: "assignment.error",
      payload: {
        status: "failed",
        error: {
          code: "permission_denied",
          message:
            "A local permission required for this assignment was denied.",
          retryable: false,
        },
      },
    };
    expect(parseWorkspaceRuntimeMessage(assignmentError).type).toBe(
      "assignment.error",
    );
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...assignmentError,
        payload: {
          ...assignmentError.payload,
          error: {
            ...assignmentError.payload.error,
            code: "tool_permission_denied",
          },
        },
      }),
    ).toThrow();
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...assignmentError,
        payload: {
          ...assignmentError.payload,
          error: {
            ...assignmentError.payload.error,
            message: "provider stderr: secret diagnostic",
          },
        },
      }),
    ).toThrow(/canonical safe message/);
    const withProvider = {
      ...assignmentError,
      payload: {
        ...assignmentError.payload,
        providerFailure: {
          schemaVersion: 1,
          source: "structured_error",
          providerErrorText: "error",
          failedRunResponse: "partial",
        },
      },
    };
    expect(parseWorkspaceRuntimeMessage(withProvider).payload).toMatchObject(
      withProvider.payload,
    );
    expect(
      parseWorkspaceRuntimeMessage({
        ...assignmentError,
        payload: {
          ...assignmentError.payload,
          providerFailureUnavailable: true,
        },
      }).payload,
    ).toMatchObject({ providerFailureUnavailable: true });
    for (const invalid of [false, "true"]) {
      expect(() =>
        parseWorkspaceRuntimeMessage({
          ...assignmentError,
          payload: {
            ...assignmentError.payload,
            providerFailureUnavailable: invalid,
          },
        }),
      ).toThrow();
    }
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...withProvider,
        payload: { ...withProvider.payload, providerFailureUnavailable: true },
      }),
    ).toThrow();
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...withProvider,
        payload: {
          ...withProvider.payload,
          providerFailure: {
            schemaVersion: 1,
            source: "stderr",
            providerErrorText: "x".repeat(4097),
          },
        },
      }),
    ).toThrow();
  });

  it("validates optional base64 echo on diagnostic.probe and diagnostic.probe.ack", () => {
    expect(SERVICE_PROBE_PAYLOAD_CAPABILITY).toBe("workspace.probe_payload.v1");
    expect(DIAGNOSTIC_PROBE_ECHO_MAX_CHARS).toBe(65_536);

    const parseProbe = (payload: Record<string, unknown>) =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "diagnostic.probe",
        payload: {
          probeId: "probe-1",
          sentAt: "2026-10-12T12:00:00.000Z",
          ...payload,
        },
      });
    const parseAck = (payload: Record<string, unknown>) =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "diagnostic.probe.ack",
        payload: {
          probeId: "probe-1",
          receivedAt: "2026-10-12T12:00:00.000Z",
          ackedAt: "2026-10-12T12:00:00.001Z",
          ...payload,
        },
      });

    expect(parseProbe({}).type).toBe("diagnostic.probe");
    expect(parseAck({}).type).toBe("diagnostic.probe.ack");

    expect(parseProbe({ echo: "YWJjZA==" }).type).toBe("diagnostic.probe");
    expect(parseAck({ echo: "YWJjZA==" }).type).toBe("diagnostic.probe.ack");
    expect(parseAck({ traceEpochId: "trace-1760000000000000-1234" }).type).toBe("diagnostic.probe.ack");
    expect(() => parseAck({ traceEpochId: "not valid!" })).toThrow();

    const maxEcho = "A".repeat(DIAGNOSTIC_PROBE_ECHO_MAX_CHARS);
    expect(parseProbe({ echo: maxEcho }).type).toBe("diagnostic.probe");
    expect(parseAck({ echo: maxEcho }).type).toBe("diagnostic.probe.ack");

    for (const invalidEcho of [
      "",
      "not base64!",
      "YWJj\n",
      "====",
      "A".repeat(DIAGNOSTIC_PROBE_ECHO_MAX_CHARS + 1),
      123,
    ]) {
      expect(() => parseProbe({ echo: invalidEcho })).toThrow();
      expect(() => parseAck({ echo: invalidEcho })).toThrow();
    }
    expect(() => parseProbe({ unknownField: "x" })).toThrow();
    expect(() => parseAck({ unknownField: "x" })).toThrow();
  });
});
