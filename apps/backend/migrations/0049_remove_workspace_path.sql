-- The Worker path is the only execution path (ADR-035). Removes the legacy
-- Workspace execution environment: its tables, the Space and Workflow
-- Workspace selections, the per-Workspace Workflow configuration, MCP tool
-- calls through a Workspace, the cutover switches and the legacy Worker
-- mapping. Nothing is in production; data on the removed path is deleted.

-- Functions and triggers that named Workspace columns now name the Worker.
DROP TRIGGER trg_assignment_execution_selection_immutable ON worker_assignments;
DROP TRIGGER trg_work_requests_snapshot_immutable ON work_requests;
CREATE OR REPLACE FUNCTION public.trg_assignment_execution_selection_immutable_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.model IS DISTINCT FROM OLD.model
  OR NEW.worker_type_id IS DISTINCT FROM OLD.worker_type_id
  OR NEW.worker_instance_id IS DISTINCT FROM OLD.worker_instance_id
  OR (NEW.permission_snapshot_json::jsonb #>> '{executionSelection}') IS DISTINCT FROM (OLD.permission_snapshot_json::jsonb #>> '{executionSelection}')
  OR (NEW.permission_snapshot_json::jsonb #>> '{workerDisplayName}') IS DISTINCT FROM (OLD.permission_snapshot_json::jsonb #>> '{workerDisplayName}')
  OR (NEW.permission_snapshot_json::jsonb #>> '{reasoningEffort}') IS DISTINCT FROM (OLD.permission_snapshot_json::jsonb #>> '{reasoningEffort}')
  OR (NEW.permission_snapshot_json::jsonb #>> '{profileDefinitionId}') IS DISTINCT FROM (OLD.permission_snapshot_json::jsonb #>> '{profileDefinitionId}')
  OR (NEW.permission_snapshot_json::jsonb #>> '{profileReleaseVersion}')::bigint IS DISTINCT FROM (OLD.permission_snapshot_json::jsonb #>> '{profileReleaseVersion}')::bigint THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Assignment execution selection is immutable';
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.trg_work_requests_snapshot_immutable_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.thread_id IS DISTINCT FROM NEW.thread_id
  OR OLD.requested_by_user_id IS DISTINCT FROM NEW.requested_by_user_id
  OR OLD.mode IS DISTINCT FROM NEW.mode
  OR OLD.workflow_id IS DISTINCT FROM NEW.workflow_id
  OR OLD.workflow_version IS DISTINCT FROM NEW.workflow_version
  OR OLD.workflow_snapshot_json IS DISTINCT FROM NEW.workflow_snapshot_json
  OR OLD.snapshot_json IS DISTINCT FROM NEW.snapshot_json
  OR OLD.input_json IS DISTINCT FROM NEW.input_json THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Work Request snapshots are immutable';
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.trg_conversation_turn_assignment_insert_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  INSERT INTO conversation_turns (
    id, conversation_id, user_message_id, work_request_id, assignment_id, workflow_run_id, workflow_step_run_id,
    task_id, step_kind, workflow_id, workflow_version,
    worker_id, worker_type_id, worker_display_name, profile_id, profile_version,
    model_id, effort, worker_session_id, base_context_revision, status, created_at
  )
  SELECT 'turn-' || NEW.id, c.id, m.id, wr.id, NEW.id, wfr.id, wsr.id,
    wt.id, wt.step_kind, wr.workflow_id, wr.workflow_version,
    NEW.worker_instance_id, NEW.worker_type_id,
    COALESCE((NEW.permission_snapshot_json::jsonb #>> '{workerDisplayName}'), NEW.worker_type_id),
    (NEW.permission_snapshot_json::jsonb #>> '{profileDefinitionId}'),
    (NEW.permission_snapshot_json::jsonb #>> '{profileReleaseVersion}')::bigint,
    NEW.model, (NEW.permission_snapshot_json::jsonb #>> '{reasoningEffort}'),
    CASE WHEN NEW.session_policy = 'durable_session' THEN (NEW.permission_snapshot_json::jsonb #>> '{workerSessionId}') ELSE NULL END,
    COALESCE((NEW.permission_snapshot_json::jsonb #>> '{baseContextRevision}')::bigint, cr.conversation_revision - 1), 'queued', NEW.created_at
  FROM workflow_tasks wt
  JOIN work_requests wr ON wr.id = wt.work_request_id
  JOIN conversation_work_requests cr ON cr.work_request_id = wr.id
  JOIN conversations c ON c.id = cr.conversation_id
  JOIN conversation_user_messages m ON m.work_request_id = wr.id
  JOIN conversation_workflow_runs wfr ON wfr.work_request_id = wr.id
  JOIN conversation_workflow_step_runs wsr ON wsr.task_id = wt.id AND wsr.workflow_run_id = wfr.id
  WHERE wt.id = NEW.task_id;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.record_ai_answer(p_work_request_id text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  wr record;
  terminal_count int;
  turn record;
  inst_id text;
  inst_actor text;
  inst_name text;
  answer_text text;
  author_actor text;
  snapshot text;
  instance_id text;
  declared_task text;
  declared_count int;
BEGIN
  SELECT id, thread_id, requested_by_user_id, workflow_id, updated_at INTO wr
    FROM work_requests WHERE id = p_work_request_id AND status = 'completed' AND thread_id IS NOT NULL;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT count(*) INTO terminal_count FROM workflow_tasks wt
   WHERE wt.work_request_id = wr.id
     AND NOT EXISTS (SELECT 1 FROM workflow_task_dependencies d WHERE d.depends_on_task_id = wt.id);

  -- A Workflow that declares its answer step (workflow_tasks.answer_step) decides
  -- the answer itself; its Worker is the author, as for a single terminal step.
  SELECT count(*), min(id) INTO declared_count, declared_task FROM workflow_tasks
   WHERE work_request_id = wr.id AND answer_step;
  IF declared_count = 1 THEN terminal_count := 1; END IF;

  SELECT ct.id, ct.worker_id, ct.worker_display_name, ct.completed_at, h.text AS text INTO turn
    FROM conversation_turns ct
    JOIN conversation_history_entries h ON h.turn_id = ct.id AND h.kind = 'worker_response'
   WHERE ct.work_request_id = wr.id AND ct.status = 'completed'
     AND (CASE WHEN declared_count = 1 THEN ct.task_id = declared_task
               ELSE (terminal_count <> 1 OR NOT EXISTS (
                      SELECT 1 FROM workflow_task_dependencies d WHERE d.depends_on_task_id = ct.task_id)) END)
   ORDER BY ct.seq DESC LIMIT 1;
  IF NOT FOUND THEN RETURN; END IF;
  answer_text := turn.text;

  IF terminal_count = 1 THEN
    SELECT w.id, w.actor_id, w.name INTO inst_id, inst_actor, inst_name FROM worker_instances w
     WHERE w.id = turn.worker_id;
  END IF;
  IF inst_id IS NOT NULL THEN
    author_actor := inst_actor;
    instance_id := inst_id;
    snapshot := COALESCE(turn.worker_display_name, inst_name);
  ELSE
    author_actor := 'actor-system-platform';
    instance_id := NULL;
    snapshot := wr.workflow_id;
  END IF;

  INSERT INTO discussion_messages
    (id, thread_id, author_user_id, author_actor_id, worker_instance_id, author_display_snapshot,
     worker_display_name, body, created_at, kind, work_request_id)
  VALUES ('ai-answer-' || wr.id, wr.thread_id, wr.requested_by_user_id, author_actor, instance_id, snapshot,
          snapshot, answer_text, COALESCE(turn.completed_at, wr.updated_at), 'ai_answer', wr.id)
  ON CONFLICT (work_request_id) WHERE kind = 'ai_answer' AND work_request_id IS NOT NULL
  DO UPDATE SET worker_instance_id = EXCLUDED.worker_instance_id, author_actor_id = EXCLUDED.author_actor_id,
                author_display_snapshot = EXCLUDED.author_display_snapshot, worker_display_name = EXCLUDED.worker_display_name,
                body = EXCLUDED.body, created_at = EXCLUDED.created_at, event_type = NULL
    WHERE discussion_messages.event_type IN ('work_failed', 'work_cancelled');
END $function$;

CREATE TRIGGER trg_assignment_execution_selection_immutable BEFORE UPDATE OF permission_snapshot_json, model, worker_type_id, worker_instance_id ON worker_assignments FOR EACH ROW EXECUTE FUNCTION trg_assignment_execution_selection_immutable_fn();
CREATE TRIGGER trg_work_requests_snapshot_immutable BEFORE UPDATE OF thread_id, requested_by_user_id, mode, workflow_id, workflow_version, workflow_snapshot_json, snapshot_json, input_json ON work_requests FOR EACH ROW EXECUTE FUNCTION trg_work_requests_snapshot_immutable_fn();

-- Assignments, leases and requests that ran on a Workspace.
DELETE FROM agent_commands WHERE worker_instance_id IS NULL;
DELETE FROM worker_assignments WHERE execution_path <> 'worker';
DELETE FROM thread_runtime_leases WHERE worker_instance_id IS NULL;

ALTER TABLE worker_assignments DROP CONSTRAINT worker_assignments_one_path_check;
DROP INDEX IF EXISTS worker_assignments_worker_path_idx;
ALTER TABLE worker_assignments
  DROP COLUMN execution_workspace_id,
  DROP COLUMN runtime_identity_id,
  DROP COLUMN workspace_space_grant_id,
  DROP COLUMN workspace_worker_id,
  DROP COLUMN execution_path;
ALTER TABLE worker_assignments ALTER COLUMN worker_instance_id SET NOT NULL;
ALTER TABLE worker_assignments ALTER COLUMN worker_snapshot_json SET NOT NULL;
CREATE INDEX worker_assignments_worker_status_idx ON worker_assignments (worker_instance_id, status);

ALTER TABLE agent_commands ALTER COLUMN worker_instance_id SET NOT NULL;

ALTER TABLE thread_runtime_leases DROP COLUMN workspace_id;
ALTER TABLE thread_runtime_leases ALTER COLUMN worker_instance_id SET NOT NULL;

ALTER TABLE work_requests DROP COLUMN primary_workspace_id;
ALTER TABLE thread_execution_policies DROP COLUMN primary_workspace_id;
ALTER TABLE work_request_inputs DROP COLUMN workspace_id;

-- One default Workflow per person (it was per Workspace).
DELETE FROM user_workflow_defaults d
 USING user_workflow_defaults newer
 WHERE newer.user_id = d.user_id AND newer.updated_at > d.updated_at;
DELETE FROM user_workflow_defaults d
 USING user_workflow_defaults other
 WHERE other.user_id = d.user_id AND other.workspace_id > d.workspace_id;
ALTER TABLE user_workflow_defaults DROP CONSTRAINT user_workflow_defaults_pkey;
ALTER TABLE user_workflow_defaults DROP COLUMN workspace_id;
ALTER TABLE user_workflow_defaults ADD PRIMARY KEY (user_id);

-- Tables of the removed path. CASCADE removes the foreign keys and triggers
-- that point at them.
DROP TABLE IF EXISTS
  workspace_worker_plugin_enablements,
  workspace_worker_preferences,
  workspace_worker_inventory,
  workspace_member_overrides,
  workspace_member_access,
  workspace_person_grants,
  workspace_invitations,
  workspace_space_grants,
  workspace_allowed_folders,
  workspace_audit_log,
  workspace_runtime_facts,
  workspace_sessions,
  workspace_runtime_identities,
  workspace_installations,
  workspace_releases,
  release_signing_key_revocations,
  space_additional_folders,
  space_workflow_settings,
  user_workflow_settings,
  user_workflow_configurations,
  mcp_tool_calls,
  legacy_worker_mapping_archive,
  legacy_worker_mapping,
  legacy_cutover,
  execution_workspaces
  CASCADE;

DROP FUNCTION IF EXISTS
  adopt_inventory_worker(text),
  archive_legacy_worker_mapping(),
  inventory_adopt_worker_fn(),
  inventory_revoke_worker_fn(),
  require_worker_instance_fn(),
  worker_activity_history_set_instance_fn(),
  worker_assignments_set_instance_fn(),
  workspace_invitations_no_active_grant_fn(),
  workspace_person_grants_expire_invitations_fn()
  CASCADE;
