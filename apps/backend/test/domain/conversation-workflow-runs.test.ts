import { pgD1 } from "./helpers/pg-d1";
import { expect, it } from "./helpers/vitest-compat";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { conversationFixture } from "./helpers/conversation.js";
import { loadConversationWorkflowRuns } from "../../src/domain/routes/conversation-workflow-runs.js";

it("one user message owns a WorkflowRun with multiple Worker turns and runtime attempts", async () => {
  const f = await conversationFixture();
  try {
    f.sqlite
      .exec(`INSERT INTO runs(id,space_id,thread_id,work_request_id,status,created_at,updated_at) VALUES
      ('RUN1','P','W','R','failed','2001-01-01T00:00:00Z','2001-01-01T00:00:00Z'), ('RUN2','P','W','R','running','2002-01-01T00:00:00Z','2002-01-01T00:00:00Z');`);
    const pending = (
      await loadConversationWorkflowRuns(f.db as unknown as D1Database, ["R"])
    ).get("R")!;
    expect(pending.workerTurnIds).toEqual([]);
    expect(pending.stepRuns).toHaveLength(1);
    expect(pending.triggerMessageId).toBe(pending.userMessageId);
    expect(() =>
      f.sqlite.exec(
        "INSERT INTO conversation_workflow_runs(id,conversation_id,user_message_id,work_request_id,workflow_id,workflow_version,created_at) SELECT 'foreign-run',conversation_id,user_message_id,work_request_id,'direct',2,created_at FROM conversation_workflow_runs",
      ),
    ).toThrow(/scoped user message/);
    f.assign("A");
    f.assign("B", "model-y", "high");
    f.sqlite
      .exec(`INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at)
      VALUES('VERIFY','R','verify','stateless_read',1000,'verify:v1','queued','now','now');
      INSERT INTO worker_assignments(id,space_id,execution_workspace_id,runtime_identity_id,worker_type_id,workspace_worker_id,task_id,run_id,status,permission_snapshot_json,created_at,updated_at)
      VALUES('V','P','WS','RT','gemini','worker-gemini','VERIFY','RUN2','created','{"profileDefinitionId":"gemini-antigravity","profileReleaseVersion":1,"workerDisplayName":"Gemini"}','now','now');`);
    const run = (
      await loadConversationWorkflowRuns(f.db as unknown as D1Database, ["R"])
    ).get("R")!;
    expect(run).toMatchObject({
      schemaVersion: 1,
      id: "workflow-run-R",
      userMessageId: "message-user-R",
      workRequestId: "R",
      status: "running",
      runtimeRunIds: ["RUN1", "RUN2"],
      workerTurnIds: ["turn-A", "turn-B", "turn-V"],
    });
    expect(run.stepRuns).toHaveLength(2);
    expect(
      run.stepRuns.find((step) => step.stepId === "chat")?.workerTurnIds,
    ).toEqual(["turn-A", "turn-B"]);
    expect(run.stepRuns.find((step) => step.stepId === "verify")).toMatchObject(
      {
        id: "step-run-VERIFY",
        workflowRunId: run.id,
        role: "verify",
        workerId: "worker-gemini",
      },
    );
    const turns = await f.turns();
    expect(new Set(turns.map((turn) => turn.workflowRunId))).toEqual(
      new Set([run.id]),
    );
    expect(new Set(turns.map((turn) => turn.userMessageId))).toEqual(
      new Set([run.userMessageId]),
    );
    expect(turns[2]).toMatchObject({
      runtimeRunId: "RUN2",
      stepKind: "verify",
      workerTypeId: "gemini",
    });
    expect(() =>
      f.sqlite.exec(
        "UPDATE conversation_turns SET workflow_run_id='foreign' WHERE id='turn-A'",
      ),
    ).toThrow(/immutable/);
    expect(() =>
      f.sqlite.exec(
        "UPDATE conversation_workflow_runs SET user_message_id='foreign'",
      ),
    ).toThrow(/immutable/);
    f.sqlite.exec(
      "UPDATE work_requests SET status='completed',updated_at='2030-01-01T00:00:00.000Z' WHERE id='R'",
    );
    const completed = (
      await loadConversationWorkflowRuns(f.db as unknown as D1Database, ["R"])
    ).get("R")!;
    expect(completed.status).toBe("completed");
    expect(completed.workerTurnIds).toEqual(run.workerTurnIds);
    expect(
      (
        await loadConversationWorkflowRuns(f.db as unknown as D1Database, [
          "missing",
        ])
      ).size,
    ).toBe(0);
  } finally {
    f.sqlite.close();
  }
});

