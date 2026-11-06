-- A tool-call step is claimed once for the lifetime of its workflow task.
-- This record is not an MCP result and does not authorize any external call.
CREATE TABLE mcp_tool_dispatch_claims (
  task_id TEXT PRIMARY KEY REFERENCES workflow_tasks(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  assignment_id TEXT NOT NULL UNIQUE REFERENCES worker_assignments(id) ON DELETE RESTRICT,
  dispatch_key TEXT NOT NULL UNIQUE,
  claimed_at TEXT NOT NULL
);
