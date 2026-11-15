import { describe, expect, test } from "bun:test";
import { handleAccountDeletionCleanup } from "../../src/domain/auth/account-lifecycle";
import { pgD1 } from "./helpers/pg-d1";

function seed() {
  const { db, sqlite } = pgD1();
  sqlite.exec(`
    INSERT INTO users (id, email, display_name, status) VALUES
      ('gone', 'gone@test', 'Gone', 'active'), ('peer', 'peer@test', 'Peer', 'active'),
      ('idle', 'idle@test', 'Idle', 'deactivated'), ('first', 'first@test', 'First', 'active'),
      ('second', 'second@test', 'Second', 'active');

    INSERT INTO spaces (id, owner_user_id, name, kind) VALUES
      ('d-active', 'gone', 'Direct with active peer', 'direct'),
      ('d-idle', 'gone', 'Direct with deactivated peer', 'direct'),
      ('d-peer-owned', 'first', 'Direct owned by the other participant', 'direct'),
      ('g-shared', 'gone', 'Group with members', 'group'),
      ('g-alone', 'gone', 'Group alone', 'group'),
      ('g-other', 'first', 'Group owned by someone else', 'group');
    INSERT INTO direct_spaces (space_id, user_low_id, user_high_id) VALUES
      ('d-active', 'gone', 'peer'), ('d-idle', 'gone', 'idle'), ('d-peer-owned', 'first', 'gone');
    INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at) VALUES
      ('m1', 'd-active', 'gone', 'owner', now(), now()), ('m2', 'd-active', 'peer', 'collaborator', now(), now()),
      ('m3', 'd-idle', 'gone', 'owner', now(), now()), ('m4', 'd-idle', 'idle', 'collaborator', now(), now()),
      ('m5', 'd-peer-owned', 'first', 'owner', now(), now()), ('m6', 'd-peer-owned', 'gone', 'collaborator', now(), now()),
      ('m7', 'g-shared', 'gone', 'owner', now() - interval '3 days', now()),
      ('m8', 'g-shared', 'second', 'viewer', now() - interval '1 day', now()),
      ('m9', 'g-shared', 'first', 'collaborator', now() - interval '2 days', now()),
      ('m10', 'g-alone', 'gone', 'owner', now(), now()),
      ('m11', 'g-other', 'first', 'owner', now(), now()), ('m12', 'g-other', 'gone', 'collaborator', now(), now());
    INSERT INTO threads (id, space_id, name, status, lead_user_id) VALUES
      ('t-shared', 'g-shared', 'T', 'active', 'gone'), ('t-other', 'g-other', 'T', 'active', 'gone');
    INSERT INTO person_connections (user_low_id, user_high_id, status, established_at) VALUES
      ('gone', 'peer', 'connected', now()), ('first', 'second', 'connected', now());
    INSERT INTO person_invitations (id, inviter_user_id, invitee_user_id, status, expires_at) VALUES
      ('i1', 'gone', 'first', 'pending', now() + interval '1 day'), ('i2', 'first', 'second', 'pending', now() + interval '1 day');
  `);
  return { db, sqlite };
}

describe("account deletion cleanup", () => {
  test("hands over or deletes owned Spaces and detaches the user, in one transaction", async () => {
    const { db, sqlite } = seed();
    await handleAccountDeletionCleanup(db, "gone");
    const rows = (sql: string) => sqlite.prepare(sql).all();

    expect(rows("SELECT id, owner_user_id FROM spaces ORDER BY id")).toEqual([
      { id: "d-active", owner_user_id: "peer" },
      { id: "d-peer-owned", owner_user_id: "first" },
      { id: "g-other", owner_user_id: "first" },
      { id: "g-shared", owner_user_id: "first" }, // earliest other member
    ]);
    expect(rows("SELECT space_id, user_id, role FROM space_memberships ORDER BY space_id, user_id")).toEqual([
      { space_id: "d-active", user_id: "peer", role: "owner" },
      { space_id: "d-peer-owned", user_id: "first", role: "owner" }, // the user only leaves it
      { space_id: "g-other", user_id: "first", role: "owner" },
      { space_id: "g-other", user_id: "gone", role: "collaborator" }, // not owned: unchanged
      { space_id: "g-shared", user_id: "first", role: "owner" },
      { space_id: "g-shared", user_id: "second", role: "viewer" },
    ]);
    expect(rows("SELECT id, lead_user_id FROM threads ORDER BY id")).toEqual([
      { id: "t-other", lead_user_id: "first" },
      { id: "t-shared", lead_user_id: "first" },
    ]);
    expect(rows("SELECT user_low_id, status FROM person_connections ORDER BY user_low_id")).toEqual([
      { user_low_id: "first", status: "connected" },
      { user_low_id: "gone", status: "disconnected" },
    ]);
    expect(rows("SELECT id, status FROM person_invitations ORDER BY id")).toEqual([
      { id: "i1", status: "cancelled" },
      { id: "i2", status: "pending" },
    ]);
  });

  test("a failure leaves everything as it was", async () => {
    const { db, sqlite } = seed();
    sqlite.exec(`CREATE FUNCTION fail_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'boom'; END $$;
      CREATE TRIGGER fail_threads BEFORE UPDATE ON threads FOR EACH ROW EXECUTE FUNCTION fail_fn();`);
    await expect(handleAccountDeletionCleanup(db, "gone")).rejects.toThrow(/boom/);
    expect(sqlite.prepare("SELECT count(*)::int AS n FROM spaces WHERE owner_user_id = 'gone'").get()).toEqual({ n: 4 });
    expect(sqlite.prepare("SELECT status FROM person_connections WHERE user_low_id = 'gone'").get()).toEqual({ status: "connected" });
  });
});
