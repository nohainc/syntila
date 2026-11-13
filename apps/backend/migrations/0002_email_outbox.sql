-- Durable outbox for email the backend starts (invitations, notifications).
-- The auth Worker's relay sends them; the backend retries with backoff until
-- the relay confirms, so a Cloudflare outage delays email instead of losing it.
CREATE TABLE email_outbox (
  id              text PRIMARY KEY,
  message         jsonb NOT NULL,
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed')),
  attempts        integer NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  last_error      text,
  relay_message_id text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  sent_at         timestamptz
);
CREATE INDEX email_outbox_due_idx ON email_outbox (next_attempt_at) WHERE status = 'pending';
