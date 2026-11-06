-- Phase 1: Direct Spaces and Personal Connections

-- 1.1 Space kind discriminator
ALTER TABLE spaces ADD COLUMN kind TEXT NOT NULL DEFAULT 'group' CHECK (kind IN ('group', 'direct'));

-- 1.2 Direct Space identity
CREATE TABLE direct_spaces (
  space_id TEXT PRIMARY KEY REFERENCES spaces(id) ON DELETE CASCADE,
  user_low_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_high_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  general_thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE RESTRICT,
  created_at TEXT NOT NULL,
  CHECK (user_low_id < user_high_id),
  UNIQUE (user_low_id, user_high_id)
);

CREATE INDEX idx_direct_spaces_high ON direct_spaces(user_high_id, user_low_id);

-- Enforce that general_thread_id belongs to the same Direct Space
CREATE TRIGGER validate_direct_space_general_thread
BEFORE INSERT ON direct_spaces
BEGIN
  SELECT CASE
    WHEN NOT EXISTS (
      SELECT 1 FROM threads t WHERE t.id = NEW.general_thread_id AND t.space_id = NEW.space_id
    ) THEN RAISE(ABORT, 'general_thread_id must belong to the same Direct Space')
  END;
END;

CREATE TRIGGER validate_direct_space_general_thread_update
BEFORE UPDATE OF general_thread_id, space_id ON direct_spaces
BEGIN
  SELECT CASE
    WHEN NOT EXISTS (
      SELECT 1 FROM threads t WHERE t.id = NEW.general_thread_id AND t.space_id = NEW.space_id
    ) THEN RAISE(ABORT, 'general_thread_id must belong to the same Direct Space')
  END;
END;

-- 1.3 Personal invitation storage
CREATE TABLE person_invitations (
  id TEXT PRIMARY KEY,
  inviter_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  invitee_user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
  email TEXT,
  status TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled', 'expired')),
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  accepted_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL,
  CHECK (invitee_user_id IS NOT NULL OR email IS NOT NULL),
  CHECK (invitee_user_id IS NULL OR inviter_user_id <> invitee_user_id)
);

-- Duplicate pending invitation prevention between known users in either direction:
CREATE UNIQUE INDEX idx_person_invitations_pending_pair
  ON person_invitations (MIN(inviter_user_id, invitee_user_id), MAX(inviter_user_id, invitee_user_id))
  WHERE status = 'pending' AND invitee_user_id IS NOT NULL;

-- Duplicate pending invitation prevention for email-addressed invitations:
CREATE UNIQUE INDEX idx_person_invitations_pending_email
  ON person_invitations (inviter_user_id, LOWER(email))
  WHERE status = 'pending' AND email IS NOT NULL;

CREATE INDEX idx_person_invitations_invitee ON person_invitations(invitee_user_id, status);
CREATE INDEX idx_person_invitations_inviter ON person_invitations(inviter_user_id, status);

-- 1.4 Approved connection storage
CREATE TABLE person_connections (
  user_low_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_high_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (status IN ('connected', 'disconnected')),
  established_at TEXT NOT NULL,
  disconnected_at TEXT,
  direct_space_id TEXT REFERENCES spaces(id) ON DELETE SET NULL,
  PRIMARY KEY (user_low_id, user_high_id),
  CHECK (user_low_id < user_high_id)
);

CREATE INDEX idx_person_connections_high ON person_connections(user_high_id, user_low_id);
CREATE INDEX idx_person_connections_space ON person_connections(direct_space_id);

-- 1.5 Per-user Direct Space state
CREATE TABLE direct_space_user_state (
  space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  hidden INTEGER NOT NULL DEFAULT 0 CHECK (hidden IN (0, 1)),
  last_opened_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (space_id, user_id)
);

CREATE INDEX idx_direct_space_user_state_user ON direct_space_user_state(user_id);

-- 1.6 Default General Thread marker
ALTER TABLE threads ADD COLUMN is_general INTEGER NOT NULL DEFAULT 0 CHECK (is_general IN (0, 1));

-- 1.7 User blocks
CREATE TABLE user_blocks (
  blocker_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  PRIMARY KEY (blocker_user_id, blocked_user_id),
  CHECK (blocker_user_id <> blocked_user_id)
);

CREATE INDEX idx_user_blocks_blocked ON user_blocks(blocked_user_id);
