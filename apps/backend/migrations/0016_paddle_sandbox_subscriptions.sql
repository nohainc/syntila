-- Sandbox records are used only by a development backend. No production
-- entitlement can be granted by the sandbox route.
CREATE TABLE paddle_sandbox_subscriptions (
  subscription_id text PRIMARY KEY,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  customer_id text NOT NULL,
  status text NOT NULL CHECK (status IN ('active', 'trialing', 'past_due', 'canceled')),
  current_period_end timestamptz,
  occurred_at timestamptz NOT NULL
);
CREATE INDEX paddle_sandbox_subscriptions_user_id_idx ON paddle_sandbox_subscriptions(user_id);
