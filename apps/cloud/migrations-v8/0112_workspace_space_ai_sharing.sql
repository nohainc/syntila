-- Owner-chosen Space AI availability for a Workspace ("Use Space AI for chat"
-- and "Use Space AI for work" on the Workspaces page). Previously held only in
-- client memory, so the choice was lost on navigation.
ALTER TABLE execution_workspaces ADD COLUMN space_ai_chat INTEGER NOT NULL DEFAULT 0
  CHECK (space_ai_chat IN (0, 1));
ALTER TABLE execution_workspaces ADD COLUMN space_ai_work INTEGER NOT NULL DEFAULT 0
  CHECK (space_ai_work IN (0, 1));
