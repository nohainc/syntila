-- A person with active access to a Workspace has no pending invitation to it.
-- Inviting checked the grants table with a SELECT, but accepting an invitation
-- moves it out of "pending" and creates the grant in one batch, so an invite
-- sent at that moment could pass both checks and leave a pending invitation
-- beside the new grant. The rule spans two tables, so no index can hold it.
-- Instead both tables take the same transaction lock, keyed by Workspace and
-- e-mail, in a trigger and then look at the other table:
--   * a pending invitation refuses to be created or revived while the person
--     has an active grant (23505, constraint workspace_invitations_no_active_grant);
--   * a grant that becomes active expires the person's redundant pending
--     invitation (history stays, status 'expired') instead of failing.
-- The lock is released at commit, so the second writer always sees the first.
--
-- Existing overlaps: access wins. Pending invitations of people who already
-- hold an active grant are expired, never deleted.
UPDATE workspace_invitations i
   SET status = 'expired', updated_at = now()
 WHERE i.status = 'pending'
   AND EXISTS (SELECT 1 FROM workspace_person_grants g JOIN users u ON u.id = g.user_id
                WHERE g.workspace_id = i.workspace_id AND g.status = 'active'
                  AND lower(u.email) = lower(i.email));

CREATE FUNCTION workspace_invitations_no_active_grant_fn() RETURNS trigger AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('syntila.workspace_access:' || NEW.workspace_id || ':' || lower(NEW.email), 0));
  IF EXISTS (SELECT 1 FROM workspace_person_grants g JOIN users u ON u.id = g.user_id
              WHERE g.workspace_id = NEW.workspace_id AND g.status = 'active'
                AND lower(u.email) = lower(NEW.email)) THEN
    RAISE EXCEPTION 'This person already has access' USING ERRCODE = '23505', CONSTRAINT = 'workspace_invitations_no_active_grant';
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER workspace_invitations_no_active_grant
  BEFORE INSERT OR UPDATE OF status, email ON workspace_invitations
  FOR EACH ROW WHEN (NEW.status = 'pending')
  EXECUTE FUNCTION workspace_invitations_no_active_grant_fn();

CREATE FUNCTION workspace_person_grants_expire_invitations_fn() RETURNS trigger AS $$
DECLARE person_email text;
BEGIN
  SELECT lower(email) INTO person_email FROM users WHERE id = NEW.user_id;
  PERFORM pg_advisory_xact_lock(hashtextextended('syntila.workspace_access:' || NEW.workspace_id || ':' || person_email, 0));
  UPDATE workspace_invitations
     SET status = 'expired', updated_at = now()
   WHERE workspace_id = NEW.workspace_id AND status = 'pending' AND lower(email) = person_email;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER workspace_person_grants_expire_invitations
  BEFORE INSERT OR UPDATE OF status ON workspace_person_grants
  FOR EACH ROW WHEN (NEW.status = 'active')
  EXECUTE FUNCTION workspace_person_grants_expire_invitations_fn();
