import { expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { loadAssignmentAdditionalFolderIds } from "../../src/domain/assignment-dispatcher.js";

it("sends only folders attached by the owner of both Space and Workspace", async () => {
  const { sqlite, db } = sqliteD1();
  try {
    sqlite.exec(
      `INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES
         ('U','u@test','U','now','now'),('V','v@test','V','now','now');
       INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES
         ('A','U','Mine','now','now'),('B','U','Other','now','now');
       INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES ('S','U','Space','now','now');
       INSERT INTO workspace_allowed_folders VALUES
         ('A','folder-00000000000000b2','b','available','now','now'),
         ('A','folder-00000000000000a1','a','read_only','now','now'),
         ('B','folder-00000000000000c3','c','available','now','now');
       INSERT INTO space_additional_folders VALUES
         ('S','A','folder-00000000000000b2','now'),
         ('S','A','folder-00000000000000a1','now');`,
    );
    const load = (space: string | undefined, workspace: string) =>
      loadAssignmentAdditionalFolderIds(
        db as unknown as D1Database,
        space,
        workspace,
      );
    expect(await load("S", "A")).toEqual([
      "folder-00000000000000a1",
      "folder-00000000000000b2",
    ]);
    expect(await load("S", "B")).toEqual([]);
    expect(await load(undefined, "A")).toEqual([]);
    // A Space handed to another person never carries the old owner's folders.
    sqlite.exec("UPDATE spaces SET owner_user_id='V' WHERE id='S'");
    expect(await load("S", "A")).toEqual([]);
  } finally {
    sqlite.close();
  }
});
