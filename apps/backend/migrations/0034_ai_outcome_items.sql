-- ADR-036: a Work Request that fails or is cancelled also gets an answer item, so
-- the Thread timeline shows how the request ended. The item is authored by the
-- System Actor and carries a short fixed message (details stay on the steps).
-- The same id is used by a later successful retry: record_ai_answer replaces the
-- outcome item, and record_ai_outcome_clear removes it when a retry is queued.

CREATE FUNCTION record_ai_outcome(p_work_request_id text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO discussion_messages
    (id, thread_id, author_user_id, author_actor_id, author_display_snapshot, worker_display_name,
     body, created_at, kind, work_request_id, event_type)
  SELECT 'ai-answer-' || wr.id, wr.thread_id, wr.requested_by_user_id, 'actor-system-platform',
         wr.workflow_id, wr.workflow_id,
         CASE wr.status WHEN 'cancelled' THEN 'This request was cancelled.' ELSE 'This request did not finish.' END,
         wr.updated_at, 'ai_answer', wr.id, 'work_' || wr.status
    FROM work_requests wr
   WHERE wr.id = p_work_request_id AND wr.status IN ('failed', 'cancelled') AND wr.thread_id IS NOT NULL
  ON CONFLICT (work_request_id) WHERE kind = 'ai_answer' AND work_request_id IS NOT NULL
  DO UPDATE SET body = EXCLUDED.body, event_type = EXCLUDED.event_type, created_at = EXCLUDED.created_at
    WHERE discussion_messages.event_type IN ('work_failed', 'work_cancelled');
END $$;

CREATE FUNCTION record_ai_outcome_clear(p_work_request_id text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM discussion_messages
   WHERE work_request_id = p_work_request_id AND kind = 'ai_answer'
     AND event_type IN ('work_failed', 'work_cancelled');
END $$;

CREATE OR REPLACE FUNCTION record_ai_answer(p_work_request_id text) RETURNS void LANGUAGE plpgsql AS $$
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
BEGIN
  SELECT id, thread_id, requested_by_user_id, workflow_id, updated_at INTO wr
    FROM work_requests WHERE id = p_work_request_id AND status = 'completed' AND thread_id IS NOT NULL;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT count(*) INTO terminal_count FROM workflow_tasks wt
   WHERE wt.work_request_id = wr.id
     AND NOT EXISTS (SELECT 1 FROM workflow_task_dependencies d WHERE d.depends_on_task_id = wt.id);

  SELECT ct.id, ct.worker_id, ct.worker_display_name, ct.completed_at, h.text AS text INTO turn
    FROM conversation_turns ct
    JOIN conversation_history_entries h ON h.turn_id = ct.id AND h.kind = 'worker_response'
   WHERE ct.work_request_id = wr.id AND ct.status = 'completed'
     AND (terminal_count <> 1 OR NOT EXISTS (
            SELECT 1 FROM workflow_task_dependencies d WHERE d.depends_on_task_id = ct.task_id))
   ORDER BY ct.seq DESC LIMIT 1;
  IF NOT FOUND THEN RETURN; END IF;
  answer_text := turn.text;

  IF terminal_count = 1 THEN
    SELECT w.id, w.actor_id, w.name INTO inst_id, inst_actor, inst_name FROM worker_instances w
     WHERE w.id = turn.worker_id
        OR w.id = (SELECT m.worker_instance_id FROM legacy_worker_mapping m WHERE m.legacy_worker_id = turn.worker_id)
     ORDER BY (w.id = turn.worker_id) DESC LIMIT 1;
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
END $$;
