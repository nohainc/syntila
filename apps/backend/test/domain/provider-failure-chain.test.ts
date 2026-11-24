import { describe, expect, it } from "./helpers/vitest-compat";
import { conversationFixture } from "./helpers/conversation.js";
import { WorkerGateway } from "../../src/domain/worker-gateway.js";
import { handleGetWorkRequest } from "../../src/domain/routes/work-lifecycle.js";
import { executionErrorMessage } from "@syntila/protocol";

const input = process.env.SYNTILA_TEST_FAILURE_PAYLOAD;
const output = process.env.SYNTILA_TEST_FAILURE_WORK;
const key = "12".repeat(32);

async function workerGatewayFixture(
  initialStatus: string,
  options: { failureDetailsSnapshot?: boolean; env?: Record<string, unknown> } = {},
) {
  const f = await conversationFixture({ failureDetailsSnapshot: options.failureDetailsSnapshot });
  await f.sqlite.exec(
    `INSERT INTO runs(id,space_id,status,created_at,updated_at) VALUES('RUN','P','running','now','now');
     INSERT INTO worker_credentials(id,worker_instance_id,public_key,key_fingerprint) VALUES('cred-a','worker-a','${"a".repeat(43)}','${"a".repeat(64)}');
     INSERT INTO worker_agent_sessions(worker_instance_id,session_id,session_epoch,credential_id,token_digest,lease_expires_at) VALUES('worker-a','sess-a',1,'cred-a','digest',now() + interval '5 minutes');`,
  );
  await f.assign("A1");
  await f.sqlite
    .prepare(
      `UPDATE worker_assignments SET run_id='RUN', attempt_id='ATT1', idempotency_key='IDEM1', status=? WHERE id='A1'`,
    )
    .run(initialStatus);
  const gateway = new WorkerGateway(
    {} as never,
    { SYNTILA_DB: f.db as never, ...options.env } as never,
  ) as any;
  gateway.socket = { send() {} };
  gateway.knownWorkerId = "worker-a";
  gateway.attachment = {
    workerId: "worker-a",
    fence: { workerInstanceId: "worker-a", sessionId: "sess-a", epoch: 1 },
  };
  let counter = 0;
  const send = async (type: string, payload: Record<string, unknown>) => {
    counter += 1;
    await gateway.handle(
      JSON.stringify({
        protocol: "syntila.workspace-runtime-protocol",
        protocolVersion: "5.1",
        messageId: `message-${counter}`,
        timestamp: new Date().toISOString(),
        type,
        executionWorkspaceId: "worker-a",
        workspaceRuntimeId: "sess-a",
        workerId: "worker-a",
        runId: "RUN",
        taskId: "T",
        attemptId: "ATT1",
        assignmentId: "A1",
        idempotencyKey: "IDEM1",
        payload,
      }),
    );
  };
  const status = async () =>
    (await f.sqlite
      .prepare("SELECT status, updated_at FROM worker_assignments WHERE id='A1'")
      .get()) as { status: string; updated_at: string };
  return { ...f, send, status };
}

it("persists an unavailable-details marker received through the Gateway", async () => {
  const f = await workerGatewayFixture("running", {
    failureDetailsSnapshot: true,
    env: { SYNTILA_PROVIDER_FAILURE_KEY: key },
  });
  await f.send("assignment.error", {
    status: "failed",
    error: {
      code: "execution_failed",
      message: executionErrorMessage("execution_failed"),
      retryable: false,
    },
    providerFailureUnavailable: true,
  });
  expect((await f.status()).status).toBe("failed");
  const row = (await f.sqlite
    .prepare(
      "SELECT error_json::text AS error_json FROM worker_assignments WHERE id='A1'",
    )
    .get()) as { error_json: string };
  expect(JSON.parse(row.error_json).providerFailureUnavailable).toBe(true);
});

describe.skipIf(!input || !output)(
  "provider failure cross-component fixture",
  () => {
    it("persists the actual Workspace terminal event and returns it only to an authorized reader", async () => {
      const message = (await Bun.file(input!).json()) as {
        type: string;
        payload: Record<string, unknown>;
      };
      expect(message.type).toBe("assignment.error");
      const f = await workerGatewayFixture("running", {
        failureDetailsSnapshot: true,
        env: { SYNTILA_PROVIDER_FAILURE_KEY: key },
      });
      await f.sqlite.exec(
        "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('M','P','U','owner','now','now')",
      );
      await f.sqlite.exec(
        "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('V','v@test','Viewer','now','now')",
      );
      await f.sqlite.exec(
        "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('MV','P','V','viewer','now','now')",
      );
      await f.send(message.type, message.payload);
      expect((await f.status()).status).toBe("failed");
      const row = (await f.sqlite
        .prepare(
          "SELECT error_json::text AS error_json FROM worker_assignments WHERE id='A1'",
        )
        .get()) as { error_json: string };
      expect(row.error_json).not.toContain("Output limit reached");
      expect(row.error_json).not.toContain("Partial answer");
      expect(row.error_json).not.toContain("permission denied by sandbox");
      expect(row.error_json).not.toContain("secret_token_1234567890");
      expect(row.error_json).not.toContain("fixture stderr-only failure");
      expect(row.error_json).not.toContain("fixture_private_diagnostic_marker");
      expect(row.error_json).not.toContain("fixture_stderr_private_marker");
      await f.send(message.type, message.payload);
      const duplicate = (await f.sqlite
        .prepare(
          "SELECT error_json::text AS error_json FROM worker_assignments WHERE id='A1'",
        )
        .get()) as { error_json: string };
      expect(duplicate.error_json).toBe(row.error_json);
      const env = (userId: string) =>
        ({
          SYNTILA_ENVIRONMENT: "development",
          SYNTILA_DB: f.db,
          SYNTILA_PROVIDER_FAILURE_KEY: key,
          TEST_AUTHENTICATION: async () => ({
            userId,
            user: {
              id: userId,
              email: "u@test",
              displayName: "User",
              status: "active",
            },
            workspaceId: "",
            spaceRoles: {},
            sessionId: "test",
            clientType: "web",
          }),
        }) as never;
      const request = new Request("https://test/api/work-requests/R");
      await expect(
        handleGetWorkRequest(request, env("other"), "R"),
      ).rejects.toThrow();
      const response = await handleGetWorkRequest(request, env("U"), "R");
      expect(response.status).toBe(200);
      const work = (await response.json()) as any;
      expect(work.steps[0].providerFailure).toEqual(
        message.payload.providerFailure,
      );
      expect(work.steps[0].status).toBe("failed");
      const shared = (await (
        await handleGetWorkRequest(request, env("V"), "R")
      ).json()) as any;
      expect(shared.steps[0].providerFailure).toEqual(
        message.payload.providerFailure,
      );
      const reloaded = (await (
        await handleGetWorkRequest(request, env("U"), "R")
      ).json()) as any;
      expect(reloaded.steps[0].providerFailure).toEqual(
        message.payload.providerFailure,
      );
      expect(reloaded.steps[0].status).toBe("failed");
      await Bun.write(output!, JSON.stringify(reloaded));
      await f.assign("A2");
      const retry = (await (
        await handleGetWorkRequest(request, env("U"), "R")
      ).json()) as any;
      expect(retry.steps[0].assignmentId).toBe("A2");
      expect(retry.steps[0].providerFailure).toBeNull();
    });
  },
);
