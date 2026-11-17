import { pgD1 } from "./helpers/pg-d1";
import { user, workspace } from "./helpers/seed";
import { afterEach, describe, expect, it, vi } from "./helpers/vitest-compat";
import { hashToken } from "@syntila/security";
import {
  isCurrentWorkspaceSocket,
  isWorkspaceRuntimeAuthorized,
  normalizeWorkspaceWorkerInstallationStatus,
  WorkspaceGateway,
  workspaceAssignmentContextMatches,
} from "../../src/domain/workspace-gateway.js";

/** A real database holding one Workspace and the runtime identity that holds `credentialTokenHash`. */
function runtimeDatabase(
  workspaceId: string,
  runtimeId: string,
  credentialTokenHash: string,
) {
  const { db, sqlite } = pgD1();
  sqlite.exec(user("owner") + workspace(workspaceId, "owner"));
  sqlite
    .prepare(
      `INSERT INTO workspace_runtime_identities (id, workspace_id, installation_id, credential_token_hash, created_at)
       VALUES (?, ?, 'installation', ?, now())`,
    )
    .run(runtimeId, workspaceId, credentialTokenHash);
  return { db, sqlite };
}

/**
 * Completes a Service's synchronization over the HTTP fallback and publishes
 * it as ready, then returns the poll cursor after the sync result so a test
 * sees only the commands it triggers.
 */
async function publishReady(
  gateway: WorkspaceGateway,
  input: {
    token: string;
    sessionId: string;
    workspaceId: string;
    runtimeId: string;
  },
): Promise<string> {
  const headers = {
    authorization: `Bearer ${input.token}`,
    "content-type": "application/json",
  };
  const messages: Array<[string, Record<string, unknown>]> = [
    [
      "workspace.hello",
      { capabilities: { customCapabilities: ["assignment.start_permit.v1"] } },
    ],
    ["workspace.sync.request", {}],
    [
      "workspace.readiness",
      { state: "ready", readyForAssignments: true, syncGeneration: 1 },
    ],
  ];
  let counter = 0;
  for (const [type, payload] of messages) {
    counter += 1;
    const at = new Date().toISOString();
    const response = await gateway.fetch(
      new Request("https://gateway.internal/runtime/events", {
        method: "POST",
        headers,
        body: JSON.stringify({
          sessionId: input.sessionId,
          events: [
            {
              contract: "syntila.desktop-auth-transport",
              version: "1.0",
              eventId: `ready-${input.sessionId}-${counter}`,
              occurredAt: at,
              message: {
                protocol: "syntila.workspace-runtime-protocol",
                protocolVersion: "5.1",
                messageId: `ready-message-${input.sessionId}-${counter}`,
                timestamp: at,
                type,
                executionWorkspaceId: input.workspaceId,
                workspaceRuntimeId: input.runtimeId,
                payload,
              },
            },
          ],
        }),
      }),
    );
    const body = (await response.json()) as { rejected?: unknown[] };
    expect(response.status).toBe(200);
    expect(body.rejected ?? []).toEqual([]);
  }
  const drained = await gateway.fetch(
    new Request("https://gateway.internal/runtime/poll", {
      method: "POST",
      headers,
      body: JSON.stringify({
        sessionId: input.sessionId,
        cursor: "0",
        waitMs: 0,
      }),
    }),
  );
  return ((await drained.json()) as { cursor: string }).cursor;
}

