-- ADR-033 (P2): durable streams for threads, Worker inboxes and assignments,
-- a transactional outbox, and the Worker command inbox.
-- Additive: no data moves; the legacy `execution_workspace` stream kind stays.

/* ------------------------------------------------------------ stream kinds */

-- Widened with NOT VALID + VALIDATE so the large events table is not held
-- under an exclusive lock while it is scanned.
ALTER TABLE realtime_event_cursors DROP CONSTRAINT realtime_event_cursors_stream_kind_check;
ALTER TABLE realtime_event_cursors ADD CONSTRAINT realtime_event_cursors_stream_kind_check
  CHECK (stream_kind IN ('execution_workspace', 'space', 'user', 'thread', 'worker_inbox', 'assignment')) NOT VALID;
ALTER TABLE realtime_event_cursors VALIDATE CONSTRAINT realtime_event_cursors_stream_kind_check;

ALTER TABLE realtime_events DROP CONSTRAINT realtime_events_stream_kind_check;
ALTER TABLE realtime_events ADD CONSTRAINT realtime_events_stream_kind_check
  CHECK (stream_kind IN ('execution_workspace', 'space', 'user', 'thread', 'worker_inbox', 'assignment')) NOT VALID;
ALTER TABLE realtime_events VALIDATE CONSTRAINT realtime_events_stream_kind_check;

-- The outbox sweep reads a recent time window across all streams.
CREATE INDEX realtime_events_occurred_idx ON realtime_events (occurred_at);

/* ------------------------------------------------------------------ outbox */

-- One row per durable event, written in the same transaction as the event.
-- Delivery to sockets is an optimization on top of it: the committing process
-- delivers inline right after commit; anything it did not finish (crash,
-- failure, no gateway) is picked up later by the dispatcher.
-- `next_attempt_at` starts 10 s in the future so the inline path wins; it is
-- also the claim lease while a delivery is in flight.
CREATE TABLE outbox (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_id        text NOT NULL REFERENCES realtime_events(event_id) ON DELETE CASCADE,
  -- Trusted audience captured at commit time (see DomainEventInput); NULL means
  -- "resolve the audience when delivering".
  audience_json   jsonb,
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'delivered', 'dead')),
  attempts        integer NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now() + interval '10 seconds',
  last_error      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  delivered_at    timestamptz,
  CHECK ((status = 'delivered') = (delivered_at IS NOT NULL))
);
-- Exactly one outbox row per event (and the foreign-key index).
CREATE UNIQUE INDEX outbox_event_uq ON outbox (event_id);
CREATE INDEX outbox_due_idx ON outbox (next_attempt_at) WHERE status = 'pending';

/* ---------------------------------------------------------- command inbox */

-- A command addressed to one Worker. The row exists before any wakeup is sent;
-- notifications carry IDs only, and the payload stays where it already lives
-- (`payload_ref`, today `worker_assignments:<assignment id>`).
-- `worker_instance_id` stays nullable until Agents address Workers by Instance
-- (P3); Workspace-routed commands fill it from the P1 mapping when they can.
CREATE TABLE agent_commands (
  command_id         text PRIMARY KEY,
  worker_instance_id text REFERENCES worker_instances(id) ON DELETE RESTRICT,
  assignment_id      text NOT NULL REFERENCES worker_assignments(id) ON DELETE CASCADE,
  attempt_id         text,
  type               text NOT NULL CHECK (type IN ('assignment.dispatch', 'assignment.cancel', 'assignment.revoke')),
  payload_ref        text NOT NULL,
  status             text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'sent', 'acked', 'cancelled', 'expired', 'failed')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  sent_at            timestamptz,
  acked_at           timestamptz,
  expires_at         timestamptz NOT NULL,
  CHECK (expires_at > created_at)
);
-- One command of each type per assignment: makes creation idempotent, and its
-- leading column serves the assignment foreign key.
CREATE UNIQUE INDEX agent_commands_assignment_type_uq ON agent_commands (assignment_id, type);
CREATE INDEX agent_commands_worker_idx ON agent_commands (worker_instance_id);
CREATE INDEX agent_commands_open_idx ON agent_commands (expires_at) WHERE status IN ('pending', 'sent');

-- The command follows its assignment, whichever code path moves it:
--   dispatched -> sent; acknowledged/running/completed -> acked;
--   cancelled -> cancelled; failed -> failed; timed_out/lost -> expired.
-- Moves are forward only: acked and the closed states never change.
CREATE FUNCTION agent_commands_follow_assignment_fn() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  next_status text;
BEGIN
  next_status := CASE NEW.status
    WHEN 'dispatched' THEN 'sent'
    WHEN 'acknowledged' THEN 'acked'
    WHEN 'running' THEN 'acked'
    WHEN 'completed' THEN 'acked'
    WHEN 'cancelled' THEN 'cancelled'
    WHEN 'failed' THEN 'failed'
    WHEN 'timed_out' THEN 'expired'
    WHEN 'lost' THEN 'expired'
    ELSE NULL END;
  IF next_status IS NULL THEN RETURN NEW; END IF;
  UPDATE agent_commands
     SET status = next_status,
         updated_at = now(),
         sent_at = CASE WHEN next_status = 'sent' THEN COALESCE(sent_at, now()) ELSE sent_at END,
         acked_at = CASE WHEN next_status = 'acked' THEN COALESCE(acked_at, now()) ELSE acked_at END
   WHERE assignment_id = NEW.id
     AND status = ANY (CASE next_status WHEN 'sent' THEN ARRAY['pending'] ELSE ARRAY['pending', 'sent'] END);
  RETURN NEW;
END $$;
CREATE TRIGGER worker_assignments_command_follow AFTER UPDATE OF status ON worker_assignments
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION agent_commands_follow_assignment_fn();
