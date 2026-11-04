-- D1 rejects LIKE/GLOB patterns longer than 50 bytes ("LIKE or GLOB pattern
-- too complex"), so the 0101 trigger's 67-byte GLOB failed every plugin
-- registration on D1 (plain SQLite has no such limit). Same invariant, short
-- patterns: `plugin-` followed by exactly 12 lowercase hex digits.
DROP TRIGGER worker_catalog_origin_invariants_insert;

CREATE TRIGGER worker_catalog_origin_invariants_insert
BEFORE INSERT ON worker_catalog
WHEN (NEW.origin = 'plugin') <> (NEW.owner_user_id IS NOT NULL)
  OR (NEW.origin = 'official' AND NEW.worker_type_id LIKE 'plugin-%')
  OR (NEW.origin = 'plugin'
      AND NOT (length(NEW.worker_type_id) = 19
        AND substr(NEW.worker_type_id, 1, 7) = 'plugin-'
        AND substr(NEW.worker_type_id, 8) NOT GLOB '*[^0-9a-f]*'))
BEGIN
  SELECT RAISE(ABORT, 'invalid worker_catalog origin');
END;
