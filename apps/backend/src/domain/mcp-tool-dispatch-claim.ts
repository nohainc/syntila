/**
 * Durable Cloud-side at-most-once claim and outcome record for one logical MCP
 * tool step. A claim is not authorization, delivery, or proof that the remote
 * tool ran. Once claimed, an uncertain outcome must never be replayed.
 */
export type McpToolState = "completed" | "toolError" | "rejected" | "unknown";

export interface McpToolCallRecord {
  taskId: string;
  workspaceId: string;
  dispatchKey: string;
  state: McpToolState | null;
  code: string | null;
  result: Record<string, unknown> | null;
}

export async function claimMcpToolDispatch(
  db: D1Database,
  input: { taskId: string; workspaceId: string; claimedAt: string },
): Promise<{ dispatchKey: string } | null> {
  if (
    !input.taskId ||
    input.taskId.length > 900 ||
    !input.workspaceId ||
    !input.claimedAt
  ) {
    throw new TypeError("Invalid MCP dispatch claim");
  }
  // Task IDs are immutable logical-step identities, unlike attempt IDs.
  const dispatchKey = `mcp-tool-v1:${input.taskId}`;
  const row = await db
    .prepare(
      `INSERT INTO mcp_tool_calls (task_id, workspace_id, dispatch_key, claimed_at)
       SELECT t.id, ?2, ?3, ?4
       FROM workflow_tasks t
       WHERE t.id = ?1 AND t.step_kind = 'tool_call'
       ON CONFLICT(task_id) DO NOTHING
       RETURNING dispatch_key`,
    )
    .bind(input.taskId, input.workspaceId, dispatchKey, input.claimedAt)
    .first<{ dispatch_key: string }>();
  return row ? { dispatchKey: row.dispatch_key } : null;
}

/** First outcome wins; a later report can never overwrite a recorded one. */
export async function recordMcpToolOutcome(
  db: D1Database,
  input: {
    taskId: string;
    state: McpToolState;
    code: string;
    result?: Record<string, unknown>;
    completedAt: string;
  },
): Promise<boolean> {
  const carried =
    input.result && (input.state === "completed" || input.state === "toolError")
      ? JSON.stringify(input.result)
      : null;
  const row = await db
    .prepare(
      `UPDATE mcp_tool_calls
       SET state = ?2, code = ?3, result_json = ?4, completed_at = ?5
       WHERE task_id = ?1 AND state IS NULL
       RETURNING task_id`,
    )
    .bind(input.taskId, input.state, input.code, carried, input.completedAt)
    .first<{ task_id: string }>();
  return row !== null;
}

export async function loadMcpToolCall(
  db: D1Database,
  taskId: string,
): Promise<McpToolCallRecord | null> {
  const row = await db
    .prepare(
      `SELECT task_id, workspace_id, dispatch_key, state, code, result_json
       FROM mcp_tool_calls WHERE task_id = ?1`,
    )
    .bind(taskId)
    .first<{
      task_id: string;
      workspace_id: string;
      dispatch_key: string;
      state: McpToolState | null;
      code: string | null;
      result_json: string | null;
    }>();
  return row
    ? {
        taskId: row.task_id,
        workspaceId: row.workspace_id,
        dispatchKey: row.dispatch_key,
        state: row.state,
        code: row.code,
        result: row.result_json ? JSON.parse(row.result_json) : null,
      }
    : null;
}
