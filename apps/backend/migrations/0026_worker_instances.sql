-- Worker Instance and Actor identity (ADR-032, phase P1). Additive only.
--
-- * actors: the immutable principal that authors things. One human Actor per
--   user, one worker Actor per Worker Instance, fixed system Actors. Created by
--   triggers, so no code path can create a user or a Worker Instance without one.
-- * worker_instances: a durable, user-owned Worker, separate from the Worker
--   Type (worker_catalog) and the Workspace. The name is NOT unique. Removing a
--   Worker sets revoked_at (a tombstone); its Actor is never deleted.
-- * legacy_worker_mapping: workspace_worker_inventory.worker_id -> Worker
--   Instance. The inventory still drives execution until P5; a trigger keeps a
--   Worker Instance for every inventory row.
-- * nullable worker_instance_id on assignments, activity history and the Thread
--   and Workflow configuration tables. Nothing becomes NOT NULL yet.

CREATE TABLE actors (
  id text PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('human', 'worker', 'system')),
  user_id text UNIQUE REFERENCES users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  tombstoned_at timestamptz,
  UNIQUE (id, kind),
  CHECK (user_id IS NULL OR kind = 'human'),
  -- A human Actor loses its user only when the account is deleted (tombstone).
  CHECK (kind <> 'human' OR user_id IS NOT NULL OR tombstoned_at IS NOT NULL)
);

