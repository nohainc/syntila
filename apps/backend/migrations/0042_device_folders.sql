-- Folders a Connect installation lets Workers on its computer use, and the folder
-- a Space works in.
--
-- device_folders: reported by the Agent (PUT /api/worker-agent/folders). The
-- cloud sees the opaque folder id, a short label (the folder's own name, never
-- its path) and the access granted. Folders belong to a device, not to one
-- Worker: every Worker on that computer can use them. The owner sees them with
-- the device name when choosing a folder for a Space.
-- space_folders: the one folder a Space works in. It disappears with the folder
-- (the owner removed the grant in Connect) or with the Space.
-- worker_agent_sessions.device_id: which computer the Worker runs on, so Work
-- that needs a folder only goes to a Worker on the folder's device.
CREATE TABLE device_folders (
  owner_user_id text NOT NULL,
  device_id text NOT NULL,
  folder_id text NOT NULL,
  device_name text NOT NULL,
  display_name text NOT NULL,
  mode text NOT NULL CHECK (mode IN ('read', 'write')),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_user_id, device_id, folder_id)
);

CREATE TABLE space_folders (
  space_id text PRIMARY KEY REFERENCES spaces (id) ON DELETE CASCADE,
  owner_user_id text NOT NULL,
  device_id text NOT NULL,
  folder_id text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (owner_user_id, device_id, folder_id)
    REFERENCES device_folders (owner_user_id, device_id, folder_id) ON DELETE CASCADE
);
CREATE INDEX space_folders_folder_idx ON space_folders (owner_user_id, device_id, folder_id);

ALTER TABLE worker_agent_sessions ADD COLUMN device_id text;
