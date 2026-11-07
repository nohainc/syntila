-- Support Spaces are hidden in the owner's sidebar until the user shows them.
-- Backfill Spaces provisioned before default-hidden that the user never opened.
UPDATE direct_space_user_state
SET hidden = 1
WHERE last_opened_at IS NULL
  AND EXISTS (
    SELECT 1 FROM support_spaces ss
    WHERE ss.space_id = direct_space_user_state.space_id
      AND ss.user_id = direct_space_user_state.user_id
  );
