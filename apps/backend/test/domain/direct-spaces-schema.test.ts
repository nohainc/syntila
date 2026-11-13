import { describe, expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { normalizeUserPair } from "@syntila/core";

describe("Direct Spaces and Personal Connections Schema (Phase 1)", () => {
  it("defaults existing spaces to group kind and enforces valid discriminator values", () => {
    const { sqlite } = sqliteD1();
    try {
      sqlite.exec(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES ('u1', 'u1@test', 'User 1', 'now', 'now');",
      );
      sqlite.exec(
        "INSERT INTO spaces (id, owner_user_id, name, created_at, updated_at) VALUES ('s1', 'u1', 'Test Space', 'now', 'now');",
      );
      const row = sqlite
        .prepare("SELECT kind FROM spaces WHERE id = 's1'")
        .get() as { kind: string };
      expect(row.kind).toBe("group");

      expect(() => {
        sqlite.exec(
          "INSERT INTO spaces (id, owner_user_id, name, kind, created_at, updated_at) VALUES ('s2', 'u1', 'Invalid', 'invalid', 'now', 'now');",
        );
      }).toThrow(/CHECK constraint failed/);

      sqlite.exec(
        "INSERT INTO spaces (id, owner_user_id, name, kind, created_at, updated_at) VALUES ('s3', 'u1', 'Direct Space', 'direct', 'now', 'now');",
      );
      const directRow = sqlite
        .prepare("SELECT kind FROM spaces WHERE id = 's3'")
        .get() as { kind: string };
      expect(directRow.kind).toBe("direct");
    } finally {
      sqlite.close();
    }
  });

  it("enforces Direct Space identity, user ordering, uniqueness, and general thread ownership", () => {
    const { sqlite } = sqliteD1();
    try {
      sqlite.exec(`
        INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES
          ('alice', 'alice@test', 'Alice', 'now', 'now'),
          ('bob', 'bob@test', 'Bob', 'now', 'now'),
          ('charlie', 'charlie@test', 'Charlie', 'now', 'now');

        INSERT INTO spaces (id, owner_user_id, name, kind, created_at, updated_at) VALUES
          ('space-ab', 'alice', 'Direct AB', 'direct', 'now', 'now'),
          ('space-other', 'alice', 'Other Space', 'group', 'now', 'now');

        INSERT INTO threads (id, space_id, name, status, lead_user_id, created_at, updated_at) VALUES
          ('thread-ab-general', 'space-ab', 'General', 'active', 'alice', 'now', 'now'),
          ('thread-other', 'space-other', 'Other', 'active', 'alice', 'now', 'now');
      `);

      const { userLowId, userHighId } = normalizeUserPair("bob", "alice");
      expect(userLowId).toBe("alice");
      expect(userHighId).toBe("bob");

      // General Thread must belong to the same space
      expect(() => {
        sqlite.exec(`
          INSERT INTO direct_spaces (space_id, user_low_id, user_high_id, general_thread_id, created_at)
          VALUES ('space-ab', '${userLowId}', '${userHighId}', 'thread-other', 'now');
        `);
      }).toThrow(/general_thread_id must belong to the same Direct Space/);

      // Successful insertion
      sqlite.exec(`
        INSERT INTO direct_spaces (space_id, user_low_id, user_high_id, general_thread_id, created_at)
        VALUES ('space-ab', '${userLowId}', '${userHighId}', 'thread-ab-general', 'now');
      `);

      // Reject duplicate Direct Space for the same user pair
      sqlite.exec(`
        INSERT INTO spaces (id, owner_user_id, name, kind, created_at, updated_at) VALUES
          ('space-ab-2', 'bob', 'Direct AB 2', 'direct', 'now', 'now');
        INSERT INTO threads (id, space_id, name, status, lead_user_id, created_at, updated_at) VALUES
          ('thread-ab-2-gen', 'space-ab-2', 'General', 'active', 'bob', 'now', 'now');
      `);
      expect(() => {
        sqlite.exec(`
          INSERT INTO direct_spaces (space_id, user_low_id, user_high_id, general_thread_id, created_at)
          VALUES ('space-ab-2', '${userLowId}', '${userHighId}', 'thread-ab-2-gen', 'now');
        `);
      }).toThrow(/UNIQUE constraint failed/);

      // Reject self-conversation at DB level
      expect(() => {
        sqlite.exec(`
          INSERT INTO direct_spaces (space_id, user_low_id, user_high_id, general_thread_id, created_at)
          VALUES ('space-ab-2', 'alice', 'alice', 'thread-ab-2-gen', 'now');
        `);
      }).toThrow(/CHECK constraint failed/);

      // Deleting the General Thread is restricted
      expect(() => {
        sqlite.exec("DELETE FROM threads WHERE id = 'thread-ab-general'");
      }).toThrow(/FOREIGN KEY constraint failed/);

      expect(sqlite.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    } finally {
      sqlite.close();
    }
  });

  it("prevents duplicate pending personal invitations including reverse directions", () => {
    const { sqlite } = sqliteD1();
    try {
      sqlite.exec(`
        INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES
          ('alice', 'alice@test', 'Alice', 'now', 'now'),
          ('bob', 'bob@test', 'Bob', 'now', 'now');

        INSERT INTO person_invitations (id, inviter_user_id, invitee_user_id, status, created_at, expires_at, updated_at)
        VALUES ('inv-1', 'alice', 'bob', 'pending', 'now', '2099-01-01T00:00:00Z', 'now');
      `);

      // Duplicate invitation in same direction
      expect(() => {
        sqlite.exec(`
          INSERT INTO person_invitations (id, inviter_user_id, invitee_user_id, status, created_at, expires_at, updated_at)
          VALUES ('inv-2', 'alice', 'bob', 'pending', 'now', '2099-01-01T00:00:00Z', 'now');
        `);
      }).toThrow(/UNIQUE constraint failed/);

      // Reverse direction invitation while pending
      expect(() => {
        sqlite.exec(`
          INSERT INTO person_invitations (id, inviter_user_id, invitee_user_id, status, created_at, expires_at, updated_at)
          VALUES ('inv-3', 'bob', 'alice', 'pending', 'now', '2099-01-01T00:00:00Z', 'now');
        `);
      }).toThrow(/UNIQUE constraint failed/);

      // Duplicate email pending invitation
      sqlite.exec(`
        INSERT INTO person_invitations (id, inviter_user_id, email, status, created_at, expires_at, updated_at)
        VALUES ('inv-email-1', 'alice', 'charlie@test', 'pending', 'now', '2099-01-01T00:00:00Z', 'now');
      `);
      expect(() => {
        sqlite.exec(`
          INSERT INTO person_invitations (id, inviter_user_id, email, status, created_at, expires_at, updated_at)
          VALUES ('inv-email-2', 'alice', 'CHARLIE@TEST', 'pending', 'now', '2099-01-01T00:00:00Z', 'now');
        `);
      }).toThrow(/UNIQUE constraint failed/);

      expect(sqlite.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    } finally {
      sqlite.close();
    }
  });

  it("manages person_connections and direct_space_user_state", () => {
    const { sqlite } = sqliteD1();
    try {
      sqlite.exec(`
        INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES
          ('u1', 'u1@test', 'User 1', 'now', 'now'),
          ('u2', 'u2@test', 'User 2', 'now', 'now');

        INSERT INTO spaces (id, owner_user_id, name, kind, created_at, updated_at) VALUES
          ('ds1', 'u1', 'Direct Space', 'direct', 'now', 'now');

        INSERT INTO threads (id, space_id, name, status, lead_user_id, created_at, updated_at) VALUES
          ('th1', 'ds1', 'General', 'active', 'u1', 'now', 'now');

        INSERT INTO direct_spaces (space_id, user_low_id, user_high_id, general_thread_id, created_at)
        VALUES ('ds1', 'u1', 'u2', 'th1', 'now');

        INSERT INTO person_connections (user_low_id, user_high_id, status, established_at, direct_space_id)
        VALUES ('u1', 'u2', 'connected', 'now', 'ds1');

        INSERT INTO direct_space_user_state (space_id, user_id, hidden, created_at, updated_at) VALUES
          ('ds1', 'u1', 0, 'now', 'now'),
          ('ds1', 'u2', 1, 'now', 'now');
      `);

      const connection = sqlite
        .prepare(
          "SELECT * FROM person_connections WHERE user_low_id = 'u1' AND user_high_id = 'u2'",
        )
        .get() as { status: string; direct_space_id: string };
      expect(connection.status).toBe("connected");
      expect(connection.direct_space_id).toBe("ds1");

      const u2State = sqlite
        .prepare(
          "SELECT hidden FROM direct_space_user_state WHERE space_id = 'ds1' AND user_id = 'u2'",
        )
        .get() as { hidden: number };
      expect(u2State.hidden).toBe(1);

      expect(sqlite.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    } finally {
      sqlite.close();
    }
  });
});
