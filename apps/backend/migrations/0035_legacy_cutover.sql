-- P10 (ADR-032/034): staged, reversible cutover away from Workspaces.
--
-- One row of switches, flipped by scripts/legacy-cutover.sh (never by a
-- migration), so each step can be rehearsed and rolled back during the rollback
-- window:
--   workspace_registration_closed_at  no new Workspace registers; existing ones keep running
--   workspace_gateway_closed_at       the Workspace gateway and runtime transport refuse connections
--   worker_required_from              new assignments and Agent commands must name a Worker Instance
-- Dropping the Workspace tables and paths is NOT done here: it is a later migration
-- that ships only after the rollback window (docs/operations/LEGACY_CUTOVER.md).

CREATE TABLE legacy_cutover (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  workspace_registration_closed_at timestamptz,
  workspace_gateway_closed_at timestamptz,
  worker_required_from timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO legacy_cutover (id) VALUES (true);

-- "NOT NULL on new rows": enforced for inserts once worker_required_from is set.
-- Existing rows are untouched, so turning the switch off again is a rollback.
CREATE FUNCTION require_worker_instance_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.worker_instance_id IS NULL
     AND EXISTS (SELECT 1 FROM legacy_cutover WHERE worker_required_from IS NOT NULL) THEN
    RAISE EXCEPTION 'worker_instance_required' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER worker_assignments_require_worker BEFORE INSERT ON worker_assignments
  FOR EACH ROW EXECUTE FUNCTION require_worker_instance_fn();
CREATE TRIGGER agent_commands_require_worker BEFORE INSERT ON agent_commands
  FOR EACH ROW EXECUTE FUNCTION require_worker_instance_fn();

-- The identity mapping is archived before the legacy tables go: it is the only
-- record of which legacy Worker became which Worker Instance.
CREATE TABLE legacy_worker_mapping_archive (
  legacy_worker_id text PRIMARY KEY,
  worker_instance_id text NOT NULL,
  mapped_at timestamptz NOT NULL,
  archived_at timestamptz NOT NULL DEFAULT now()
);
CREATE FUNCTION archive_legacy_worker_mapping() RETURNS int LANGUAGE plpgsql AS $$
DECLARE copied int;
BEGIN
  INSERT INTO legacy_worker_mapping_archive (legacy_worker_id, worker_instance_id, mapped_at)
  SELECT legacy_worker_id, worker_instance_id, created_at FROM legacy_worker_mapping
  ON CONFLICT (legacy_worker_id) DO NOTHING;
  GET DIAGNOSTICS copied = ROW_COUNT;
  RETURN copied;
END $$;
