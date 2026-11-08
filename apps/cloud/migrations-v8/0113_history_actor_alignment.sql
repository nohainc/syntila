-- Align pre-rename installations with the canonical Syntila history actor.
-- Rebuild with data intact; refresh history triggers, including step events.
PRAGMA defer_foreign_keys = ON;

DROP TRIGGER IF EXISTS trg_conversation_history_immutable;

DROP TRIGGER IF EXISTS trg_conversation_history_no_delete;

DROP TRIGGER IF EXISTS trg_history_user_message;

DROP TRIGGER IF EXISTS trg_history_request_accepted;

DROP TRIGGER IF EXISTS trg_history_request_status;

DROP TRIGGER IF EXISTS trg_history_run_created;

DROP TRIGGER IF EXISTS trg_history_run_status;

DROP TRIGGER IF EXISTS trg_history_step_created;

DROP TRIGGER IF EXISTS trg_history_step_status;

DROP TRIGGER IF EXISTS trg_history_execution_created;

DROP TRIGGER IF EXISTS trg_history_execution_status;

DROP TRIGGER IF EXISTS trg_history_worker_response;

DROP TRIGGER IF EXISTS trg_history_artifact_created;

DROP TRIGGER IF EXISTS trg_history_artifact_removed;

DROP TRIGGER IF EXISTS trg_history_context_revision;

CREATE TABLE conversation_history_entries_actor_alignment (
  id TEXT PRIMARY KEY DEFAULT ('history-' || lower(hex(randomblob(16)))),
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sequence INTEGER NOT NULL CHECK (typeof(sequence) = 'integer' AND sequence > 0),
  schema_version INTEGER NOT NULL DEFAULT 1 CHECK (schema_version = 1),
  kind TEXT NOT NULL CHECK (kind IN ('user_message', 'worker_response', 'workflow_event', 'execution_event', 'artifact_event', 'context_event')),
  event_type TEXT NOT NULL,
  actor_type TEXT NOT NULL CHECK (actor_type IN ('user', 'worker', 'syntila')),
  actor_id TEXT,
  work_request_id TEXT,
  turn_id TEXT,
  artifact_id TEXT,
  source_id TEXT NOT NULL,
  text TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metadata_json) AND json_type(metadata_json) = 'object'),
  deduplication_key TEXT,
  occurred_at TEXT NOT NULL,
  recorded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  UNIQUE (conversation_id, sequence),
  UNIQUE (conversation_id, deduplication_key),
  CHECK ((kind IN ('user_message', 'worker_response')) = (text IS NOT NULL)),
  CHECK (kind != 'worker_response' OR turn_id IS NOT NULL),
  CHECK (kind != 'artifact_event' OR artifact_id IS NOT NULL)
);

INSERT INTO conversation_history_entries_actor_alignment (id, conversation_id, sequence, schema_version, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at, recorded_at)
SELECT id, conversation_id, sequence, schema_version, kind, event_type, CASE actor_type WHEN 'conclave' THEN 'syntila' ELSE actor_type END, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at, recorded_at
FROM conversation_history_entries;

DROP TABLE conversation_history_entries;

ALTER TABLE conversation_history_entries_actor_alignment RENAME TO conversation_history_entries;

CREATE INDEX idx_conversation_history_request ON conversation_history_entries(work_request_id, sequence);

CREATE INDEX idx_conversation_history_turn ON conversation_history_entries(turn_id, kind);

CREATE TRIGGER trg_conversation_history_immutable
BEFORE UPDATE ON conversation_history_entries
BEGIN
  SELECT RAISE(ABORT, 'Canonical Conversation history is append-only');
END;

CREATE TRIGGER trg_conversation_history_no_delete
BEFORE DELETE ON conversation_history_entries
WHEN EXISTS (SELECT 1 FROM conversations WHERE id = OLD.conversation_id)
BEGIN
  SELECT RAISE(ABORT, 'Canonical Conversation history cannot be deleted independently');
END;

CREATE TRIGGER trg_history_user_message
AFTER INSERT ON conversation_user_messages
BEGIN
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
    json_object('userMessageId', NEW.id),
    'user:' || NEW.id,
    NEW.created_at
  ;
END;

CREATE TRIGGER trg_history_request_accepted
AFTER INSERT ON conversation_work_requests
BEGIN
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
    json_object('workflowId', wr.workflow_id, 'workflowVersion', wr.workflow_version, 'status', wr.status, 'conversationRevision', NEW.conversation_revision),
    NULL,
    wr.created_at
  FROM work_requests wr WHERE wr.id = NEW.work_request_id;
