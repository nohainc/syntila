import { loadConversationWorkflowStepRuns } from "./conversation-workflow-step-runs.js";
import type { WorkflowRun } from "@syntila/core";

/** Call after authorizing the enclosing request collection. Lifecycle has one owner: Work Request. */
export async function loadConversationWorkflowRuns(
  db: D1Database,
  workRequestIds: readonly string[],
): Promise<Map<string, WorkflowRun>> {
  if (!workRequestIds.length) return new Map();
  const rows = await db
    .prepare(
      `SELECT wfr.id, wfr.conversation_id AS conversationId,
    wfr.user_message_id AS userMessageId, wfr.user_message_id AS triggerMessageId, wfr.work_request_id AS workRequestId,
    wfr.workflow_id AS workflowId, wfr.workflow_version AS workflowVersion,
    (wr.snapshot_json::jsonb #>> '{stepExecutionConfigs}') AS executionConfigsJson,
    wr.status, wfr.created_at AS createdAt, wr.updated_at AS updatedAt,
    wfr.started_at AS startedAt, wfr.completed_at AS completedAt,
    (SELECT COALESCE(json_agg(id ORDER BY created_at, id)::text, '[]') FROM runs WHERE work_request_id=wfr.work_request_id) AS runtimeRunIdsJson,
    (SELECT COALESCE(json_agg(id ORDER BY seq)::text, '[]') FROM conversation_turns WHERE workflow_run_id=wfr.id) AS workerTurnIdsJson
    FROM conversation_workflow_runs wfr JOIN work_requests wr ON wr.id=wfr.work_request_id
    WHERE wfr.work_request_id IN (${workRequestIds.map(() => "?").join(",")})`,
    )
    .bind(...workRequestIds)
    .all<
      Omit<
        WorkflowRun,
        "schemaVersion" | "runtimeRunIds" | "workerTurnIds" | "stepRuns"
      > & {
        executionConfigsJson: string | null;
        runtimeRunIdsJson: string;
        workerTurnIdsJson: string;
      }
    >();
  const steps = await loadConversationWorkflowStepRuns(db, workRequestIds);
  return new Map(
    (rows.results ?? []).map(
      ({
        runtimeRunIdsJson,
        workerTurnIdsJson,
        executionConfigsJson,
        ...row
      }) => [
        row.workRequestId,
        {
          ...row,
          schemaVersion: 1,
          stepRuns: steps.get(row.id) ?? [],
          ...(executionConfigsJson
            ? { executionConfigs: JSON.parse(executionConfigsJson) }
            : {}),
          runtimeRunIds: JSON.parse(runtimeRunIdsJson) as string[],
          workerTurnIds: JSON.parse(workerTurnIdsJson) as string[],
        },
      ],
    ),
  );
}
