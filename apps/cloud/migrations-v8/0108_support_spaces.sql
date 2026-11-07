-- Personal support Spaces: one Direct Space per user and configured support account.
-- The Space itself is an ordinary Direct Space (unique per user pair); this table
-- marks it as support and makes "one per user per support identity" a database fact.
CREATE TABLE support_spaces (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  support_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  space_id TEXT NOT NULL UNIQUE REFERENCES spaces(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, support_user_id),
  CHECK (user_id <> support_user_id)
);

CREATE INDEX idx_support_spaces_support_user ON support_spaces(support_user_id);
