import { conversationFixture } from "./helpers/conversation";
import { expect, it } from "./helpers/vitest-compat";
import { dispatchTaskAssignment } from "../../src/domain/assignment-dispatcher.js";
import {
  parseWorkspaceRuntimeMessage,
  WORKSPACE_RUNTIME_PROTOCOL_NAME,
  WORKSPACE_RUNTIME_PROTOCOL_VERSION,
} from "@syntila/worker-agent-protocol";

it.each([null, "low"])(
  "dispatch uses the frozen effort %s even if the task has a later override",
  async (effort) => {
    const f = await conversationFixture();
    await f.sqlite.exec(`
      INSERT INTO runs(id,space_id,status,created_at,updated_at) VALUES('RUN','P','running','now','now');
      INSERT INTO worker_credentials(id,worker_instance_id,public_key,key_fingerprint) VALUES('cred-a','worker-a','${"a".repeat(43)}','${"a".repeat(64)}');
      INSERT INTO worker_agent_sessions(worker_instance_id,session_id,session_epoch,credential_id,token_digest,lease_expires_at) VALUES('worker-a','sess-a',1,'cred-a','digest',now() + interval '5 minutes');
      INSERT INTO worker_profiles(worker_type_id,schema_version,profile_json,revision,digest,updated_at) VALUES('chatgpt',1,'{"schemaVersion":1,"profileDefinitionId":"profile"}',2,'${"a".repeat(64)}',now()) ON CONFLICT (worker_type_id) DO NOTHING;`);
    let sent: Record<string, unknown> | undefined;
    const namespace = {
      idFromName() {
        return "worker-a";
      },
      get() {
        return {
          async fetch(_url: string, init: RequestInit) {
            sent = JSON.parse(init.body as string);
            return new Response("{}");
          },
        };
      },
      getByName() {
        return this.get();
      },
    };
    const workerTarget = {
      workerId: "worker-a",
      workerTypeId: "chatgpt",
      workerName: "ChatGPT",
      spaceId: "P",
      threadId: "W",
      model: "family",
      reasoningEffort: effort,
      readOnly: true,
      permissions: ["repository:read"],
      profile: { definitionId: "profile", revision: 2, digest: "a".repeat(64) },
      mcpWorker: null,
    };
    const result = await dispatchTaskAssignment(
      {
        SYNTILA_DB: f.db,
        SYNTILA_WORKER_GATEWAY:
          namespace as unknown as DurableObjectNamespace,
      },
      {
        workspaceId: null,
        runId: "RUN",
        taskId: "T",
        task: {
          id: "T",
          role: "collaborator",
          objective: "Prompt",
          spaceId: "P",
          threadId: "W",
          requestedByUserId: "U",
          workBindingId: "chat",
          model: "changed-later",
          reasoningEffort: "high",
          workerTarget,
        },
      } as any,
    );
    expect(result.accepted).toBe(true);
    expect(
      (sent as { payload: { snapshot: Record<string, unknown> } }).payload.snapshot,
    ).toMatchObject({
      model: "family",
      reasoningEffort: effort,
    });
    const command = await f.sqlite
      .prepare(
        `SELECT c.type, c.status, c.worker_instance_id AS instance, c.payload_ref AS ref, c.assignment_id AS assignment
           FROM agent_commands c JOIN worker_assignments a ON a.id = c.assignment_id
          WHERE a.task_id = 'T' AND a.run_id = 'RUN'`,
      )
      .get() as { type: string; status: string; instance: string; ref: string; assignment: string };
    expect(command).toMatchObject({ type: "assignment.dispatch", status: "sent", instance: "worker-a" });
    expect(command.ref).toBe(`worker_assignments:${command.assignment}`);
  },
);
