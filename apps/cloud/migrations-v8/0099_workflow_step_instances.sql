-- Step-instance identity (ADR-026 Phase 2). A built-in Workflow may now run
-- the same semantic step kind more than once (Research v2: research-1,
-- research-2, ... then synthesis). `workflow_tasks.step_id` is the stable
-- step-instance ID and replaces `step_kind` in the per-request uniqueness;
-- existing rows get `step_id = step_kind`, which is exactly the instance ID
-- of every older definition, so task IDs, history and Step Runs are unchanged.
-- `synthesis` joins the allowed step kinds.
-- D1 migrations execute atomically with foreign keys enabled.
PRAGMA defer_foreign_keys = ON;

CREATE TABLE __migration_0099_tasks AS SELECT * FROM workflow_tasks;
CREATE TABLE __migration_0099_dependencies AS SELECT * FROM workflow_task_dependencies;
CREATE TABLE __migration_0099_step_runs AS SELECT * FROM conversation_workflow_step_runs;

-- Children first: a RESTRICT dependency would refuse the parent drop, and the
-- CASCADE children are restored from the copies below.
DELETE FROM workflow_task_dependencies;
DELETE FROM conversation_workflow_step_runs;
DROP TABLE workflow_tasks;

CREATE TABLE workflow_tasks (
  id TEXT PRIMARY KEY,
  work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  step_kind TEXT NOT NULL CHECK (
    step_kind IN ('chat', 'research', 'plan', 'implement', 'test', 'verify', 'synthesis')
  ),
  execution_mode TEXT NOT NULL CHECK (
    execution_mode IN ('stateless_read', 'stateful_thread')
  ),
  timeout_ms INTEGER NOT NULL CHECK (timeout_ms >= 1000),
  prompt_profile_version TEXT NOT NULL,
  status TEXT NOT NULL CHECK (
    status IN ('queued', 'running', 'waiting', 'completed', 'failed', 'cancelled')
  ),
  attempt INTEGER NOT NULL DEFAULT 0 CHECK (attempt >= 0),
  output_json TEXT,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  started_at TEXT,
  finished_at TEXT,
  -- Written only when a definition repeats a kind; otherwise the instance
  -- ID is the kind, which `step_id` derives.
  step_instance_id TEXT CHECK (
    step_instance_id IS NULL OR length(step_instance_id) BETWEEN 1 AND 64
  ),
  step_id TEXT GENERATED ALWAYS AS (COALESCE(step_instance_id, step_kind)) STORED,
  UNIQUE (work_request_id, step_id)
);

INSERT INTO workflow_tasks (id, work_request_id, step_kind, execution_mode,
  timeout_ms, prompt_profile_version, status, attempt, output_json, error,
  created_at, updated_at, started_at, finished_at)
SELECT id, work_request_id, step_kind, execution_mode, timeout_ms,
  prompt_profile_version, status, attempt, output_json, error, created_at,
  updated_at, started_at, finished_at
FROM __migration_0099_tasks;
INSERT INTO workflow_task_dependencies SELECT * FROM __migration_0099_dependencies;
INSERT INTO conversation_workflow_step_runs SELECT * FROM __migration_0099_step_runs;

CREATE INDEX idx_workflow_tasks_request
  ON workflow_tasks(work_request_id, status, created_at);

-- Recreated after the copy so restoring rows does not emit history again.
CREATE TRIGGER trg_history_step_created
AFTER INSERT ON workflow_tasks
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event', 'workflow.step_created', 'syntila', NULL,
    NEW.work_request_id, NULL, NULL, NEW.id, NULL,
    json_object('status', NEW.status, 'stepKind', NEW.step_kind, 'stepId', NEW.step_id, 'attempt', NEW.attempt),
    NULL, NEW.created_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
END;

CREATE TRIGGER trg_history_step_status
AFTER UPDATE OF status ON workflow_tasks
WHEN OLD.status IS NOT NEW.status
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event', 'workflow.step_status_changed', 'syntila', NULL,
    NEW.work_request_id, NULL, NULL, NEW.id, NULL,
    json_object('from', OLD.status, 'to', NEW.status, 'stepKind', NEW.step_kind, 'stepId', NEW.step_id, 'attempt', NEW.attempt),
    NULL, NEW.updated_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
END;

-- A Step Run's step_id is the step-instance ID; its role is the step kind.
CREATE TRIGGER trg_workflow_step_run_task_insert AFTER INSERT ON workflow_tasks
BEGIN
 INSERT INTO conversation_workflow_step_runs(id,workflow_run_id,task_id,step_id,role,created_at)
 SELECT 'step-run-' || NEW.id,r.id,NEW.id,NEW.step_id,NEW.step_kind,NEW.created_at
 FROM conversation_workflow_runs r WHERE r.work_request_id=NEW.work_request_id;
END;

DROP TRIGGER trg_workflow_step_run_scope_insert;
CREATE TRIGGER trg_workflow_step_run_scope_insert BEFORE INSERT ON conversation_workflow_step_runs
WHEN NOT EXISTS (SELECT 1 FROM workflow_tasks t JOIN conversation_workflow_runs r ON r.work_request_id=t.work_request_id
 WHERE t.id=NEW.task_id AND r.id=NEW.workflow_run_id AND t.step_id=NEW.step_id AND t.step_kind=NEW.role)
BEGIN SELECT RAISE(ABORT, 'Workflow Step Run must belong to its scoped task and Workflow Run'); END;

-- Verify preservation before discarding the copies.
CREATE TABLE __migration_0099_assertion (valid INTEGER NOT NULL CHECK (valid = 1));
INSERT INTO __migration_0099_assertion SELECT CASE WHEN
  (SELECT COUNT(*) FROM workflow_tasks) = (SELECT COUNT(*) FROM __migration_0099_tasks)
  AND NOT EXISTS (SELECT 1 FROM workflow_tasks WHERE step_id <> step_kind)
  AND (SELECT COUNT(*) FROM workflow_task_dependencies) = (SELECT COUNT(*) FROM __migration_0099_dependencies)
  AND (SELECT COUNT(*) FROM conversation_workflow_step_runs) = (SELECT COUNT(*) FROM __migration_0099_step_runs)
  AND NOT EXISTS (SELECT * FROM pragma_foreign_key_check)
THEN 1 ELSE 0 END;
DROP TABLE __migration_0099_assertion;
DROP TABLE __migration_0099_tasks;
DROP TABLE __migration_0099_dependencies;
DROP TABLE __migration_0099_step_runs;
