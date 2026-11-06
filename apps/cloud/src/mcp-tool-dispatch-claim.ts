/**
 * Durable Cloud-side at-most-once claim for one logical MCP tool step.
 * This is not assignment authorization, delivery, or proof that the remote
 * tool ran. Once claimed, an uncertain outcome must never be replayed.
 */
export async function claimMcpToolDispatch(
  db: D1Database,
  input: {
    taskId: string;
    assignmentId: string;
    workspaceId: string;
    claimedAt: string;
  },
): Promise<{ dispatchKey: string } | null> {
  if (
    !input.taskId ||
    input.taskId.length > 900 ||
    !input.assignmentId ||
    !input.workspaceId ||
    !input.claimedAt
  ) {
    throw new TypeError("Invalid MCP dispatch claim");
  }
  // Task IDs are immutable logical-step identities, unlike attempt IDs. The
  // key is not a credential, but is still scoped by the row and assignment.
  const dispatchKey = `mcp-tool-v1:${input.taskId}`;
  const row = await db
    .prepare(
      `INSERT INTO mcp_tool_dispatch_claims
        (task_id, workspace_id, assignment_id, dispatch_key, claimed_at)
       SELECT t.id, a.execution_workspace_id, a.id, ?4, ?5
       FROM workflow_tasks t JOIN worker_assignments a ON a.task_id = t.id
       WHERE t.id = ?1 AND t.step_kind = 'tool_call'
         AND a.id = ?2 AND a.execution_workspace_id = ?3
       ON CONFLICT(task_id) DO NOTHING
       RETURNING dispatch_key`,
    )
    .bind(
      input.taskId,
      input.assignmentId,
      input.workspaceId,
      dispatchKey,
      input.claimedAt,
    )
    .first<{ dispatch_key: string }>();
  return row ? { dispatchKey: row.dispatch_key } : null;
}
