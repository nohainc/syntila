-- Per-Worker model and effort visibility preferences for the Thread page
-- execution selector (`hiddenModels` and `hiddenEfforts`).
ALTER TABLE worker_instances
  ADD COLUMN visibility_json text NOT NULL DEFAULT '{"hiddenModels":[],"hiddenEfforts":{}}'
    CHECK (visibility_json IS JSON);
