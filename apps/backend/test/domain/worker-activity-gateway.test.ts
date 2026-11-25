import { expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { basicThread } from "./helpers/seed";
import { WorkerGateway } from "../../src/domain/worker-gateway.js";
import { publishAssignmentPhase } from "../../src/domain/assignment-phase-events.js";

it("forwards current Worker activity on the Space stream and fences old sessions", async () => {
  const f = await pgD1();
  await f.sqlite.exec(`${basicThread({ user: "alice", space: "sp", thread: "th" })}
    INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES ('w','','alice','chatgpt','Worker');
    INSERT INTO worker_credentials(id,worker_instance_id,public_key,key_fingerprint) VALUES ('c','w','${"a".repeat(43)}','${"a".repeat(64)}');
    INSERT INTO worker_agent_sessions(worker_instance_id,session_id,session_epoch,credential_id,token_digest,lease_expires_at) VALUES ('w','s',1,'c','digest',now()+interval '5 minutes');
    INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at) VALUES ('r','th','alice','stateless','chat',1,'{}','running','{}',now(),now());
    INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at) VALUES ('task','r','chat','stateless_read',1000,'v1','running',now(),now());
    INSERT INTO worker_assignments(id,space_id,worker_instance_id,worker_snapshot_json,worker_type_id,status,run_id,task_id,attempt_id,idempotency_key,created_at,updated_at) VALUES ('a','sp','w','{}','chatgpt','running',NULL,'task','att','key',now(),now());`);
  // run_id must match the wire and references an existing Run.
  await f.sqlite.exec(`INSERT INTO runs(id,space_id,thread_id,work_request_id,status,created_at,updated_at) VALUES ('run','sp','th','r','running',now(),now()); UPDATE worker_assignments SET run_id='run' WHERE id='a';`);
  const delivered: unknown[] = [];
  const realtime = { getByName: () => ({ fetch: async (request: Request) => {
    delivered.push(await request.json());
    return new Response(null, { status: 200 });
  } }) };
  const gateway = new WorkerGateway({} as never, { SYNTILA_DB: f.db, SYNTILA_REALTIME_GATEWAY: realtime } as never) as any;
  gateway.knownWorkerId = "w";
  gateway.attachment = { fence: { workerInstanceId: "w", sessionId: "s", epoch: 1 } };
  const frame = {
    protocol: "syntila.worker-agent-protocol", protocolVersion: "5.1", messageId: "m", timestamp: new Date().toISOString(),
    type: "assignment.activity", executionWorkspaceId: "worker:w", workspaceRuntimeId: "worker:w", workerId: "w", runId: "run", taskId: "task", attemptId: "att", assignmentId: "a", idempotencyKey: "key",
    payload: { assignmentId: "a", executionId: "exec", workerId: "chatgpt", eventId: "ev", sequence: 1, timestamp: new Date().toISOString(), eventType: "tool.started", status: "running", title: "Reading files" },
  };
  await gateway.handle(JSON.stringify(frame));
  const events = await f.sqlite.prepare("SELECT event_type, stream_kind, stream_id, thread_id FROM realtime_events WHERE assignment_id='a'").all();
  expect(events).toHaveLength(0);
  expect(delivered).toEqual([expect.objectContaining({ type: "assignment.activity", stream: { kind: "space", id: "sp" }, threadId: "th" })]);
  frame.payload.eventId = "status";
  frame.payload.sequence = 2;
  frame.payload.eventType = "model.status";
  frame.payload.status = "updated";
  await gateway.handle(JSON.stringify(frame));
  expect(delivered).toHaveLength(2);
  expect(await f.sqlite.prepare("SELECT event_id FROM realtime_events WHERE assignment_id='a'").all()).toHaveLength(0);
  await f.sqlite.exec("UPDATE worker_agent_sessions SET session_epoch=2 WHERE worker_instance_id='w'");
  frame.payload.eventId = "ev2";
  frame.payload.sequence = 3;
  await gateway.handle(JSON.stringify(frame));
  expect(delivered).toHaveLength(2);
  await publishAssignmentPhase({ SYNTILA_DB: f.db } as never, "a", { strict: true });
  expect(await f.sqlite.prepare("SELECT event_type, stream_id FROM realtime_events WHERE event_type='step.phase'").get()).toMatchObject({ event_type: "step.phase", stream_id: "sp" });
  await f.sqlite.close();
});
