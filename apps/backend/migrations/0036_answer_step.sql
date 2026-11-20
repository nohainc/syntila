-- ADR-036: a Workflow declares which step is its answer (derived from the step's
-- result semantics by declaredAnswerStepId in @syntila/core and stored when the
-- tasks are created). record_ai_answer then uses that step even when the
-- Workflow has several terminal steps.
ALTER TABLE workflow_tasks ADD COLUMN answer_step boolean NOT NULL DEFAULT false;

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
