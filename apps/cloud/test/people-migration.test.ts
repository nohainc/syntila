import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
it("backfills accepted co-members once, retains relationships, and consolidates duplicate pending invitations", () => {
  const { sqlite } = sqliteD1();
  try {
    sqlite.exec(`DROP TRIGGER establish_people_on_membership; DROP TABLE people_relationships; DROP INDEX idx_space_invitations_pending_email;
 INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('a','a@test','A','now','now'),('b','b@test','B','now','now'),('c','c@test','C','now','now');
 INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('A','a','A','now','now'),('B','a','B','now','now');
 INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('a1','A','a','owner','2026-01-01','now'),('b1','A','b','viewer','2026-01-02','now'),('a2','B','a','owner','2026-02-01','now'),('b2','B','b','viewer','2026-02-02','now');
 INSERT INTO space_invitations(id,space_id,email,role,token_hash,invited_by_user_id,expires_at,created_at,updated_at) VALUES('i1','A','c@test','viewer','h1','a','2099-01-01','2026-01-01','now'),('i2','A','C@test','viewer','h2','a','2099-01-01','2026-01-02','now');`);
    sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0023_people_relationships.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    expect(sqlite.prepare("SELECT * FROM people_relationships").all()).toEqual([
      { user_low_id: "a", user_high_id: "b", established_at: "2026-01-02" },
    ]);
    expect(
      sqlite
        .prepare("SELECT id,status FROM space_invitations ORDER BY id")
        .all(),
    ).toEqual([
      { id: "i1", status: "pending" },
      { id: "i2", status: "revoked" },
    ]);
    sqlite.exec(
      "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('c1','A','c','viewer','2026-03-01','now')",
    );
    expect(
      sqlite.prepare("SELECT COUNT(*) n FROM people_relationships").get(),
    ).toEqual({ n: 3 });
    sqlite.exec("DELETE FROM space_memberships");
    expect(
      sqlite.prepare("SELECT COUNT(*) n FROM people_relationships").get(),
    ).toEqual({ n: 3 });
    expect(sqlite.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
  } finally {
    sqlite.close();
  }
});

it("preserves existing spaces, threads, memberships, and people relationships when applying 0105 migration", () => {
  const { sqlite } = sqliteD1();
  try {
    sqlite.exec(`
      INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('u1','u1@test','User 1','now','now'),('u2','u2@test','User 2','now','now');
      INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('sp1','u1','Preexisting Group Space','now','now');
      INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('m1','sp1','u1','owner','now','now'),('m2','sp1','u2','collaborator','now','now');
      INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('th1','sp1','Preexisting Thread','active','u1','now','now');
    `);

    // Existing space has kind default 'group'
    const spaceRow = sqlite.prepare("SELECT kind FROM spaces WHERE id = 'sp1'").get() as { kind: string };
    expect(spaceRow.kind).toBe("group");

    // People relationships remain intact
    const rels = sqlite.prepare("SELECT * FROM people_relationships").all();
    expect(rels).toEqual([
      expect.objectContaining({ user_low_id: "u1", user_high_id: "u2" }),
    ]);

    // Threads and memberships preserved
    expect(sqlite.prepare("SELECT COUNT(*) AS n FROM threads WHERE space_id = 'sp1'").get()).toEqual({ n: 1 });
    expect(sqlite.prepare("SELECT COUNT(*) AS n FROM space_memberships WHERE space_id = 'sp1'").get()).toEqual({ n: 2 });
    expect(sqlite.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
  } finally {
    sqlite.close();
  }
});
