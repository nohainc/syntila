import { CONVERSATION_WORKFLOWS } from "@syntila/core";
import { sqliteD1 } from "./sqlite-d1.js";
import {
  conversationSubmissionStatements,
  threadConversationId,
} from "../../../src/domain/routes/conversations.js";
import { loadConversationTurns } from "../../../src/domain/routes/conversation-turns.js";
export async function conversationFixture(
  options: { beforeTurnLifecycleRepair?: boolean; research?: boolean } = {},
) {
  const { sqlite, db } = sqliteD1(options);
  sqlite.exec(`
 INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('U','u@test','User','now','now');
 INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('P','U','Space','now','now');
 INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('W','P','Stream','active','U','now','now');
 INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('WS','U','Workspace','now','now');
 INSERT INTO workspace_runtime_identities(id,workspace_id,credential_token_hash,installation_id,created_at) VALUES('RT','WS','test-hash','installation','now');
 INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
 VALUES('R','W','U','stateless','${options.research ? "research" : "chat"}',${options.research ? 2 : 1},'{}','running','{"originalRequest":"**Exact user text**"}','2026-10-07T10:00:00Z','now');
 INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at)
 VALUES('T','R','chat','stateless_read',1000,'chat:v1','running','now','now');`);
  await db.batch(
    conversationSubmissionStatements(
      db as unknown as D1Database,
      threadConversationId("W"),
      "W",
      CONVERSATION_WORKFLOWS.chat!,
      "R",
      "now",
    ),
  );
  const assign = (
    id: string,
    model: string | null = "model-x",
    effort: string | null = "medium",
    sessionPolicy = "durable_session",
    baseContextRevision?: number,
    contextSnapshot?: Record<string, unknown>,
    executionSelection?: Record<string, unknown>,
  ) =>
    sqlite
      .prepare(
        `INSERT INTO worker_assignments
 (id,space_id,execution_workspace_id,runtime_identity_id,worker_type_id,workspace_worker_id,task_id,status,model,permission_snapshot_json,session_policy,created_at,updated_at)
 VALUES(?,'P','WS','RT','chatgpt','worker-a','T','created',?,?,?,'2026-10-07T10:01:00Z','2026-10-07T10:01:00Z')`,
      )
      .run(
        id,
        model,
        JSON.stringify({
          profileDefinitionId: "chatgpt-codex",
          profileReleaseVersion: 3,
          workerDisplayName: "ChatGPT",
          ...(executionSelection ? { executionSelection } : {}),
          reasoningEffort: effort,
          workerSessionId: "worker-session-opaque",
          ...(contextSnapshot ? { contextSnapshot } : {}),
          ...(baseContextRevision === undefined ? {} : { baseContextRevision }),
        }),
        sessionPolicy,
      );
  const turns = async () =>
    (await loadConversationTurns(db as unknown as D1Database, ["R"])).get(
      "R",
    ) ?? [];
  const start = (id: string, updatedAt = "now") =>
    sqlite
      .prepare(
        "UPDATE worker_assignments SET status='running', updated_at=? WHERE id=?",
      )
      .run(updatedAt, id);
  return { sqlite, db, assign, start, turns };
}
