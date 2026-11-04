-- Spaces no longer inherit the owner's account-level Workspace. Attaching a
-- Workspace to a Space lets its Workers run on that machine, so every Space now
-- records its own choice. This keeps today's effective selection for existing
-- Spaces: an inheriting Space gets its owner's selection if that Workspace is
-- still usable, otherwise no Workspace (the owner must choose one).
INSERT INTO space_workflow_settings(space_id, workspace_id, updated_at)
SELECT s.id,
       CASE WHEN ew.status IS NOT NULL AND ew.status != 'revoked'
            THEN uws.workspace_id END,
       COALESCE(uws.updated_at, s.updated_at)
  FROM spaces s
  LEFT JOIN user_workflow_settings uws ON uws.user_id = s.owner_user_id
  LEFT JOIN execution_workspaces ew ON ew.id = uws.workspace_id
 WHERE NOT EXISTS (
   SELECT 1 FROM space_workflow_settings sws WHERE sws.space_id = s.id
 );