END;

CREATE TRIGGER trg_history_request_status
AFTER UPDATE OF status ON work_requests
WHEN OLD.status IS NOT NEW.status
BEGIN
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
    json_object('from', OLD.status, 'to', NEW.status, 'workflowId', NEW.workflow_id, 'workflowVersion', NEW.workflow_version),
    NULL,
    NEW.updated_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.id;
END;

CREATE TRIGGER trg_history_run_created
AFTER INSERT ON runs
BEGIN
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
    json_object('status', NEW.status),
    NULL,
    NEW.created_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
END;

CREATE TRIGGER trg_history_run_status
AFTER UPDATE OF status ON runs
WHEN OLD.status IS NOT NEW.status
BEGIN
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
    json_object('from', OLD.status, 'to', NEW.status),
    NULL,
    NEW.updated_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
END;

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

CREATE TRIGGER trg_history_execution_created
AFTER INSERT ON conversation_turns
BEGIN
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
    json_object('workerId', NEW.worker_id, 'workerTypeId', NEW.worker_type_id, 'workerDisplayName', NEW.worker_display_name, 'profileId', NEW.profile_id, 'profileVersion', NEW.profile_version, 'modelId', NEW.model_id, 'effort', NEW.effort, 'workflowId', NEW.workflow_id, 'workflowVersion', NEW.workflow_version, 'userMessageId', NEW.user_message_id, 'assignmentId', NEW.assignment_id, 'taskId', NEW.task_id, 'stepKind', NEW.step_kind, 'workerSessionId', NEW.worker_session_id, 'baseContextRevision', NEW.base_context_revision),
    NULL,
    NEW.created_at
  ;
END;

CREATE TRIGGER trg_history_execution_status
AFTER UPDATE OF status ON conversation_turns
WHEN OLD.status IS NOT NEW.status
BEGIN
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
    json_object('from', OLD.status, 'to', NEW.status, 'assignmentId', NEW.assignment_id, 'startedAt', NEW.started_at, 'completedAt', NEW.completed_at),
    NULL,
    COALESCE(NEW.completed_at, NEW.started_at, NEW.created_at)
  ;
END;

CREATE TRIGGER trg_history_worker_response
AFTER UPDATE OF status ON conversation_turns
WHEN OLD.status IS NOT NEW.status AND NEW.status = 'completed' AND NEW.result_text IS NOT NULL
BEGIN
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
    json_object('workerId', NEW.worker_id, 'workerTypeId', NEW.worker_type_id, 'workerDisplayName', NEW.worker_display_name, 'profileId', NEW.profile_id, 'profileVersion', NEW.profile_version, 'modelId', NEW.model_id, 'effort', NEW.effort, 'workflowId', NEW.workflow_id, 'workflowVersion', NEW.workflow_version, 'userMessageId', NEW.user_message_id, 'assignmentId', NEW.assignment_id, 'taskId', NEW.task_id, 'stepKind', NEW.step_kind, 'workerSessionId', NEW.worker_session_id, 'baseContextRevision', NEW.base_context_revision),
    'worker:' || NEW.id,
    NEW.completed_at
  ;
END;

CREATE TRIGGER trg_history_artifact_created
AFTER INSERT ON artifacts
BEGIN
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
    json_object('contentDigest', NEW.content_digest),
    NULL,
    NEW.created_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = COALESCE(NEW.work_request_id, (SELECT wt.work_request_id FROM workflow_tasks wt JOIN worker_assignments wa ON wa.task_id = wt.id WHERE wa.id = NEW.assignment_id), (SELECT work_request_id FROM runs WHERE id = NEW.run_id));
END;

CREATE TRIGGER trg_history_artifact_removed
AFTER DELETE ON artifacts
BEGIN
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
    json_object('contentDigest', OLD.content_digest),
    NULL,
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  FROM conversation_work_requests cr WHERE cr.work_request_id = COALESCE(OLD.work_request_id, (SELECT wt.work_request_id FROM workflow_tasks wt JOIN worker_assignments wa ON wa.task_id = wt.id WHERE wa.id = OLD.assignment_id), (SELECT work_request_id FROM runs WHERE id = OLD.run_id));
END;

CREATE TRIGGER trg_history_context_revision
AFTER UPDATE OF context_revision ON conversations
WHEN NEW.context_revision > OLD.context_revision
BEGIN
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
    json_object('previousRevision', OLD.context_revision, 'contextRevision', NEW.context_revision),
    NULL,
    NEW.updated_at
  ;
END;