describe("Workspace runtime Gateway", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("deduplicates replayed runtime events across HTTP session recreation", async () => {
    const token = "runtime-secret-replay";
    const credentialTokenHash = await hashToken(token);
    const workspaceId = "workspace-replay";
    const { db } = runtimeDatabase(workspaceId, "runtime-replay", credentialTokenHash);
    const storage = new Map<string, unknown>();
    const state = {
      id: { name: workspaceId },
      storage: {
        get: async (key: string) => storage.get(key),
        put: async (key: string, value: unknown) => {
          storage.set(key, value);
        },
        delete: async (key: string) => storage.delete(key),
      },
    };
    const gateway = new WorkspaceGateway(state as never, {
      SYNTILA_DB: db as never,
    });
    const createSession = async () => {
      const response = await gateway.fetch(
        new Request("https://gateway.internal/runtime/sessions", {
          method: "POST",
          headers: {
            authorization: `Bearer ${token}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            workspaceRuntimeId: "runtime-replay",
            contractVersion: "1.0",
          }),
        }),
      );
      expect(response.status).toBe(200);
      return (await response.json()) as { sessionId: string; cursor: string };
    };
    const firstSession = await createSession();
    const replayedEvent = {
      contract: "syntila.desktop-auth-transport",
      version: "1.0",
      eventId: "stable-replay-event-id",
      occurredAt: new Date().toISOString(),
      message: {
        protocol: "syntila.workspace-runtime-protocol",
        protocolVersion: "5.1",
        messageId: "stable-protocol-message-id",
        timestamp: new Date().toISOString(),
        type: "workspace.heartbeat",
        executionWorkspaceId: workspaceId,
        workspaceRuntimeId: "runtime-replay",
        payload: {},
      },
    };
    const postEvent = (sessionId: string) =>
      gateway.fetch(
        new Request("https://gateway.internal/runtime/events", {
          method: "POST",
          headers: {
            authorization: `Bearer ${token}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({ sessionId, events: [replayedEvent] }),
        }),
      );
    const firstPost = await postEvent(firstSession.sessionId);
    expect(await firstPost.json()).toMatchObject({
      acceptedEventIds: ["stable-replay-event-id"],
      rejected: [],
    });

    const nextSession = await createSession();
    const replay = await postEvent(nextSession.sessionId);
    expect(await replay.json()).toMatchObject({
      acceptedEventIds: ["stable-replay-event-id"],
      rejected: [],
    });
    const poll = await gateway.fetch(
      new Request("https://gateway.internal/runtime/poll", {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          sessionId: nextSession.sessionId,
          cursor: nextSession.cursor,
          waitMs: 0,
        }),
      }),
    );
    expect(await poll.json()).toMatchObject({ events: [], timedOut: true });
  });

  it("logs DO upgrade checkpoints with the forwarded request correlation ID", async () => {
    const runtimeToken = "runtime-secret-for-gateway-test";
    const credentialTokenHash = await hashToken(runtimeToken);
    const workspaceId = "workspace-gateway-test";
    let resolveHelloAck!: (message: string) => void;
    const helloAck = new Promise<string>((resolve) => {
      resolveHelloAck = resolve;
    });
    class TestSocket {
      attachment?: unknown;
      serializeAttachment(value: unknown) {
        this.attachment = value;
      }
      deserializeAttachment() {
        return this.attachment;
      }
      send(message: string) {
        if (
          (JSON.parse(message) as { type?: string }).type ===
          "workspace.hello.ack"
        ) {
          resolveHelloAck(message);
        }
      }
      close() {}
    }
    let acceptedSocket: TestSocket | undefined;
    class TestWebSocketPair {
      0 = new TestSocket();
      1 = new TestSocket();
    }
    class TestResponse {
      readonly status: number;
      readonly webSocket?: unknown;
      constructor(
        _body: unknown,
        init?: { status?: number; webSocket?: unknown },
      ) {
        this.status = init?.status ?? 200;
        this.webSocket = init?.webSocket;
      }
      static json(body: unknown, init?: { status?: number }) {
        return new TestResponse(body, init);
      }
    }
    vi.stubGlobal("WebSocketPair", TestWebSocketPair);
    vi.stubGlobal("Response", TestResponse);
    const { db } = runtimeDatabase(workspaceId, "runtime-gateway-test", credentialTokenHash);
    const state = {
      id: { name: workspaceId },
      storage: {
        get: async () => undefined,
        put: async () => undefined,
        delete: async () => undefined,
      },
      acceptWebSocket(socket: unknown) {
        acceptedSocket = socket as TestSocket;
      },
    };
    const gateway = new WorkspaceGateway(state as never, {
      SYNTILA_DB: db as never,
    });
    const logs: string[] = [];
    vi.spyOn(console, "log").mockImplementation((record) => {
      logs.push(String(record));
    });
    vi.spyOn(console, "warn").mockImplementation((record) => {
      logs.push(String(record));
    });
    vi.spyOn(console, "error").mockImplementation((record) => {
      logs.push(String(record));
    });

    const response = (await gateway.fetch(
      new Request(
        `https://app.syntila.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-gateway-test`,
        {
          headers: {
            upgrade: "websocket",
            authorization: `Bearer ${runtimeToken}`,
            "cf-ray": "gateway-ray-456",
          },
        },
      ),
    )) as unknown as TestResponse;

    expect(response.status).toBe(101);
    expect(acceptedSocket).toBeDefined();
    expect(acceptedSocket?.attachment).toMatchObject({
      correlationId: "gateway-ray-456",
      executionWorkspaceId: workspaceId,
      workspaceRuntimeId: "runtime-gateway-test",
    });
    gateway.webSocketMessage(
      acceptedSocket as unknown as WebSocket,
      JSON.stringify({
        protocol: "syntila.workspace-runtime-protocol",
        protocolVersion: "5.1",
        messageId: "gateway-hello-message",
        timestamp: new Date().toISOString(),
        type: "workspace.hello",
        executionWorkspaceId: workspaceId,
        workspaceRuntimeId: "runtime-gateway-test",
        payload: {},
      }),
    );
    await helloAck;
    // Message handling awaits durable outbound delivery before logging the ack.
    await Promise.resolve();
    await Promise.resolve();
    const records = logs.map(
      (record) =>
        JSON.parse(record) as {
          message: string;
          correlation?: { requestId?: string };
        },
    );
    expect(records.map((record) => record.message)).toEqual([
      "GW-05 durable_object_request_received",
      "GW-06 durable_object_runtime_authenticated",
      "GW-07 websocket_accepting",
      "GW-08 websocket_accepted",
      "GW-09 returning_http_101",
      "GW-10 workspace_hello_received",
      "GW-11 workspace_hello_ack_sent",
    ]);
    expect(
      records.every(
        (record) => record.correlation?.requestId === "gateway-ray-456",
      ),
    ).toBe(true);
    expect(logs.join("\n")).not.toContain(runtimeToken);
  });

  it("accepts only the runtime credential for one execution Workspace", async () => {
    const { db, sqlite } = runtimeDatabase("workspace-a", "runtime-a", "hash-a");
    // A revoked runtime is refused even with its own correct credential hash.
    sqlite.exec(
      `INSERT INTO workspace_runtime_identities (id, workspace_id, installation_id, credential_token_hash, revoked_at, created_at)
       VALUES ('runtime-revoked', 'workspace-a', 'installation-2', 'hash-revoked', now(), now())`,
    );
    await expect(
      isWorkspaceRuntimeAuthorized(db, "runtime-a", "hash-a"),
    ).resolves.toEqual({ executionWorkspaceId: "workspace-a" });
    await expect(
      isWorkspaceRuntimeAuthorized(db, "runtime-a", "wrong-token"),
    ).resolves.toBeNull();
    await expect(
      isWorkspaceRuntimeAuthorized(db, "runtime-revoked", "hash-revoked"),
    ).resolves.toBeNull();
  });

  describe("delivery probe", () => {
    async function connectedHttpGateway(workspaceId: string, token: string) {
      const credentialTokenHash = await hashToken(token);
      const { db } = runtimeDatabase(workspaceId, "runtime-probe", credentialTokenHash);
      const storage = new Map<string, unknown>();
      const state = {
        id: { name: workspaceId },
        storage: {
          get: async (key: string) => storage.get(key),
          put: async (key: string, value: unknown) => {
            storage.set(key, value);
          },
          delete: async (key: string) => storage.delete(key),
        },
      };
      const gateway = new WorkspaceGateway(state as never, {
        SYNTILA_DB: db as never,
      });
      const create = await gateway.fetch(
        new Request("https://gateway.internal/runtime/sessions", {
          method: "POST",
          headers: {
            authorization: `Bearer ${token}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            workspaceRuntimeId: "runtime-probe",
            contractVersion: "1.0",
          }),
        }),
      );
      expect(create.status).toBe(200);
      const session = (await create.json()) as {
        sessionId: string;
        cursor: string;
      };
      const poll = async () => {
        const response = await gateway.fetch(
          new Request("https://gateway.internal/runtime/poll", {
            method: "POST",
            headers: {
              authorization: `Bearer ${token}`,
              "content-type": "application/json",
            },
            body: JSON.stringify({
              sessionId: session.sessionId,
              cursor: session.cursor,
              waitMs: 0,
            }),
          }),
        );
        return (await response.json()) as {
          events: Array<{ message: Record<string, unknown> }>;
        };
      };
      return { gateway, session, poll };
    }

    const probeRequest = () =>
      new Request("https://gateway.internal/diagnostic-probe", {
        method: "POST",
      });

    it("rejects a probe when no Workspace runtime is connected", async () => {
      const gateway = new WorkspaceGateway(
        {
          id: { name: "workspace-offline" },
          storage: {
            get: async () => undefined,
            put: async () => undefined,
            delete: async () => false,
          },
        } as never,
        { SYNTILA_DB: {} as never },
      );
      const response = await gateway.fetch(probeRequest());
      expect(response.status).toBe(503);
    });

    it("wakes the Service with a content-free input notice", async () => {
      const { gateway, poll } = await connectedHttpGateway(
        "workspace-input-wake",
        "runtime-secret-input-wake",
      );
      const response = await gateway.fetch(
        new Request("https://gateway.internal/inputs-available", {
          method: "POST",
        }),
      );
      expect(await response.json()).toEqual({ delivered: true });
      const notices = (await poll()).events.filter(
        (event) => event.message.type === "input.available",
      );
      expect(notices).toHaveLength(1);
      expect(notices[0]!.message.payload).toEqual({});
    });

    it("queues a probe on the live transport and reports its acknowledgement", async () => {
      const token = "runtime-secret-probe-ack";
      const { gateway, session, poll } = await connectedHttpGateway(
        "workspace-probe-ack",
        token,
      );
      const outcome = gateway.fetch(probeRequest());
      let queued: Record<string, unknown> | undefined;
      for (let attempt = 0; attempt < 50 && !queued; attempt += 1) {
        const polled = await poll();
        queued = polled.events
          .map((event) => event.message)
          .find((message) => message.type === "diagnostic.probe");
        if (!queued) await new Promise((resolve) => setTimeout(resolve, 5));
      }
      expect(queued).toBeDefined();
      const payload = queued!.payload as { probeId: string; sentAt: string };
      expect(payload.probeId).toMatch(/^probe-/);

      const receivedAt = new Date().toISOString();
      const acknowledged = await gateway.fetch(
        new Request("https://gateway.internal/runtime/events", {
          method: "POST",
          headers: {
            authorization: `Bearer ${token}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            sessionId: session.sessionId,
            events: [
              {
                contract: "syntila.desktop-auth-transport",
                version: "1.0",
                eventId: "probe-ack-event",
                occurredAt: receivedAt,
                message: {
                  protocol: "syntila.workspace-runtime-protocol",
                  protocolVersion: "5.1",
                  messageId: "probe-ack-message",
                  correlationId: queued!.messageId,
                  timestamp: receivedAt,
                  type: "diagnostic.probe.ack",
                  executionWorkspaceId: "workspace-probe-ack",
                  workspaceRuntimeId: "runtime-probe",
                  payload: {
                    probeId: payload.probeId,
                    receivedAt,
                    ackedAt: receivedAt,
                    syncState: "ready",
                    localQueueLength: 2,
                    activeAssignments: 1,
                    clockOffsetMs: -12,
                    clockRttMs: 30,
                  },
                },
              },
            ],
          }),
        }),
      );
      expect(acknowledged.status).toBe(200);

      const response = await outcome;
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({
        probeId: payload.probeId,
        transport: "http_long_poll",
        outcome: "acknowledged",
        syncState: "ready",
        localQueueLength: 2,
        activeAssignments: 1,
        clockOffsetMs: -12,
        clockRttMs: 30,
      });
    });

    it("reports a timeout when an older Service never acknowledges", async () => {
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      try {
        const { gateway } = await connectedHttpGateway(
          "workspace-probe-timeout",
          "runtime-secret-probe-timeout",
        );
        const outcome = gateway.fetch(probeRequest());
        await vi.advanceTimersByTimeAsync(5_001);
        const response = await outcome;
        expect(response.status).toBe(504);
        expect(await response.json()).toMatchObject({
          transport: "http_long_poll",
          outcome: "timeout",
          timeoutMs: 5000,
        });
      } finally {
        vi.useRealTimers();
      }
    });
  });

  it("fences stale socket close events after reconnect", () => {
    const current = {} as WebSocket;
    const stale = {} as WebSocket;
    expect(isCurrentWorkspaceSocket(current, "new", current, "new")).toBe(true);
    expect(isCurrentWorkspaceSocket(current, "new", stale, "old")).toBe(false);
  });

  it("rejects assignment correlation for another Workspace runtime", () => {
    const row = {
      id: "assignment-1",
      execution_workspace_id: "workspace-a",
      runtime_identity_id: "runtime-a",
      worker_type_id: "chatgpt",
      workspace_worker_id: "worker-1",
      run_id: "run-1",
      task_id: "task-1",
      attempt_id: "attempt-1",
      idempotency_key: "idem-1",
    };
    const message = {
      executionWorkspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      workerId: "worker-1",
      runId: "run-1",
      taskId: "task-1",
      attemptId: "attempt-1",
      assignmentId: "assignment-1",
      idempotencyKey: "idem-1",
    };
    expect(workspaceAssignmentContextMatches(message, row)).toBe(true);
    expect(
      workspaceAssignmentContextMatches(
        { ...message, workspaceRuntimeId: "runtime-b" },
        row,
      ),
    ).toBe(false);
    expect(
      workspaceAssignmentContextMatches(
        { ...message, executionWorkspaceId: "workspace-b" },
        row,
      ),
    ).toBe(false);
  });

  it("normalizes runtime Worker health without allowing it to change desired state", () => {
    expect(normalizeWorkspaceWorkerInstallationStatus("ready")).toBe("ready");
    expect(normalizeWorkspaceWorkerInstallationStatus("downloading")).toBe(
      "installing",
    );
    expect(normalizeWorkspaceWorkerInstallationStatus("updating")).toBe(
      "updating",
    );
    expect(normalizeWorkspaceWorkerInstallationStatus("unknown")).toBe(
      "failed",
    );
  });
});
