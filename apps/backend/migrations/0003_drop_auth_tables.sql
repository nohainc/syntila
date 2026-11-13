-- Accounts, sessions, desktop sign-in and step-up live in the Cloudflare auth
-- Worker's D1 database. The backend authenticates with short-lived tokens and
-- keeps only `users` (synced from tokens) and `auth_audit_events` (its own
-- authorization denials).
DROP TABLE IF EXISTS auth_step_up_sessions;
DROP TABLE IF EXISTS auth_step_up_events;
DROP TABLE IF EXISTS desktop_human_sessions;
DROP TABLE IF EXISTS desktop_auth_intents;
DROP TABLE IF EXISTS passkeys;
DROP TABLE IF EXISTS auth_verifications;
DROP TABLE IF EXISTS auth_accounts;
DROP TABLE IF EXISTS auth_sessions;
