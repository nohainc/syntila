import { expect } from "vitest";
import { hashToken } from "../../../../packages/security/src/index.js";
import { WorkspaceGateway } from "../../src/workspace-gateway.js";
import { conversationFixture } from "./conversation.js";

const token = "runtime-secret-assignment-lifecycle";

/**
 * Drives the real Gateway over the HTTP fallback transport against the real
 * SQL schema, so the ack handlers, the transition helper, the generated
 * source sets and the conversation-turn triggers are exercised together.
 */
export async function gatewayFixture(
  initialStatus: string,
  options: {
    readonly ready?: boolean;
    readonly capabilities?: string[];
    readonly research?: boolean;
    /** Extra bindings for the Gateway's environment (e.g. a Workflow). */
    readonly env?: Record<string, unknown>;
  } = {},
) {
  const f = await conversationFixture({ research: options.research });
  f.sqlite.exec(
    "INSERT INTO runs(id,space_id,status,created_at,updated_at) VALUES('RUN','P','running','now','now')",
  );
  f.assign("A1");
  // Dispatch only delivers to assignments backed by an active Space grant.
  f.sqlite.exec(
    "INSERT INTO workspace_space_grants(id,space_id,workspace_id,granted_by_user_id,created_at,updated_at) VALUES('G','P','WS','U','now','now')",
  );
  f.sqlite.exec(
    "UPDATE worker_assignments SET workspace_space_grant_id='G' WHERE id='A1'",
  );
  f.sqlite
    .prepare(
      `UPDATE worker_assignments
          SET run_id='RUN', attempt_id='ATT1', idempotency_key='IDEM1', status=?
        WHERE id='A1'`,
    )
    .run(initialStatus);
  f.sqlite
    .prepare(
      "UPDATE workspace_runtime_identities SET credential_token_hash=? WHERE id='RT'",
    )
    .run(await hashToken(token));
  const storage = new Map<string, unknown>();
  const makeGateway = () =>
    new WorkspaceGateway(
      {
        id: { name: "WS" },
        storage: {
          get: async (key: string) => storage.get(key),
          put: async (key: string, value: unknown) => {
            storage.set(key, value);
          },
          delete: async (key: string) => storage.delete(key),
        },
      } as never,
      { SYNTILA_DB: f.db as never, ...options.env } as never,
    );
  const gateway = makeGateway();
  const headers = {
    authorization: `Bearer ${token}`,
    "content-type": "application/json",
  };
  const create = await gateway.fetch(
    new Request("https://gateway.internal/runtime/sessions", {
      method: "POST",
      headers,
      body: JSON.stringify({
        workspaceRuntimeId: "RT",
        contractVersion: "1.0",
      }),
    }),
  );
  expect(create.status).toBe(200);
  const { sessionId } = (await create.json()) as { sessionId: string };

  let counter = 0;
  const send = async (
    type: string,
    payload: Record<string, unknown>,
    overrides: Record<string, unknown> = {},
    target: WorkspaceGateway = gateway,
  ) => {
    counter += 1;
    const at = new Date().toISOString();
    const response = await target.fetch(
      new Request("https://gateway.internal/runtime/events", {
        method: "POST",
        headers,
        body: JSON.stringify({
          sessionId,
          events: [
            {
              contract: "syntila.desktop-auth-transport",
              version: "1.0",
              eventId: `event-${counter}`,
              occurredAt: at,
              message: {
                protocol: "syntila.workspace-runtime-protocol",
                protocolVersion: "5.1",
                messageId: `message-${counter}`,
                timestamp: at,
                type,
                executionWorkspaceId: "WS",
                workspaceRuntimeId: "RT",
                workerId: "worker-a",
                runId: "RUN",
                taskId: "T",
                attemptId: "ATT1",
                assignmentId: "A1",
                idempotencyKey: "IDEM1",
                payload,
                ...overrides,
              },
            },
          ],
        }),
      }),
    );
    expect(response.status).toBe(200);
  };
  const status = () =>
    f.sqlite
      .prepare(
        "SELECT status, updated_at FROM worker_assignments WHERE id='A1'",
      )
      .get() as { status: string; updated_at: string };
  let pollCursor = 0;
  /** Messages the Gateway has queued for the Service since the last call. */
  const outbound = async (target: WorkspaceGateway = gateway) => {
    const response = await target.fetch(
      new Request("https://gateway.internal/runtime/poll", {
        method: "POST",
        headers,
        body: JSON.stringify({
          sessionId,
          cursor: String(pollCursor),
          waitMs: 0,
        }),
      }),
    );
    const body = (await response.json()) as {
      cursor: string;
      events: Array<{
        message: { type: string; payload: Record<string, unknown> } & Record<
          string,
          unknown
        >;
      }>;
    };
    pollCursor = Number(body.cursor);
    return body.events.map((event) => event.message);
  };
  const dispatchBody = {
    executionWorkspaceId: "WS",
    workspaceRuntimeId: "RT",
    workerId: "worker-a",
    runId: "RUN",
    taskId: "T",
    attemptId: "ATT1",
    assignmentId: "A1",
    idempotencyKey: "IDEM1",
    payload: {
      snapshot: { workerTypeId: "chatgpt" },
      input: { objective: "revocation test" },
    },
  };
  const dispatch = async () =>
    gateway.fetch(
      new Request("https://gateway.internal/dispatch-assignment", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(dispatchBody),
      }),
    );
  const cancelBody = {
    ...dispatchBody,
    payload: { assignmentId: "A1", reason: "test revocation" },
  };
  /** Completes the Service's synchronization and publishes it as ready. */
  const becomeReady = async (syncGeneration = 1) => {
    await send("workspace.sync.request", {});
    await send("workspace.readiness", {
      state: "ready",
      readyForAssignments: true,
      syncGeneration,
    });
  };
  const gatewayStatus = async () =>
    (await (
      await gateway.fetch(new Request("https://gateway.internal/status"))
    ).json()) as {
      online: boolean;
      readyForAssignments: boolean;
      serviceState: string;
      syncGeneration: number;
    };
  await send("workspace.hello", {
    capabilities: {
      customCapabilities: options.capabilities ?? [
        "assignment.start_permit.v1",
      ],
    },
  });
  await outbound();
  if (options.ready !== false) {
    await becomeReady();
    // Discard the sync result so tests see only the messages they trigger.
    await outbound();
  }
  return {
    ...f,
    send,
    status,
    outbound,
    /** Cursor after everything already read via outbound(). */
    cursor: () => String(pollCursor),
    dispatch,
    dispatchBody,
    gateway,
    cancelBody,
    becomeReady,
    gatewayStatus,
    headers,
    sessionId,
    /** A new instance over the same storage, as after hibernation. */
    restart: makeGateway,
  };
}
