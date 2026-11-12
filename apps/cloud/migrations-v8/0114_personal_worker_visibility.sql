-- Personal display preferences are independent of Workspace sharing policies.
CREATE TABLE workspace_worker_preferences (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  preferences_json TEXT NOT NULL CHECK (json_valid(preferences_json)),
  updated_at TEXT NOT NULL,
  PRIMARY KEY (user_id, workspace_id)
);
