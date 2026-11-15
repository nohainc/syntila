-- Attribute-bag documents become jsonb: history metadata, audit and
-- diagnostic details, error documents. PostgreSQL stores them parsed and can
-- query and index them.
--
-- Documents whose key order or exact text matters stay validated text
-- (CHECK ... IS JSON): request and workflow snapshots, signed Worker
-- Profiles, plugin manifests, idempotency receipts and configuration
-- documents. jsonb does not keep key order (it sorts keys), and code that
-- walks such a document in order, or signs it, would silently change.
--
-- The D1 adapter hands jsonb to the domain code as JSON text and accepts
-- JSON text for it (src/platform/pg-d1.ts), so domain code is unchanged.

ALTER TABLE auth_audit_events DROP CONSTRAINT auth_audit_events_details_json_is_json;
ALTER TABLE auth_audit_events ALTER COLUMN details_json DROP DEFAULT;
ALTER TABLE auth_audit_events ALTER COLUMN details_json TYPE jsonb USING details_json::jsonb;
ALTER TABLE auth_audit_events ALTER COLUMN details_json SET DEFAULT '{}'::jsonb;
ALTER TABLE conversation_history_entries DROP CONSTRAINT conversation_history_entries_metadata_json_is_json;
ALTER TABLE conversation_history_entries ALTER COLUMN metadata_json DROP DEFAULT;
ALTER TABLE conversation_history_entries ALTER COLUMN metadata_json TYPE jsonb USING metadata_json::jsonb;
ALTER TABLE conversation_history_entries ALTER COLUMN metadata_json SET DEFAULT '{}'::jsonb;
ALTER TABLE issue_report_diagnostics DROP CONSTRAINT issue_report_diagnostics_diagnostic_json_is_json;
ALTER TABLE issue_report_diagnostics ALTER COLUMN diagnostic_json TYPE jsonb USING diagnostic_json::jsonb;
ALTER TABLE issue_report_events DROP CONSTRAINT issue_report_events_details_json_is_json;
ALTER TABLE issue_report_events ALTER COLUMN details_json DROP DEFAULT;
ALTER TABLE issue_report_events ALTER COLUMN details_json TYPE jsonb USING details_json::jsonb;
ALTER TABLE issue_report_events ALTER COLUMN details_json SET DEFAULT '{}'::jsonb;
ALTER TABLE space_audit_log DROP CONSTRAINT space_audit_log_details_json_is_json;
ALTER TABLE space_audit_log ALTER COLUMN details_json DROP DEFAULT;
ALTER TABLE space_audit_log ALTER COLUMN details_json TYPE jsonb USING details_json::jsonb;
ALTER TABLE space_audit_log ALTER COLUMN details_json SET DEFAULT '{}'::jsonb;
ALTER TABLE threads DROP CONSTRAINT threads_metadata_json_is_json;
ALTER TABLE threads ALTER COLUMN metadata_json DROP DEFAULT;
ALTER TABLE threads ALTER COLUMN metadata_json TYPE jsonb USING metadata_json::jsonb;
ALTER TABLE threads ALTER COLUMN metadata_json SET DEFAULT '{}'::jsonb;
ALTER TABLE worker_activity_history DROP CONSTRAINT worker_activity_history_details_json_is_json;
ALTER TABLE worker_activity_history ALTER COLUMN details_json DROP DEFAULT;
ALTER TABLE worker_activity_history ALTER COLUMN details_json TYPE jsonb USING details_json::jsonb;
ALTER TABLE worker_activity_history ALTER COLUMN details_json SET DEFAULT '{}'::jsonb;
ALTER TABLE worker_assignments DROP CONSTRAINT worker_assignments_error_json_is_json;
ALTER TABLE worker_assignments ALTER COLUMN error_json TYPE jsonb USING error_json::jsonb;
ALTER TABLE worker_assignments DROP CONSTRAINT worker_assignments_startup_detail_json_is_json;
ALTER TABLE worker_assignments ALTER COLUMN startup_detail_json TYPE jsonb USING startup_detail_json::jsonb;
ALTER TABLE worker_scheduling_audit DROP CONSTRAINT worker_scheduling_audit_details_json_is_json;
ALTER TABLE worker_scheduling_audit ALTER COLUMN details_json DROP DEFAULT;
ALTER TABLE worker_scheduling_audit ALTER COLUMN details_json TYPE jsonb USING details_json::jsonb;
ALTER TABLE worker_scheduling_audit ALTER COLUMN details_json SET DEFAULT '{}'::jsonb;
ALTER TABLE workspace_audit_log DROP CONSTRAINT workspace_audit_log_details_json_is_json;
ALTER TABLE workspace_audit_log ALTER COLUMN details_json DROP DEFAULT;
ALTER TABLE workspace_audit_log ALTER COLUMN details_json TYPE jsonb USING details_json::jsonb;
ALTER TABLE workspace_audit_log ALTER COLUMN details_json SET DEFAULT '{}'::jsonb;

