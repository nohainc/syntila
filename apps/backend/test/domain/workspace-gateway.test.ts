import { pgD1, recordStatements } from "./helpers/pg-d1";
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
import worker from "../../src/domain/index.js";
import { identityService } from "../../src/domain/auth/identity-service.js";
import { handleWorkspaceDeliveryProbe } from "../../src/domain/routes/workspaces-management.js";
import type { SecurityEnv } from "../../src/domain/routes/http-security.js";

/** A real database holding one Workspace and the runtime identity that holds `credentialTokenHash`. */
async function runtimeDatabase(
  workspaceId: string,
  runtimeId: string,
  credentialTokenHash: string,
) {
  const { db, sqlite } = await pgD1();
  await sqlite.exec(user("owner") + workspace(workspaceId, "owner"));
  await sqlite
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
    const { db } = await runtimeDatabase(workspaceId, "runtime-replay", credentialTokenHash);
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
    const { db } = await runtimeDatabase(workspaceId, "runtime-gateway-test", credentialTokenHash);
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
    const { db, sqlite } = await runtimeDatabase("workspace-a", "runtime-a", "hash-a");
    // A revoked runtime is refused even with its own correct credential hash.
    (await sqlite.exec(
      `INSERT INTO workspace_runtime_identities (id, workspace_id, installation_id, credential_token_hash, revoked_at, created_at)
       VALUES ('runtime-revoked', 'workspace-a', 'installation-2', 'hash-revoked', now(), now())`,
    ));
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
      const { db } = await runtimeDatabase(workspaceId, "runtime-probe", credentialTokenHash);
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

    describe("POST /api/workspaces/:workspaceId/delivery-probe", () => {
      async function setupProbeRouteTest(workspaceId: string) {
        const runtimeToken = `runtime-secret-${workspaceId}`;
        const credentialTokenHash = await hashToken(runtimeToken);
        const { db: rawDb, sqlite } = await runtimeDatabase(
          workspaceId,
          "runtime-probe",
          credentialTokenHash,
        );
        await sqlite.exec(user("stranger"));
        const { db, statements } = recordStatements(rawDb);
        const gateways = new Map<string, WorkspaceGateway>();
        const getGateway = (id: string) => {
          let gw = gateways.get(id);
          if (!gw) {
            const storage = new Map<string, unknown>();
            gw = new WorkspaceGateway(
              {
                id: { name: id },
                storage: {
                  get: async (key: string) => storage.get(key),
                  put: async (key: string, value: unknown) => {
                    storage.set(key, value);
                  },
                  delete: async (key: string) => storage.delete(key),
                },
              } as never,
              { SYNTILA_DB: db as never },
            );
            gateways.set(id, gw);
          }
          return gw;
        };

        vi.spyOn(identityService, "resolve").mockImplementation(async (req) => {
          const auth = req.headers.get("authorization");
          const userId = auth?.startsWith("Bearer ") ? auth.slice(7) : auth;
          return userId
            ? {
                userId,
                email: `${userId}@example.com`,
                name: userId,
                sessionId: `session-${userId}`,
              }
            : null;
        });

        const env: SecurityEnv = {
          SYNTILA_DB: db as never,
          SYNTILA_ENVIRONMENT: "production",
          SYNTILA_WORKSPACE_GATEWAY: {
            getByName: (name: string) => ({
              fetch: (input: RequestInfo | URL, init?: RequestInit) =>
                getGateway(name).fetch(new Request(input, init)),
            }),
          } as unknown as DurableObjectNamespace,
        };

        const connectRuntime = async () => {
          const gateway = getGateway(workspaceId);
          const create = await gateway.fetch(
            new Request("https://gateway.internal/runtime/sessions", {
              method: "POST",
              headers: {
                authorization: `Bearer ${runtimeToken}`,
                "content-type": "application/json",
              },
              body: JSON.stringify({
                workspaceRuntimeId: "runtime-probe",
                contractVersion: "1.0",
              }),
            }),
          );
          expect(create.status).toBe(200);
          let { sessionId, cursor } = (await create.json()) as {
            sessionId: string;
            cursor: string;
          };
          const pollAndAckOnce = async () => {
            for (let attempt = 0; attempt < 100; attempt += 1) {
              const polledRes = await gateway.fetch(
                new Request("https://gateway.internal/runtime/poll", {
                  method: "POST",
                  headers: {
                    authorization: `Bearer ${runtimeToken}`,
                    "content-type": "application/json",
                  },
                  body: JSON.stringify({ sessionId, cursor, waitMs: 0 }),
                }),
              );
              const polled = (await polledRes.json()) as {
                cursor: string;
                events: Array<{ message: Record<string, unknown> }>;
              };
              cursor = polled.cursor;
              const probe = polled.events
                .map((e) => e.message)
                .find((m) => m.type === "diagnostic.probe");
              if (probe) {
                const payload = probe.payload as { probeId: string };
                const now = new Date().toISOString();
                const ackRes = await gateway.fetch(
                  new Request("https://gateway.internal/runtime/events", {
                    method: "POST",
                    headers: {
                      authorization: `Bearer ${runtimeToken}`,
                      "content-type": "application/json",
                    },
                    body: JSON.stringify({
                      sessionId,
                      events: [
                        {
                          contract: "syntila.desktop-auth-transport",
                          version: "1.0",
                          eventId: `ack-${payload.probeId}`,
                          occurredAt: now,
                          message: {
                            protocol: "syntila.workspace-runtime-protocol",
                            protocolVersion: "5.1",
                            messageId: `msg-ack-${payload.probeId}`,
                            correlationId: probe.messageId,
                            timestamp: now,
                            type: "diagnostic.probe.ack",
                            executionWorkspaceId: workspaceId,
                            workspaceRuntimeId: "runtime-probe",
                            payload: {
                              probeId: payload.probeId,
                              receivedAt: now,
                              ackedAt: now,
                              syncState: "ready",
                              localQueueLength: 0,
                              activeAssignments: 0,
                              clockOffsetMs: -5,
                              clockRttMs: 14,
                            },
                          },
                        },
                      ],
                    }),
                  }),
                );
                expect(ackRes.status).toBe(200);
                return payload.probeId;
              }
              await new Promise((resolve) => setTimeout(resolve, 5));
            }
            throw new Error("Timed out waiting for diagnostic.probe");
          };
          return { gateway, sessionId, pollAndAckOnce };
        };

        return { env, sqlite, statements, connectRuntime };
      }

      it("allows the Workspace owner to run a probe, logs trace stages without leaking Authorization, and writes nothing to the database", async () => {
        const workspaceId = "ws-route-owner-ok";
        const { env, statements, connectRuntime } =
          await setupProbeRouteTest(workspaceId);
        const { pollAndAckOnce } = await connectRuntime();
        statements.length = 0;

        const logs: string[] = [];
        vi.spyOn(console, "log").mockImplementation((record) => {
          logs.push(String(record));
        });

        const secretHeader = "Bearer owner";
        const responsePromise = worker.fetch(
          new Request(
            `https://app.syntila.test/api/workspaces/${workspaceId}/delivery-probe`,
            {
              method: "POST",
              headers: { authorization: secretHeader },
            },
          ),
          env,
        );
        const ackedProbeId = await pollAndAckOnce();
        const response = await responsePromise;
        expect(response.status).toBe(200);
        const body = (await response.json()) as Record<string, unknown>;
        expect(body).toMatchObject({
          probeId: ackedProbeId,
          transport: "http_long_poll",
          outcome: "acknowledged",
          syncState: "ready",
          localQueueLength: 0,
          activeAssignments: 0,
          clockOffsetMs: -5,
          clockRttMs: 14,
        });
        expect(typeof body.roundTripMs).toBe("number");
        expect(typeof body.serviceReceivedAt).toBe("string");

        const parsedLogs = logs.map((line) => JSON.parse(line) as Record<string, any>);
        const httpLog = parsedLogs.find((l) => l.message === "http.request");
        expect(httpLog).toBeDefined();
        expect(JSON.stringify(httpLog)).not.toContain(secretHeader);
        expect(JSON.stringify(httpLog)).not.toContain("authorization");

        const traceStages = parsedLogs
          .filter((l) => l.message === "diagnostic.event")
          .map((l) => l.details?.event?.context?.traceStage);
        expect(traceStages).toContain("probe_sent");
        expect(traceStages).toContain("probe_acknowledged");

        // Handle probe route does not write to the database (only user provision/read on auth).
        const probeWrites = statements.filter(
          (s) =>
            /\b(INSERT|UPDATE|DELETE)\b/i.test(s) &&
            !/\bINSERT INTO users\b/i.test(s),
        );
        expect(probeWrites).toEqual([]);
      });

      it("rejects unauthenticated callers with 401 and non-owners with 404", async () => {
        const workspaceId = "ws-route-auth";
        const { env } = await setupProbeRouteTest(workspaceId);

        const unauth = await worker.fetch(
          new Request(
            `https://app.syntila.test/api/workspaces/${workspaceId}/delivery-probe`,
            { method: "POST" },
          ),
          env,
        );
        expect(unauth.status).toBe(401);

        const nonOwner = await worker.fetch(
          new Request(
            `https://app.syntila.test/api/workspaces/${workspaceId}/delivery-probe`,
            {
              method: "POST",
              headers: { authorization: "Bearer stranger" },
            },
          ),
          env,
        );
        expect(nonOwner.status).toBe(404);
      });

      it("returns 503 when the Workspace is offline", async () => {
        const workspaceId = "ws-route-offline";
        const { env } = await setupProbeRouteTest(workspaceId);

        const response = await worker.fetch(
          new Request(
            `https://app.syntila.test/api/workspaces/${workspaceId}/delivery-probe`,
            {
              method: "POST",
              headers: { authorization: "Bearer owner" },
            },
          ),
          env,
        );
        expect(response.status).toBe(503);
        expect(await response.json()).toMatchObject({
          error: "Workspace is offline",
        });
      });

      it("runs count=3 probes sequentially and returns 3 results with a summary", async () => {
        const workspaceId = "ws-route-batch";
        const { env, connectRuntime } = await setupProbeRouteTest(workspaceId);
        const { pollAndAckOnce } = await connectRuntime();

        const responsePromise = worker.fetch(
          new Request(
            `https://app.syntila.test/api/workspaces/${workspaceId}/delivery-probe?count=3&intervalMs=5`,
            {
              method: "POST",
              headers: { authorization: "Bearer owner" },
            },
          ),
          env,
        );

        await pollAndAckOnce();
        await pollAndAckOnce();
        await pollAndAckOnce();

        const response = await responsePromise;
        expect(response.status).toBe(200);
        const body = (await response.json()) as {
          results: Array<{ probeId: string; outcome: string; roundTripMs: number }>;
          summary: {
            n: number;
            ok: number;
            timeouts: number;
            minMs: number;
            p50Ms: number;
            p95Ms: number;
            maxMs: number;
          };
        };
        expect(body.results).toHaveLength(3);
        expect(body.results.every((r) => r.outcome === "acknowledged")).toBe(true);
        const rtts = body.results.map((r) => r.roundTripMs).sort((a, b) => a - b);
        expect(body.summary).toEqual({
          n: 3,
          ok: 3,
          timeouts: 0,
          minMs: rtts[0]!,
          p50Ms: rtts[1]!,
          p95Ms: rtts[2]!,
          maxMs: rtts[2]!,
        });
      });

      it("rejects invalid count and intervalMs parameters with 400", async () => {
        const workspaceId = "ws-route-invalid-params";
        const { env } = await setupProbeRouteTest(workspaceId);

        for (const query of [
          "count=0",
          "count=21",
          "count=-1",
          "count=abc",
          "count=1.5",
          "intervalMs=-1",
          "intervalMs=1001",
          "intervalMs=abc",
        ]) {
          const response = await worker.fetch(
            new Request(
              `https://app.syntila.test/api/workspaces/${workspaceId}/delivery-probe?${query}`,
              {
                method: "POST",
                headers: { authorization: "Bearer owner" },
              },
            ),
            env,
          );
          expect(response.status, query).toBe(400);
        }
      });

      it("rejects a second concurrent probe batch for the same Workspace with 429", async () => {
        const workspaceId = "ws-route-concurrent";
        const { env, connectRuntime } = await setupProbeRouteTest(workspaceId);
        const { pollAndAckOnce } = await connectRuntime();

        const firstPromise = worker.fetch(
          new Request(
            `https://app.syntila.test/api/workspaces/${workspaceId}/delivery-probe?count=2`,
            {
              method: "POST",
              headers: { authorization: "Bearer owner" },
            },
          ),
          env,
        );

        // First probe of the first batch is in flight; start a second request concurrently.
        await pollAndAckOnce();
        const secondResponse = await worker.fetch(
          new Request(
            `https://app.syntila.test/api/workspaces/${workspaceId}/delivery-probe`,
            {
              method: "POST",
              headers: { authorization: "Bearer owner" },
            },
          ),
          env,
        );
        expect(secondResponse.status).toBe(429);

        // Complete the second probe of the first batch.
        await pollAndAckOnce();
        const firstResponse = await firstPromise;
        expect(firstResponse.status).toBe(200);
      });

      it("returns outcome 'timeout' when probing a Service that never acknowledges", async () => {
        const workspaceId = "ws-route-timeout";
        const { env, connectRuntime } = await setupProbeRouteTest(workspaceId);
        await connectRuntime();

        const response = await handleWorkspaceDeliveryProbe(
          new Request(
            `https://app.syntila.test/api/workspaces/${workspaceId}/delivery-probe`,
            {
              method: "POST",
              headers: { authorization: "Bearer owner" },
            },
          ),
          env,
          workspaceId,
          undefined,
          { timeoutMs: 25 },
        );
        expect(response.status).toBe(504);
        expect(await response.json()).toMatchObject({
          transport: "http_long_poll",
          outcome: "timeout",
          timeoutMs: 25,
        });
      });
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
