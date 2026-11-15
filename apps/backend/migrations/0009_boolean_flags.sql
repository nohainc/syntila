-- Flags become real booleans. They came from SQLite as smallint 0/1 with a
-- CHECK; PostgreSQL has a boolean type, so the check and the "= 1" idiom go.
-- (The D1 adapter still reports booleans to the domain code as 1/0.)
ALTER TABLE direct_space_user_state DROP CONSTRAINT direct_space_user_state_hidden_check;
ALTER TABLE direct_space_user_state ALTER COLUMN hidden DROP DEFAULT;
ALTER TABLE direct_space_user_state ALTER COLUMN hidden TYPE boolean USING (hidden <> 0);
ALTER TABLE direct_space_user_state ALTER COLUMN hidden SET DEFAULT false;
ALTER TABLE execution_workspaces DROP CONSTRAINT execution_workspaces_space_ai_chat_check;
ALTER TABLE execution_workspaces ALTER COLUMN space_ai_chat DROP DEFAULT;
ALTER TABLE execution_workspaces ALTER COLUMN space_ai_chat TYPE boolean USING (space_ai_chat <> 0);
ALTER TABLE execution_workspaces ALTER COLUMN space_ai_chat SET DEFAULT false;
ALTER TABLE execution_workspaces DROP CONSTRAINT execution_workspaces_space_ai_work_check;
ALTER TABLE execution_workspaces ALTER COLUMN space_ai_work DROP DEFAULT;
ALTER TABLE execution_workspaces ALTER COLUMN space_ai_work TYPE boolean USING (space_ai_work <> 0);
ALTER TABLE execution_workspaces ALTER COLUMN space_ai_work SET DEFAULT false;
ALTER TABLE threads DROP CONSTRAINT threads_has_other_contributions_check;
ALTER TABLE threads ALTER COLUMN has_other_contributions DROP DEFAULT;
ALTER TABLE threads ALTER COLUMN has_other_contributions TYPE boolean USING (has_other_contributions <> 0);
ALTER TABLE threads ALTER COLUMN has_other_contributions SET DEFAULT false;
ALTER TABLE threads DROP CONSTRAINT threads_is_general_check;
ALTER TABLE threads ALTER COLUMN is_general DROP DEFAULT;
ALTER TABLE threads ALTER COLUMN is_general TYPE boolean USING (is_general <> 0);
ALTER TABLE threads ALTER COLUMN is_general SET DEFAULT false;
ALTER TABLE users DROP CONSTRAINT users_email_verified_check;
ALTER TABLE users ALTER COLUMN email_verified DROP DEFAULT;
ALTER TABLE users ALTER COLUMN email_verified TYPE boolean USING (email_verified <> 0);
ALTER TABLE users ALTER COLUMN email_verified SET DEFAULT false;
ALTER TABLE users DROP CONSTRAINT users_share_read_receipts_check;
ALTER TABLE users ALTER COLUMN share_read_receipts DROP DEFAULT;
ALTER TABLE users ALTER COLUMN share_read_receipts TYPE boolean USING (share_read_receipts <> 0);
ALTER TABLE users ALTER COLUMN share_read_receipts SET DEFAULT true;
ALTER TABLE workspace_releases DROP CONSTRAINT workspace_releases_is_revoked_check;
ALTER TABLE workspace_releases ALTER COLUMN is_revoked DROP DEFAULT;
ALTER TABLE workspace_releases ALTER COLUMN is_revoked TYPE boolean USING (is_revoked <> 0);
ALTER TABLE workspace_releases ALTER COLUMN is_revoked SET DEFAULT false;
ALTER TABLE workspace_worker_plugin_enablements DROP CONSTRAINT workspace_worker_plugin_enablements_shareable_check;
ALTER TABLE workspace_worker_plugin_enablements ALTER COLUMN shareable DROP DEFAULT;
ALTER TABLE workspace_worker_plugin_enablements ALTER COLUMN shareable TYPE boolean USING (shareable <> 0);
ALTER TABLE workspace_worker_plugin_enablements ALTER COLUMN shareable SET DEFAULT false;

-- A guard for batches: evaluates to an error that aborts the transaction.
-- Replaces the SQLite idiom of writing an out-of-range value into a checked
-- column. Reported as a check violation, like the constraint it replaces.
CREATE FUNCTION syntila_guard_failed(guard text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'guard failed: %', guard USING ERRCODE = 'check_violation', CONSTRAINT = guard;
END $$;

CREATE OR REPLACE FUNCTION trg_thread_discussion_contributor_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.event_type IS NULL AND NEW.kind != 'ai_answer' THEN
    UPDATE threads SET has_other_contributions = TRUE
    WHERE id = NEW.thread_id AND lead_user_id != NEW.author_user_id AND NOT has_other_contributions;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION trg_thread_request_contributor_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE threads SET has_other_contributions = TRUE
  WHERE id = NEW.thread_id AND lead_user_id != NEW.requested_by_user_id AND NOT has_other_contributions;
  RETURN NEW;
END $$;
