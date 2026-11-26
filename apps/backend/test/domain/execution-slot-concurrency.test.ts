/**
 * Concurrency (claude/concurrency-plan.md): a Free requester has one
 * execution slot. Parallel dispatches without the global writer lock must
 * admit exactly one assignment; the others wait.
 */
import { expect, it } from "./helpers/vitest-compat";
import { dispatchTaskAssignment } from "../../src/domain/assignment-dispatcher.js";
import { PgDb } from "../../src/platform/data";
import { conversationFixture } from "./helpers/conversation.js";

it("admits one assignment for parallel dispatches of a Free requester", async () => {
  const f = await conversationFixture();
  await f.sqlite.exec(`
    INSERT INTO runs(id,space_id,status,created_at,updated_at) VALUES('RUN','P','running','now','now');
    INSERT INTO worker_credentials(id,worker_instance_id,public_key,key_fingerprint) VALUES('cred-a','worker-a','${"a".repeat(43)}','${"a".repeat(64)}');
    INSERT INTO worker_agent_sessions(worker_instance_id,session_id,session_epoch,credential_id,token_digest,lease_expires_at) VALUES('worker-a','sess-a',1,'cred-a','digest',now() + interval '5 minutes');
    INSERT INTO worker_profiles(worker_type_id,schema_version,profile_json,revision,digest,updated_at) VALUES('chatgpt',1,'{"schemaVersion":1,"profileDefinitionId":"chatgpt-codex"}',3,'${"a".repeat(64)}',now()) ON CONFLICT (worker_type_id) DO NOTHING;
    INSERT INTO workflow_tasks(id,work_request_id,step_instance_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at)
    SELECT 'T' || n, 'R', 'step-' || n, 'chat', 'stateless_read', 1000, 'chat:v1', 'running', 'now', 'now' FROM generate_series(2, 6) n;`);
  const db = new PgDb((f.db as unknown as { sql: any }).sql);
  const env = {
    SYNTILA_DB: db,
    SYNTILA_WORKER_GATEWAY: { idFromName: () => "worker-a", get: () => ({ fetch: async () => Response.json({}) }), getByName: () => ({ fetch: async () => Response.json({}) }) },
  } as any;
  const workerTarget = {
    workerId: "worker-a", workerTypeId: "chatgpt", workerName: "ChatGPT", spaceId: "P", threadId: "W",
    model: null, reasoningEffort: null, readOnly: true, permissions: ["repository:read"],
    profile: { definitionId: "chatgpt-codex", revision: 3, digest: "a".repeat(64) }, mcpWorker: null,
  };
  const tasks = ["T", "T2", "T3", "T4", "T5", "T6"];
  await Promise.allSettled(tasks.map((taskId) =>
    dispatchTaskAssignment(env, {
      runId: "RUN", taskId,
      task: { id: taskId, spaceId: "P", threadId: "W", requestedByUserId: "U", role: "collaborator", objective: "x", workRequestId: "R", workBindingId: "chat", sessionPolicy: "stateless", workerTarget },
    } as any)));
  const live = await f.sqlite.prepare(
    "SELECT count(*)::int AS n FROM worker_assignments WHERE requested_by_user_id = 'U' AND status NOT IN ('completed','failed','cancelled','timed_out')",
  ).get() as { n: number };
  expect(live.n).toBe(1);
});
