-- Concurrency plan, Phase 2 (claude/concurrency-plan.md).
--
-- 1. History numbering without a global lock. Each Conversation numbers its
--    own history with a counter on its row: taking the next number locks
--    only that Conversation, so writes to different Conversations no longer
--    wait for each other. Replaces the database-wide advisory lock
--    ('syntila.conversation_history') and MAX(sequence) + 1 in the eleven
--    history triggers. Numbers stay gapless: the counter rolls back with
--    the transaction that took it.
-- 2. One request-queue item per position in a Thread. Existing duplicates
--    (from parallel enqueues) are spread apart first, in their queue order.
-- 3. One live (active or suspended) grant per Space and Workspace. Older
--    duplicates from parallel grants are revoked first; the newest stays.

ALTER TABLE conversations
  ADD COLUMN history_sequence bigint NOT NULL DEFAULT 0 CHECK (history_sequence >= 0);

UPDATE conversations c
   SET history_sequence = h.top
  FROM (SELECT conversation_id, max(sequence) AS top
          FROM conversation_history_entries GROUP BY conversation_id) h
 WHERE h.conversation_id = c.id;

-- The next history number of a Conversation; NULL (and so a NOT NULL error
-- on insert) for a Conversation that does not exist. The row lock taken by
-- the UPDATE is what orders writers of one Conversation. The counter also
-- moves past any entry written with an explicit number (tools, fixtures),
-- so it can never hand out a number that is taken.
CREATE FUNCTION syntila_next_history_sequence(conversation text) RETURNS bigint
LANGUAGE sql VOLATILE AS $$
  UPDATE conversations c
     SET history_sequence = GREATEST(c.history_sequence,
           COALESCE((SELECT max(h.sequence) FROM conversation_history_entries h
                      WHERE h.conversation_id = c.id), 0)) + 1
   WHERE c.id = conversation
  RETURNING c.history_sequence
$$;

CREATE OR REPLACE FUNCTION public.trg_history_context_revision_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.context_revision > OLD.context_revision THEN
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.id,
    syntila_next_history_sequence(NEW.id),
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
END $function$;

CREATE OR REPLACE FUNCTION public.trg_history_execution_created_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    syntila_next_history_sequence(NEW.conversation_id),
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
END $function$;

CREATE OR REPLACE FUNCTION public.trg_history_execution_status_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    syntila_next_history_sequence(NEW.conversation_id),
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
END $function$;

CREATE OR REPLACE FUNCTION public.trg_history_request_accepted_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    syntila_next_history_sequence(NEW.conversation_id),
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
END $function$;

CREATE OR REPLACE FUNCTION public.trg_history_request_status_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    syntila_next_history_sequence(cr.conversation_id),
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
END $function$;

CREATE OR REPLACE FUNCTION public.trg_history_run_created_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    syntila_next_history_sequence(cr.conversation_id),
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
END $function$;

CREATE OR REPLACE FUNCTION public.trg_history_run_status_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    syntila_next_history_sequence(cr.conversation_id),
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
END $function$;

CREATE OR REPLACE FUNCTION public.trg_history_step_created_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    syntila_next_history_sequence(cr.conversation_id),
    'workflow_event', 'workflow.step_created', 'syntila', NULL,
    NEW.work_request_id, NULL, NULL, NEW.id, NULL,
    jsonb_build_object('status', NEW.status, 'stepKind', NEW.step_kind, 'stepId', NEW.step_id, 'attempt', NEW.attempt),
    NULL, NEW.created_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.trg_history_step_status_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    syntila_next_history_sequence(cr.conversation_id),
    'workflow_event', 'workflow.step_status_changed', 'syntila', NULL,
    NEW.work_request_id, NULL, NULL, NEW.id, NULL,
    jsonb_build_object('from', OLD.status, 'to', NEW.status, 'stepKind', NEW.step_kind, 'stepId', NEW.step_id, 'attempt', NEW.attempt),
    NULL, NEW.updated_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.trg_history_user_message_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    syntila_next_history_sequence(NEW.conversation_id),
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
END $function$;

CREATE OR REPLACE FUNCTION public.trg_history_worker_response_fn()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'completed' AND NEW.result_text IS NOT NULL THEN
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    syntila_next_history_sequence(NEW.conversation_id),
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
END $function$;

WITH ranked AS (
  SELECT id, row_number() OVER (PARTITION BY thread_id, position ORDER BY created_at, id) - 1 AS k
    FROM thread_request_queue
)
UPDATE thread_request_queue q
   SET position = q.position + ranked.k * 0.000001
  FROM ranked
 WHERE ranked.id = q.id AND ranked.k > 0;

CREATE UNIQUE INDEX thread_request_queue_thread_position_key
  ON thread_request_queue (thread_id, position);
DROP INDEX idx_thread_request_queue_thread;

UPDATE workspace_space_grants g
   SET status = 'revoked', updated_at = now()
 WHERE g.status IN ('active', 'suspended')
   AND EXISTS (SELECT 1 FROM workspace_space_grants n
                WHERE n.space_id = g.space_id AND n.workspace_id = g.workspace_id
                  AND n.status IN ('active', 'suspended')
                  AND (n.created_at, n.id) > (g.created_at, g.id));

CREATE UNIQUE INDEX workspace_space_grants_one_live
  ON workspace_space_grants (space_id, workspace_id) WHERE status IN ('active', 'suspended');
