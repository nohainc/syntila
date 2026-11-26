-- Read-only Worker identity audit. Run with psql -X -v ON_ERROR_STOP=1.
-- Investigate nonzero violations. This script never repairs data.
SELECT 'users without a human Actor' AS invariant, count(*) AS violations
  FROM users u LEFT JOIN actors a ON a.user_id = u.id AND a.kind = 'human'
 WHERE a.id IS NULL
UNION ALL SELECT 'Workers without their Worker Actor', count(*)
  FROM worker_instances w LEFT JOIN actors a ON a.id = w.actor_id AND a.kind = 'worker'
 WHERE a.id IS NULL;

SELECT (SELECT count(*) FROM users) AS users,
       (SELECT count(*) FROM actors WHERE kind = 'human' AND user_id IS NOT NULL) AS human_actors,
       (SELECT count(*) FROM worker_instances WHERE revoked_at IS NULL) AS live_workers;
