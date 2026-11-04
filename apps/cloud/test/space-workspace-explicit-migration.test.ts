import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

const migration = readFileSync(
  new URL(
    "../migrations-v8/0103_space_workspace_explicit.sql",
    import.meta.url,
  ),
  "utf8",
);

it("0103 pins each inheriting Space to its owner's usable Workspace, else none", () => {
  const { sqlite } = sqliteD1();
  try {
    sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('a','a@t','A','now','now'),('b','b@t','B','now','now'),('c','c@t','C','now','now');
      INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at) VALUES('live','a','Live','online','now','now'),('gone','b','Gone','revoked','now','now'),('mine','a','Mine','online','now','now');
      INSERT INTO user_workflow_settings VALUES('a','live','t1'),('b','gone','t2');
      INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('inherits','a','S1','now','s1'),('stale','b','S2','now','s2'),('nodefault','c','S3','now','s3'),('own','a','S4','now','s4');
      INSERT INTO space_workflow_settings VALUES('own','mine','t0');`);
    sqlite.exec(migration);
    expect(
      sqlite
        .prepare(
          "SELECT space_id, workspace_id FROM space_workflow_settings ORDER BY space_id",
        )
        .all(),
    ).toEqual([
      { space_id: "inherits", workspace_id: "live" },
      { space_id: "nodefault", workspace_id: null },
      { space_id: "own", workspace_id: "mine" },
      { space_id: "stale", workspace_id: null },
    ]);
  } finally {
    sqlite.close();
  }
});
