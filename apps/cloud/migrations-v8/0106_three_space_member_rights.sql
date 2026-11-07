-- Space members hold exactly three stored rights: chat, work and
-- manageOwnThreads. `useOwnWorkers` is derived from chat at read time, so the
-- legacy persisted key is removed. Unrelated settings are preserved; absent or
-- non-object snapshots are left untouched; entries that are not objects are
-- preserved as-is (readers fail closed on them).
UPDATE spaces
SET settings_json = json_set(
  settings_json,
  '$.memberPermissions',
  COALESCE((
    SELECT json_group_object(key, json_remove(json(
      CASE type
        WHEN 'text' THEN json_quote(value)
        WHEN 'true' THEN 'true'
        WHEN 'false' THEN 'false'
        WHEN 'null' THEN 'null'
        ELSE value
      END), '$.useOwnWorkers'))
    FROM json_each(json_extract(spaces.settings_json, '$.memberPermissions'))
  ), json('{}'))
)
WHERE json_valid(settings_json)
  AND json_type(settings_json, '$.memberPermissions') = 'object';

UPDATE spaces
SET settings_json = json_set(
  settings_json,
  '$.invitationPermissions',
  COALESCE((
    SELECT json_group_object(key, json_remove(json(
      CASE type
        WHEN 'text' THEN json_quote(value)
        WHEN 'true' THEN 'true'
        WHEN 'false' THEN 'false'
        WHEN 'null' THEN 'null'
        ELSE value
      END), '$.useOwnWorkers'))
    FROM json_each(json_extract(spaces.settings_json, '$.invitationPermissions'))
  ), json('{}'))
)
WHERE json_valid(settings_json)
  AND json_type(settings_json, '$.invitationPermissions') = 'object';
