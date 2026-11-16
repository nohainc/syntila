-- A Space never has two Threads with the same name (compared case-insensitively,
-- ignoring surrounding spaces): the create and rename handlers checked this
-- with a SELECT before writing, which two parallel requests both passed.
-- The index makes the rule hold under any concurrency; the handlers answer a
-- violation with 409 "This Space already has a Thread with this name".
--
-- Existing duplicates (possible while the rule was only a check) are renamed
-- first: the oldest keeps its name, later ones become "name (2)", "name (3)"…
-- A renamed Thread that collides with an existing "name (2)" is renamed again.
DO $$
BEGIN
  FOR i IN 1..5 LOOP
    UPDATE threads t
       SET name = t.name || ' (' || d.rn || ')', updated_at = now()
      FROM (SELECT id, row_number() OVER (PARTITION BY space_id, lower(btrim(name)) ORDER BY created_at, id) AS rn
              FROM threads) d
     WHERE d.id = t.id AND d.rn > 1;
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM threads GROUP BY space_id, lower(btrim(name)) HAVING count(*) > 1);
  END LOOP;
END $$;

CREATE UNIQUE INDEX threads_space_name_key ON threads (space_id, lower(btrim(name)));
