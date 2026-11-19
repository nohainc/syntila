-- Read-only ADR-032 backfill audit. Run with psql -X -v ON_ERROR_STOP=1.
-- Investigate nonzero violations. This script never repairs data.
SELECT 'users without a human Actor' AS invariant, count(*) AS violations
  FROM users u LEFT JOIN actors a ON a.user_id = u.id AND a.kind = 'human'
 WHERE a.id IS NULL
UNION ALL SELECT 'Workers without their worker Actor', count(*)
  FROM worker_instances w LEFT JOIN actors a ON a.id = w.actor_id AND a.kind = 'worker'
 WHERE a.id IS NULL
UNION ALL SELECT 'inventory rows with unknown Worker Type', count(*)
  FROM workspace_worker_inventory i LEFT JOIN worker_catalog c ON c.worker_type_id = i.worker_type_id
 WHERE c.worker_type_id IS NULL
UNION ALL SELECT 'adoptable inventory rows without a matching Worker', count(*)
  FROM workspace_worker_inventory i JOIN worker_catalog c ON c.worker_type_id = i.worker_type_id
  LEFT JOIN legacy_worker_mapping m ON m.legacy_worker_id = i.worker_id
  LEFT JOIN worker_instances w ON w.id = m.worker_instance_id
 WHERE w.id IS NULL
    OR w.owner_user_id IS DISTINCT FROM i.owner_user_id
    OR w.worker_type_id IS DISTINCT FROM i.worker_type_id
UNION ALL SELECT 'live mapped Workers without an inventory row', count(*)
  FROM legacy_worker_mapping m JOIN worker_instances w ON w.id = m.worker_instance_id
  LEFT JOIN workspace_worker_inventory i ON i.worker_id = m.legacy_worker_id
 WHERE i.worker_id IS NULL AND w.revoked_at IS NULL;

SELECT (SELECT count(*) FROM users) AS users,
       (SELECT count(*) FROM actors WHERE kind = 'human' AND user_id IS NOT NULL) AS human_actors,
       (SELECT count(*) FROM workspace_worker_inventory) AS inventory_rows,
       (SELECT count(*) FROM legacy_worker_mapping) AS mappings,
       (SELECT count(*) FROM worker_instances WHERE revoked_at IS NULL) AS live_workers;
