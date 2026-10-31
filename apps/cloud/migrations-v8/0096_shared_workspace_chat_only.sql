-- A lent Workspace answers only its borrower's Chat (ADR-020 amendment).
-- Invitation acceptance used to seed an override listing no Workers, which
-- shared nothing and blocked Chat. Remove the untouched seeds only; an
-- override the lender saved later keeps its later updated_at.
DELETE FROM workspace_member_overrides
 WHERE policy_json = '{"schemaVersion":1,"mode":"chat","workers":{}}'
   AND EXISTS (
     SELECT 1 FROM workspace_person_grants g
      WHERE g.workspace_id = workspace_member_overrides.workspace_id
        AND g.user_id = workspace_member_overrides.user_id
        AND workspace_member_overrides.updated_at IN (g.created_at, g.updated_at));

-- Space grants on a lent Workspace are read-only: Chat needs nothing more.
UPDATE workspace_space_grants
   SET allowed_permissions_json = '["repository:read"]'
 WHERE status IN ('active', 'suspended')
   AND EXISTS (
     SELECT 1 FROM spaces s
       JOIN execution_workspaces ew ON ew.id = workspace_space_grants.workspace_id
      WHERE s.id = workspace_space_grants.space_id
        AND s.owner_user_id <> ew.owner_user_id);
