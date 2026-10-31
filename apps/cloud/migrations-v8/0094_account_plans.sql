-- Two account tiers: everyone is Free unless a row grants Paid. Rows are
-- written by manual grants now and by billing-provider webhooks later; the
-- client never writes them.
CREATE TABLE account_plans (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  tier TEXT NOT NULL CHECK (tier IN ('free', 'paid')),
  status TEXT NOT NULL CHECK (status IN ('active', 'trialing', 'past_due', 'canceled')),
  source TEXT NOT NULL CHECK (source IN ('manual', 'provider')),
  current_period_end TEXT,
  provider_customer_id TEXT,
  provider_subscription_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
