-- Data invariants that must hold however many writes run in parallel
-- (claude/concurrency-plan.md). One row per invariant; every `violations`
-- value must be 0. Run on production after a deploy or a load test:
--   sudo -u postgres psql -X -d syntila < check-invariants.sql
-- The concurrency tests run the same file after every scenario.

-- History of a Conversation is numbered 1..n without gaps or repeats.
SELECT 'conversation history numbered 1..n' AS invariant, count(*) AS violations
  FROM (SELECT conversation_id FROM conversation_history_entries
         GROUP BY conversation_id
        HAVING min(sequence) <> 1 OR max(sequence) <> count(*)) t
-- Every realtime stream counter is ahead of the events it numbered.
UNION ALL SELECT 'realtime cursor ahead of its events', count(*)
  FROM realtime_event_cursors c
 WHERE c.next_sequence <= COALESCE((SELECT max(e.sequence) FROM realtime_events e
                                     WHERE e.stream_kind = c.stream_kind
                                       AND COALESCE(e.stream_id, e.workspace_id) = c.stream_key), 0)
-- A Thread's request queue has one item per position.
UNION ALL SELECT 'request queue positions unique per Thread', count(*)
  FROM (SELECT 1 FROM thread_request_queue GROUP BY thread_id, position HAVING count(*) > 1) t
-- Every Space has exactly one owner membership, and it is the Space's owner.
UNION ALL SELECT 'Space has its owner as the one owner member', count(*)
  FROM spaces s
 WHERE (SELECT count(*) FROM space_memberships m WHERE m.space_id = s.id AND m.role = 'owner') <> 1
    OR NOT EXISTS (SELECT 1 FROM space_memberships m
                    WHERE m.space_id = s.id AND m.user_id = s.owner_user_id AND m.role = 'owner')
-- One active runtime lease per Thread, with tokens below the Thread's counter.
UNION ALL SELECT 'runtime lease token within the Thread counter', count(*)
  FROM thread_runtime_leases l JOIN threads t ON t.id = l.thread_id
 WHERE l.fencing_token > t.lease_fence_counter
-- Idempotency claims are released or completed; none stays pending for long.
UNION ALL SELECT 'no idempotency claim pending for over an hour', count(*)
  FROM mutation_receipts WHERE response_status = 0 AND created_at < now() - interval '1 hour'
-- Every durable event written since the outbox exists has its outbox row (ADR-033).
UNION ALL SELECT 'every event has one outbox row', count(*)
  FROM realtime_events e
 WHERE e.occurred_at > COALESCE((SELECT min(o.created_at) FROM outbox o), 'infinity'::timestamptz)
   AND NOT EXISTS (SELECT 1 FROM outbox o WHERE o.event_id = e.event_id)
-- A pending outbox row is delivered or retried within minutes; none waits for an hour.
UNION ALL SELECT 'no outbox row pending for over an hour', count(*)
  FROM outbox WHERE status = 'pending' AND created_at < now() - interval '1 hour'
-- A Worker command does not stay open after its assignment ended.
UNION ALL SELECT 'no open Worker command for an ended assignment', count(*)
  FROM agent_commands c JOIN worker_assignments a ON a.id = c.assignment_id
 WHERE c.status IN ('pending', 'sent')
   AND a.status IN ('completed', 'failed', 'cancelled', 'timed_out', 'lost')
-- A session is not open on a credential that was revoked (ADR-034).
UNION ALL SELECT 'no open Worker session on a revoked credential', count(*)
  FROM worker_agent_sessions s JOIN worker_credentials c ON c.id = s.credential_id
 WHERE s.disconnected_at IS NULL AND c.revoked_at IS NOT NULL
-- A removed Worker keeps no live credential or session.
UNION ALL SELECT 'no live credential or session on a removed Worker', count(*)
  FROM worker_instances w
 WHERE w.revoked_at IS NOT NULL
   AND (EXISTS (SELECT 1 FROM worker_credentials c WHERE c.worker_instance_id = w.id AND c.revoked_at IS NULL)
     OR EXISTS (SELECT 1 FROM worker_agent_sessions s WHERE s.worker_instance_id = w.id AND s.disconnected_at IS NULL))
-- A session lease that lapsed is closed by the sweep within minutes.
UNION ALL SELECT 'no Worker session past its lease for over an hour', count(*)
  FROM worker_agent_sessions WHERE disconnected_at IS NULL AND lease_expires_at < now() - interval '1 hour';
