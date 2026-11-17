-- An uploaded file belongs to its owner, not to the Thread or Space it was
-- uploaded in: when that Thread or Space is deleted the file stays and only
-- loses the link (the file list already shows it unlinked). A plan approval
-- stays after its approver's account is deleted; the approver is then unknown.
-- Rows that already point at something that no longer exists are detached
-- first (nothing is deleted).
--
-- user_notes.thread_id / space_id deliberately get NO foreign key: a note whose
-- Thread is gone keeps the old ids and shows its saved Space and Thread titles
-- (linked_title, linked_space_title), which a NULL link would lose.
UPDATE user_files SET thread_id = NULL WHERE thread_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM threads t WHERE t.id = user_files.thread_id);
UPDATE user_files SET space_id = NULL WHERE space_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM spaces s WHERE s.id = user_files.space_id);

ALTER TABLE plan_approvals ALTER COLUMN approved_by_user_id DROP NOT NULL;
UPDATE plan_approvals SET approved_by_user_id = NULL WHERE approved_by_user_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = plan_approvals.approved_by_user_id);

ALTER TABLE user_files ADD CONSTRAINT user_files_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE SET NULL NOT VALID;
ALTER TABLE user_files ADD CONSTRAINT user_files_space_id_fkey FOREIGN KEY (space_id) REFERENCES spaces(id) ON DELETE SET NULL NOT VALID;
ALTER TABLE plan_approvals ADD CONSTRAINT plan_approvals_approved_by_user_id_fkey FOREIGN KEY (approved_by_user_id) REFERENCES users(id) ON DELETE SET NULL NOT VALID;

-- VALIDATE only reads; it does not block reads or writes.
ALTER TABLE user_files VALIDATE CONSTRAINT user_files_thread_id_fkey;
ALTER TABLE user_files VALIDATE CONSTRAINT user_files_space_id_fkey;
ALTER TABLE plan_approvals VALIDATE CONSTRAINT plan_approvals_approved_by_user_id_fkey;