CREATE TABLE worker_instances (
  id text PRIMARY KEY,
  actor_id text NOT NULL,
  actor_kind text NOT NULL DEFAULT 'worker' CHECK (actor_kind = 'worker'),
  owner_user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  worker_type_id text NOT NULL REFERENCES worker_catalog(worker_type_id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  description text NOT NULL DEFAULT '' CHECK (length(description) <= 500),
  enabled boolean NOT NULL DEFAULT true,
  default_model text CHECK (default_model IS NULL OR length(default_model) BETWEEN 1 AND 200),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  UNIQUE (actor_id),
  UNIQUE (actor_id, actor_kind),
  FOREIGN KEY (actor_id, actor_kind) REFERENCES actors(id, kind) ON DELETE RESTRICT,
  CHECK (revoked_at IS NULL OR enabled = false)
);
CREATE INDEX worker_instances_owner_created_idx ON worker_instances (owner_user_id, created_at);
CREATE INDEX worker_instances_worker_type_idx ON worker_instances (worker_type_id);

CREATE TABLE legacy_worker_mapping (
  legacy_worker_id text PRIMARY KEY,
  worker_instance_id text NOT NULL UNIQUE REFERENCES worker_instances(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- System Actors are fixed and created only here.
INSERT INTO actors (id, kind) VALUES ('actor-system-platform', 'system');

/* ---------------------------------------------------------------- Actors */

CREATE FUNCTION users_create_actor_fn() RETURNS trigger AS $$
BEGIN
  INSERT INTO actors (id, kind, user_id) VALUES ('actor-human-' || NEW.id, 'human', NEW.id);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER users_create_actor AFTER INSERT ON users
  FOR EACH ROW EXECUTE FUNCTION users_create_actor_fn();

-- Deleting an account tombstones its Actor instead of deleting it: messages
-- written by that person keep their author.
CREATE FUNCTION users_tombstone_actor_fn() RETURNS trigger AS $$
BEGIN
  UPDATE actors SET user_id = NULL, tombstoned_at = now() WHERE user_id = OLD.id;
  RETURN OLD;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER users_tombstone_actor BEFORE DELETE ON users
  FOR EACH ROW EXECUTE FUNCTION users_tombstone_actor_fn();

INSERT INTO actors (id, kind, user_id)
SELECT 'actor-human-' || id, 'human', id FROM users;

/* ------------------------------------------------------- Worker Instances */

-- Every Worker Instance gets its own worker Actor.
CREATE FUNCTION worker_instances_create_actor_fn() RETURNS trigger AS $$
BEGIN
  NEW.actor_id := 'actor-worker-' || NEW.id;
  NEW.actor_kind := 'worker';
  INSERT INTO actors (id, kind) VALUES (NEW.actor_id, 'worker');
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER worker_instances_create_actor BEFORE INSERT ON worker_instances
  FOR EACH ROW EXECUTE FUNCTION worker_instances_create_actor_fn();

-- Identity never changes in place: owner (explicit transfer comes later), Type
-- and Actor are fixed, and a tombstone is final.
CREATE FUNCTION worker_instances_guard_fn() RETURNS trigger AS $$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.actor_id IS DISTINCT FROM OLD.actor_id
     OR NEW.owner_user_id IS DISTINCT FROM OLD.owner_user_id
     OR NEW.worker_type_id IS DISTINCT FROM OLD.worker_type_id THEN
    RAISE EXCEPTION 'A Worker keeps its id, Actor, owner and Type; create a new Worker instead'
      USING ERRCODE = '23514', CONSTRAINT = 'worker_instances_identity_immutable';
  END IF;
  IF OLD.revoked_at IS NOT NULL AND (NEW.revoked_at IS DISTINCT FROM OLD.revoked_at
     OR NEW.name IS DISTINCT FROM OLD.name OR NEW.description IS DISTINCT FROM OLD.description
     OR NEW.enabled IS DISTINCT FROM OLD.enabled OR NEW.default_model IS DISTINCT FROM OLD.default_model) THEN
    RAISE EXCEPTION 'A removed Worker cannot change'
      USING ERRCODE = '23514', CONSTRAINT = 'worker_instances_tombstone_final';
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER worker_instances_guard BEFORE UPDATE ON worker_instances
  FOR EACH ROW EXECUTE FUNCTION worker_instances_guard_fn();

-- A removed Worker (tombstone) or a deleted row tombstones its Actor.
CREATE FUNCTION worker_instances_tombstone_actor_fn() RETURNS trigger AS $$
BEGIN
  UPDATE actors SET tombstoned_at = COALESCE(tombstoned_at, now())
   WHERE id = COALESCE(OLD.actor_id, NEW.actor_id);
  RETURN COALESCE(NEW, OLD);
END $$ LANGUAGE plpgsql;
CREATE TRIGGER worker_instances_tombstone_actor AFTER UPDATE OF revoked_at ON worker_instances
  FOR EACH ROW WHEN (OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL)
  EXECUTE FUNCTION worker_instances_tombstone_actor_fn();
CREATE TRIGGER worker_instances_tombstone_actor_on_delete AFTER DELETE ON worker_instances
  FOR EACH ROW EXECUTE FUNCTION worker_instances_tombstone_actor_fn();

/* ------------------------------------------- Legacy inventory -> Instances */

-- One Worker Instance per workspace_worker_inventory row, keeping worker_id as
-- the Instance id when it is a valid id. Rows whose Worker Type is not in the
-- catalog are skipped (the integrity check reports them).
CREATE FUNCTION adopt_inventory_worker(p_worker_id text) RETURNS void AS $$
DECLARE
  inv workspace_worker_inventory%ROWTYPE;
  catalog_name text;
  new_id text;
BEGIN
  -- Already adopted by a live Instance: nothing to do. A mapping to a tombstone
  -- is stale (the Worker was removed and registered again): replace it.
  IF EXISTS (SELECT 1 FROM legacy_worker_mapping m JOIN worker_instances w ON w.id = m.worker_instance_id
              WHERE m.legacy_worker_id = p_worker_id AND w.revoked_at IS NULL) THEN RETURN; END IF;
  DELETE FROM legacy_worker_mapping WHERE legacy_worker_id = p_worker_id;
  SELECT * INTO inv FROM workspace_worker_inventory WHERE worker_id = p_worker_id;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT display_name INTO catalog_name FROM worker_catalog WHERE worker_type_id = inv.worker_type_id;
  IF NOT FOUND THEN RETURN; END IF;
  new_id := CASE
    WHEN p_worker_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$'
         AND NOT EXISTS (SELECT 1 FROM worker_instances WHERE id = p_worker_id)
      THEN p_worker_id
    ELSE 'wrk-' || gen_random_uuid()
  END;
  INSERT INTO worker_instances (id, actor_id, owner_user_id, worker_type_id, name, enabled, created_at, updated_at)
  VALUES (new_id, '', inv.owner_user_id, inv.worker_type_id,
          COALESCE(NULLIF(btrim(catalog_name), ''), inv.worker_type_id),
          inv.activation_state = 'enabled', inv.created_at, now());
  INSERT INTO legacy_worker_mapping (legacy_worker_id, worker_instance_id) VALUES (p_worker_id, new_id);
END $$ LANGUAGE plpgsql;

CREATE FUNCTION inventory_adopt_worker_fn() RETURNS trigger AS $$
BEGIN
  PERFORM adopt_inventory_worker(NEW.worker_id);
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER inventory_adopt_worker AFTER INSERT ON workspace_worker_inventory
  FOR EACH ROW EXECUTE FUNCTION inventory_adopt_worker_fn();

-- A Worker removed from its Workspace is tombstoned, never deleted.
CREATE FUNCTION inventory_revoke_worker_fn() RETURNS trigger AS $$
BEGIN
  UPDATE worker_instances SET revoked_at = now(), enabled = false, updated_at = now()
   WHERE revoked_at IS NULL
     AND id = (SELECT worker_instance_id FROM legacy_worker_mapping WHERE legacy_worker_id = OLD.worker_id);
  RETURN OLD;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER inventory_revoke_worker AFTER DELETE ON workspace_worker_inventory
  FOR EACH ROW EXECUTE FUNCTION inventory_revoke_worker_fn();

SELECT adopt_inventory_worker(worker_id) FROM workspace_worker_inventory;

/* ----------------------------------------- Nullable references, no NOT NULL */

ALTER TABLE worker_assignments ADD COLUMN worker_instance_id text REFERENCES worker_instances(id) ON DELETE SET NULL;
ALTER TABLE worker_activity_history ADD COLUMN worker_instance_id text REFERENCES worker_instances(id) ON DELETE SET NULL;
ALTER TABLE thread_work_configs ADD COLUMN worker_instance_id text REFERENCES worker_instances(id) ON DELETE SET NULL;
ALTER TABLE user_workflow_configurations ADD COLUMN worker_instance_id text REFERENCES worker_instances(id) ON DELETE SET NULL;
CREATE INDEX worker_assignments_worker_instance_idx ON worker_assignments (worker_instance_id);
CREATE INDEX worker_activity_history_worker_instance_idx ON worker_activity_history (worker_instance_id);
CREATE INDEX thread_work_configs_worker_instance_idx ON thread_work_configs (worker_instance_id);
CREATE INDEX user_workflow_configurations_worker_instance_idx ON user_workflow_configurations (worker_instance_id);

-- New rows learn their Worker Instance through the legacy mapping until the
-- code sets it itself (P5).
CREATE FUNCTION worker_assignments_set_instance_fn() RETURNS trigger AS $$
BEGIN
  IF NEW.worker_instance_id IS NULL AND NEW.workspace_worker_id IS NOT NULL THEN
    SELECT worker_instance_id INTO NEW.worker_instance_id
      FROM legacy_worker_mapping WHERE legacy_worker_id = NEW.workspace_worker_id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER worker_assignments_set_instance BEFORE INSERT ON worker_assignments
  FOR EACH ROW EXECUTE FUNCTION worker_assignments_set_instance_fn();

CREATE FUNCTION worker_activity_history_set_instance_fn() RETURNS trigger AS $$
BEGIN
  IF NEW.worker_instance_id IS NULL THEN
    SELECT worker_instance_id INTO NEW.worker_instance_id
      FROM legacy_worker_mapping WHERE legacy_worker_id = NEW.worker_id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER worker_activity_history_set_instance BEFORE INSERT ON worker_activity_history
  FOR EACH ROW EXECUTE FUNCTION worker_activity_history_set_instance_fn();

UPDATE worker_assignments a SET worker_instance_id = m.worker_instance_id
  FROM legacy_worker_mapping m
 WHERE a.worker_instance_id IS NULL AND m.legacy_worker_id = a.workspace_worker_id;
UPDATE worker_activity_history h SET worker_instance_id = m.worker_instance_id
  FROM legacy_worker_mapping m
 WHERE h.worker_instance_id IS NULL AND m.legacy_worker_id = h.worker_id;
