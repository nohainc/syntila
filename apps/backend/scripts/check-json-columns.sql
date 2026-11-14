-- Lists rows whose JSON-as-text columns do not hold valid JSON.
-- Run on production before validating the constraints of migration 0006:
--   sudo -u postgres psql -d syntila -f check-json-columns.sql
-- No output rows means every constraint can be validated.
DO $$
DECLARE c record; bad bigint;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS json_column_check (table_name text, column_name text, invalid_rows bigint);
  TRUNCATE json_column_check;
  FOR c IN
    SELECT rel.relname AS table_name, att.attname AS column_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
    WHERE con.contype = 'c' AND con.conname LIKE '%\_is\_json' AND con.connamespace = 'public'::regnamespace
  LOOP
    EXECUTE format('SELECT count(*) FROM %I WHERE %I IS NOT NULL AND NOT (%I IS JSON)', c.table_name, c.column_name, c.column_name) INTO bad;
    IF bad > 0 THEN INSERT INTO json_column_check VALUES (c.table_name, c.column_name, bad); END IF;
  END LOOP;
END $$;
SELECT * FROM json_column_check ORDER BY 1, 2;
