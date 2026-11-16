-- A person never owns two group Spaces with the same name (compared
-- case-insensitively, ignoring surrounding spaces). Create is serialized per
-- owner, but rename was not, so a create racing a rename, or two renames,
-- could both pass the SELECT check. The index makes the rule hold under any
-- concurrency; the router answers a violation with 409 "You already have a
-- Space with this name". Direct Spaces are named after the other person and
-- are not covered.
--
-- Existing duplicates are renamed first: the oldest keeps its name, later
-- ones become "name (2)", "name (3)"… (repeated if that collides again).
DO $$
BEGIN
  FOR i IN 1..5 LOOP
    UPDATE spaces s
       SET name = s.name || ' (' || d.rn || ')', updated_at = now()
      FROM (SELECT id, row_number() OVER (PARTITION BY owner_user_id, lower(btrim(name)) ORDER BY created_at, id) AS rn
              FROM spaces WHERE kind = 'group') d
     WHERE d.id = s.id AND d.rn > 1;
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM spaces WHERE kind = 'group'
       GROUP BY owner_user_id, lower(btrim(name)) HAVING count(*) > 1);
  END LOOP;
END $$;

CREATE UNIQUE INDEX spaces_owner_group_name_key
  ON spaces (owner_user_id, lower(btrim(name))) WHERE kind = 'group';
