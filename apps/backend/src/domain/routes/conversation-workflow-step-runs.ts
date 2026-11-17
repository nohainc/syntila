import { queryOf, type Tx, type Db } from "../../platform/data.js";
import {
  planWorkflowTasks,
  type BuiltinWorkflowDefinition,
  type WorkflowStepRun,
} from "@syntila/core";

/** Authorized request scope only. Task state owns lifecycle; turns own actual invocation attribution. */
export async function loadConversationWorkflowStepRuns(
  db: Db,
  workRequestIds: readonly string[],
): Promise<Map<string, WorkflowStepRun[]>> {
  if (!workRequestIds.length) return new Map();
  const q = queryOf(db);
  const rows = await q.rows<
      Omit<WorkflowStepRun, "schemaVersion" | "workerTurnIds"> & {
        workerTurnIdsJson: string;
        executionConfigJson: string | null;
      }
    >`SELECT (wr.snapshot_json::jsonb #>> syntila_json_path('$.stepExecutionConfigs.' || s.step_id)) AS "executionConfigJson", s.id, s.workflow_run_id AS "workflowRunId", s.task_id AS "taskId",
    s.step_id AS "stepId", s.role, t.status,
    CASE WHEN ct.id IS NOT NULL THEN ct.worker_id ELSE COALESCE((wr.snapshot_json::jsonb #>> syntila_json_path('$.resolvedBindings.' || s.step_id || '.workerId')),(wr.snapshot_json::jsonb #>> syntila_json_path('$.resolvedBindings.' || CASE WHEN wr.workflow_id='direct' THEN 'direct' ELSE t.step_kind END || '.workerId'))) END AS "workerId",
    CASE WHEN ct.id IS NOT NULL THEN ct.model_id ELSE COALESCE((wr.snapshot_json::jsonb #>> syntila_json_path('$.resolvedBindings.' || s.step_id || '.model')),(wr.snapshot_json::jsonb #>> syntila_json_path('$.resolvedBindings.' || CASE WHEN wr.workflow_id='direct' THEN 'direct' ELSE t.step_kind END || '.model'))) END AS "modelId",
    CASE WHEN ct.id IS NOT NULL THEN ct.effort ELSE COALESCE((wr.snapshot_json::jsonb #>> syntila_json_path('$.resolvedBindings.' || s.step_id || '.reasoningEffort')),(wr.snapshot_json::jsonb #>> syntila_json_path('$.resolvedBindings.' || CASE WHEN wr.workflow_id='direct' THEN 'direct' ELSE t.step_kind END || '.reasoningEffort'))) END AS effort,
    ct.worker_session_id AS "workerSessionId", COALESCE(ct.base_context_revision,cr.conversation_revision-1) AS "baseContextRevision",
    CASE WHEN t.status='completed' THEN substr(COALESCE(h.text,ct.result_text,(t.output_json::jsonb #>> '{text}'),(t.output_json::jsonb #>> '{output,text}')),1,24000) ELSE NULL END AS result,
    t.started_at AS "startedAt", CASE WHEN t.status IN ('completed','failed','cancelled') THEN t.finished_at ELSE NULL END AS "completedAt",
    (SELECT COALESCE(json_agg(id ORDER BY seq)::text, '[]') FROM conversation_turns WHERE workflow_step_run_id=s.id) AS "workerTurnIdsJson"
    FROM conversation_workflow_step_runs s JOIN workflow_tasks t ON t.id=s.task_id
    JOIN conversation_workflow_runs r ON r.id=s.workflow_run_id
    JOIN work_requests wr ON wr.id=r.work_request_id
    JOIN conversation_work_requests cr ON cr.work_request_id=wr.id
    LEFT JOIN conversation_turns ct ON ct.id=(SELECT id FROM conversation_turns WHERE workflow_step_run_id=s.id ORDER BY seq DESC LIMIT 1)
    LEFT JOIN conversation_history_entries h ON h.turn_id=ct.id AND h.kind='worker_response'
    WHERE wr.id IN ${q.list(workRequestIds)} ORDER BY t.seq`;
  const result = new Map<string, WorkflowStepRun[]>();
  for (const {
    workerTurnIdsJson,
    executionConfigJson,
    ...row
  } of rows) {
    const executionConfig = executionConfigJson
      ? JSON.parse(executionConfigJson)
      : undefined;
    const steps = result.get(row.workflowRunId) ?? [];
    steps.push({
      ...row,
      schemaVersion: 1,
      ...(executionConfig
        ? {
            executionConfig,
            profileId: executionConfig.profileId,
            profileReleaseVersion: executionConfig.profileReleaseVersion,
          }
        : {}),
      workerTurnIds: JSON.parse(workerTurnIdsJson) as string[],
    });
    result.set(row.workflowRunId, steps);
  }
  return result;
}

/** Materialize the logical steps atomically with accepted Conversation requests. */
export async function insertInitialConversationTasks(
  tx: Tx,
  definition: BuiltinWorkflowDefinition,
  workRequestId: string,
  now: string,
): Promise<void> {
  const tasks = planWorkflowTasks(definition, workRequestId);
  for (const task of tasks)
    await tx.run`INSERT INTO workflow_tasks
      (id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,attempt,created_at,updated_at,step_instance_id)
      VALUES (${task.id},${workRequestId},${task.step.kind},${task.step.executionMode},${task.step.timeoutMs},${task.step.promptProfileVersion},'queued',0,${now},${now},${task.step.id ?? null}) ON CONFLICT(work_request_id,step_id) DO NOTHING`;
  for (const task of tasks)
    for (const dependency of task.dependencyTaskIds)
      await tx.run`INSERT INTO workflow_task_dependencies(task_id,depends_on_task_id)
      VALUES (${task.id},${dependency}) ON CONFLICT(task_id,depends_on_task_id) DO NOTHING`;
}