-- jsonb versions of the document helpers (the text versions stay for text input).
CREATE FUNCTION syntila_json_set(doc jsonb, path text, value text) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE p text[] := syntila_json_path(path); d jsonb := COALESCE(doc, '{}'::jsonb); i int;
BEGIN
  FOR i IN 1 .. coalesce(array_length(p, 1), 0) - 1 LOOP
    IF jsonb_typeof(d #> p[1:i]) IS DISTINCT FROM 'object' THEN d := jsonb_set(d, p[1:i], '{}'::jsonb, true); END IF;
  END LOOP;
  RETURN jsonb_set(d, p, value::jsonb, true);
END $$;

CREATE FUNCTION syntila_json_remove(doc jsonb, path text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$ SELECT COALESCE(doc, '{}'::jsonb) #- syntila_json_path(path) $$;

CREATE FUNCTION syntila_json_patch(doc jsonb, patch text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$ SELECT syntila_jsonb_merge_patch(COALESCE(doc, '{}'::jsonb), patch::jsonb) $$;

-- History triggers built their metadata as text; they now pass jsonb.
CREATE OR REPLACE FUNCTION trg_history_artifact_created_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'artifact_event',
    'artifact.created',
    'syntila',
    NULL,
    cr.work_request_id,
    NULL,
    NEW.id,
    NEW.id,
    NULL,
    jsonb_build_object('contentDigest', NEW.content_digest),
    NULL,
    NEW.created_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = COALESCE(NEW.work_request_id, (SELECT wt.work_request_id FROM workflow_tasks wt JOIN worker_assignments wa ON wa.task_id = wt.id WHERE wa.id = NEW.assignment_id), (SELECT work_request_id FROM runs WHERE id = NEW.run_id));
  RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION trg_history_artifact_removed_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'artifact_event',
    'artifact.removed',
    'syntila',
    NULL,
    cr.work_request_id,
    NULL,
    OLD.id,
    OLD.id,
    NULL,
    jsonb_build_object('contentDigest', OLD.content_digest),
    NULL,
    now()
  FROM conversation_work_requests cr WHERE cr.work_request_id = COALESCE(OLD.work_request_id, (SELECT wt.work_request_id FROM workflow_tasks wt JOIN worker_assignments wa ON wa.task_id = wt.id WHERE wa.id = OLD.assignment_id), (SELECT work_request_id FROM runs WHERE id = OLD.run_id));
  RETURN OLD;
END $function$
;

CREATE OR REPLACE FUNCTION trg_history_context_revision_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.context_revision > OLD.context_revision THEN
    PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.id), 0) + 1,
    'context_event',
    'context.revision_advanced',
    'syntila',
    NULL,
    NULL,
    NULL,
    NULL,
    NEW.id,
    NULL,
    jsonb_build_object('previousRevision', OLD.context_revision, 'contextRevision', NEW.context_revision),
    NULL,
    NEW.updated_at;
  END IF;
  RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION trg_history_execution_created_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'execution_event',
    'execution.created',
    'syntila',
    NULL,
    NEW.work_request_id,
    NEW.id,
    NULL,
    NEW.id,
    NULL,
    jsonb_build_object('workerId', NEW.worker_id, 'workerTypeId', NEW.worker_type_id, 'workerDisplayName', NEW.worker_display_name, 'profileId', NEW.profile_id, 'profileVersion', NEW.profile_version, 'modelId', NEW.model_id, 'effort', NEW.effort, 'workflowId', NEW.workflow_id, 'workflowVersion', NEW.workflow_version, 'userMessageId', NEW.user_message_id, 'assignmentId', NEW.assignment_id, 'taskId', NEW.task_id, 'stepKind', NEW.step_kind, 'workerSessionId', NEW.worker_session_id, 'baseContextRevision', NEW.base_context_revision),
    NULL,
    NEW.created_at;
  RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION trg_history_execution_status_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'execution_event',
    'execution.' || CASE WHEN NEW.status = 'running' THEN 'started' ELSE NEW.status END,
    'syntila',
    NULL,
    NEW.work_request_id,
    NEW.id,
    NULL,
    NEW.id,
    NULL,
    jsonb_build_object('from', OLD.status, 'to', NEW.status, 'assignmentId', NEW.assignment_id, 'startedAt', syntila_iso(NEW.started_at), 'completedAt', syntila_iso(NEW.completed_at)),
    NULL,
    COALESCE(NEW.completed_at, NEW.started_at, NEW.created_at);
  END IF;
  RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION trg_history_request_accepted_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'workflow_event',
    'workflow.request_accepted',
    'syntila',
    NULL,
    NEW.work_request_id,
    NULL,
    NULL,
    NEW.work_request_id,
    NULL,
    jsonb_build_object('workflowId', wr.workflow_id, 'workflowVersion', wr.workflow_version, 'status', wr.status, 'conversationRevision', NEW.conversation_revision),
    NULL,
    wr.created_at
  FROM work_requests wr WHERE wr.id = NEW.work_request_id;
  RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION trg_history_request_status_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event',
    'workflow.request_status_changed',
    'syntila',
    NULL,
    NEW.id,
    NULL,
    NULL,
    NEW.id,
    NULL,
    jsonb_build_object('from', OLD.status, 'to', NEW.status, 'workflowId', NEW.workflow_id, 'workflowVersion', NEW.workflow_version),
    NULL,
    NEW.updated_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.id;
  END IF;
  RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION trg_history_run_created_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event',
    'workflow.run_created',
    'syntila',
    NULL,
    NEW.work_request_id,
    NULL,
    NULL,
    NEW.id,
    NULL,
    jsonb_build_object('status', NEW.status),
    NULL,
    NEW.created_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
  RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION trg_history_run_status_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event',
    'workflow.run_status_changed',
    'syntila',
    NULL,
    NEW.work_request_id,
    NULL,
    NULL,
    NEW.id,
    NULL,
    jsonb_build_object('from', OLD.status, 'to', NEW.status),
    NULL,
    NEW.updated_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
  END IF;
  RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION trg_history_step_created_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event', 'workflow.step_created', 'syntila', NULL,
    NEW.work_request_id, NULL, NULL, NEW.id, NULL,
    jsonb_build_object('status', NEW.status, 'stepKind', NEW.step_kind, 'stepId', NEW.step_id, 'attempt', NEW.attempt),
    NULL, NEW.created_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
  RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION trg_history_step_status_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event', 'workflow.step_status_changed', 'syntila', NULL,
    NEW.work_request_id, NULL, NULL, NEW.id, NULL,
    jsonb_build_object('from', OLD.status, 'to', NEW.status, 'stepKind', NEW.step_kind, 'stepId', NEW.step_id, 'attempt', NEW.attempt),
    NULL, NEW.updated_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
  END IF;
  RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION trg_history_user_message_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'user_message',
    'message.user_created',
    'user',
    NEW.author_user_id,
    NEW.work_request_id,
    NULL,
    NULL,
    NEW.id,
    NEW.text,
    jsonb_build_object('userMessageId', NEW.id),
    'user:' || NEW.id,
    NEW.created_at;
  RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION trg_history_worker_response_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'completed' AND NEW.result_text IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'worker_response',
    'message.worker_created',
    'worker',
    NEW.worker_id,
    NEW.work_request_id,
    NEW.id,
    NULL,
    NEW.id,
    NEW.result_text,
    jsonb_build_object('workerId', NEW.worker_id, 'workerTypeId', NEW.worker_type_id, 'workerDisplayName', NEW.worker_display_name, 'profileId', NEW.profile_id, 'profileVersion', NEW.profile_version, 'modelId', NEW.model_id, 'effort', NEW.effort, 'workflowId', NEW.workflow_id, 'workflowVersion', NEW.workflow_version, 'userMessageId', NEW.user_message_id, 'assignmentId', NEW.assignment_id, 'taskId', NEW.task_id, 'stepKind', NEW.step_kind, 'workerSessionId', NEW.worker_session_id, 'baseContextRevision', NEW.base_context_revision),
    'worker:' || NEW.id,
    NEW.completed_at;
  END IF;
  RETURN NEW;
END $function$
;
