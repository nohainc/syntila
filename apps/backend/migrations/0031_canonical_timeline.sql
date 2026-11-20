-- Canonical Thread timeline and attribution (ADR-036, phase P7). Expand only.
--
-- discussion_messages is extended in place; no new table. Every row names the
-- Actor that authored it, the Worker Instance when one did, and the display
-- name as it was at the time (a removed or tombstoned Worker still shows).
--
-- The `ai_request` and `ai_answer` rows are written only when the
-- `canonical_timeline` flag is on (record_ai_request / record_ai_answer, called
-- by the transactions that create and finish a Work Request) and are always
-- idempotent: one of each per Work Request, enforced by partial unique indexes.

ALTER TABLE discussion_messages ADD COLUMN author_actor_id text REFERENCES actors(id) ON DELETE RESTRICT;
ALTER TABLE discussion_messages ADD COLUMN worker_instance_id text REFERENCES worker_instances(id) ON DELETE SET NULL;
ALTER TABLE discussion_messages ADD COLUMN author_display_snapshot text;
ALTER TABLE discussion_messages ADD COLUMN client_mutation_id text;

CREATE INDEX discussion_messages_author_actor_idx ON discussion_messages (author_actor_id);
CREATE INDEX discussion_messages_worker_instance_idx ON discussion_messages (worker_instance_id);

-- Humans: the Actor of the author and the name they had when they wrote.
UPDATE discussion_messages m
   SET author_actor_id = a.id,
       author_display_snapshot = COALESCE(m.author_display_snapshot, u.display_name)
  FROM actors a, users u
 WHERE a.user_id = m.author_user_id AND u.id = m.author_user_id
   AND m.author_actor_id IS NULL AND m.kind = 'message';
UPDATE discussion_messages SET author_display_snapshot = COALESCE(worker_display_name, 'AI')
 WHERE kind = 'ai_answer' AND author_display_snapshot IS NULL;

-- New human messages get the same without any change to the writers.
CREATE FUNCTION trg_discussion_message_author_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.kind = 'message' AND NEW.author_actor_id IS NULL THEN
    SELECT a.id INTO NEW.author_actor_id FROM actors a WHERE a.user_id = NEW.author_user_id;
  END IF;
  IF NEW.kind = 'message' AND NEW.author_display_snapshot IS NULL THEN
    SELECT u.display_name INTO NEW.author_display_snapshot FROM users u WHERE u.id = NEW.author_user_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_discussion_message_author BEFORE INSERT ON discussion_messages
  FOR EACH ROW EXECUTE FUNCTION trg_discussion_message_author_fn();

-- One request and one answer per Work Request; one human send per mutation.
CREATE UNIQUE INDEX discussion_messages_one_ai_request_idx ON discussion_messages (work_request_id)
  WHERE kind = 'ai_request' AND work_request_id IS NOT NULL;
CREATE UNIQUE INDEX discussion_messages_one_ai_answer_idx ON discussion_messages (work_request_id)
  WHERE kind = 'ai_answer' AND work_request_id IS NOT NULL;
CREATE UNIQUE INDEX discussion_messages_client_mutation_idx ON discussion_messages (author_actor_id, client_mutation_id)
  WHERE client_mutation_id IS NOT NULL;

-- The request item. Inserted with the Work Request's own transaction.
CREATE FUNCTION record_ai_request(p_work_request_id text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO discussion_messages
    (id, thread_id, author_user_id, author_actor_id, author_display_snapshot, body, created_at, kind, work_request_id)
  SELECT 'ai-request-' || wr.id, wr.thread_id, m.author_user_id,
         (SELECT a.id FROM actors a WHERE a.user_id = m.author_user_id),
         (SELECT u.display_name FROM users u WHERE u.id = m.author_user_id),
         m.text, m.created_at, 'ai_request', wr.id
    FROM work_requests wr
    JOIN conversation_user_messages m ON m.work_request_id = wr.id
   WHERE wr.id = p_work_request_id AND wr.thread_id IS NOT NULL
  ON CONFLICT DO NOTHING;
END $$;

-- The answer item, written when the Work Request completes. The terminal step
-- is the only step no other step depends on; its Worker is the author. With no
-- single terminal step that produced text, the answer is authored by the
-- platform System Actor, labelled with the Workflow. Intermediate step output
-- is not a timeline item.
CREATE FUNCTION record_ai_answer(p_work_request_id text) RETURNS void LANGUAGE plpgsql AS $$
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
  ON CONFLICT DO NOTHING;
END $$;

-- Historical Work: ask for a Thread's missing items. Idempotent.
CREATE FUNCTION backfill_ai_timeline(p_thread_id text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id, status FROM work_requests WHERE thread_id = p_thread_id ORDER BY created_at, id LOOP
    PERFORM record_ai_request(r.id);
    IF r.status = 'completed' THEN PERFORM record_ai_answer(r.id); END IF;
  END LOOP;
END $$;
