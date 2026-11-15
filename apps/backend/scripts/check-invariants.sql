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
-- One live grant per Space and Workspace.
UNION ALL SELECT 'one live grant per Space and Workspace', count(*)
  FROM (SELECT 1 FROM workspace_space_grants WHERE status IN ('active', 'suspended')
         GROUP BY space_id, workspace_id HAVING count(*) > 1) t
-- Idempotency claims are released or completed; none stays pending for long.
UNION ALL SELECT 'no idempotency claim pending for over an hour', count(*)
  FROM mutation_receipts WHERE response_status = 0 AND created_at < now() - interval '1 hour';
