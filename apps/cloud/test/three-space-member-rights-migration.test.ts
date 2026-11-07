import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

describe("three Space member rights migration", () => {
  let store: ReturnType<typeof sqliteD1>;
  const sql = readFileSync(
    new URL(
      "../migrations-v8/0106_three_space_member_rights.sql",
      import.meta.url,
    ),
    "utf8",
  );
  const insert = (id: string, settings: string) =>
    store.sqlite
      .prepare(
        "INSERT INTO spaces(id,owner_user_id,name,settings_json,created_at,updated_at) VALUES(?,'owner',?,?,'now','now')",
      )
      .run(id, id, settings);
  const read = (id: string) =>
    (
      store.sqlite
        .prepare("SELECT settings_json FROM spaces WHERE id=?")
        .get(id) as { settings_json: string }
    ).settings_json;

  beforeEach(() => {
    store = sqliteD1();
    store.sqlite
      .prepare(
        "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('owner','owner@test','Owner','now','now')",
      )
      .run();
  });
  afterEach(() => store.sqlite.close());

  it("drops derived useOwnWorkers from member and invitation snapshots only", () => {
    insert(
      "legacy",
      JSON.stringify({
        theme: "dark",
        memberPermissions: {
          a: { chat: true, useOwnWorkers: false, work: false },
          b: { chat: false, useOwnWorkers: true, manageOwnThreads: true },
          bad: "junk",
        },
        invitationPermissions: {
          i: { chat: true, useOwnWorkers: true, work: true },
        },
      }),
    );
    store.sqlite.exec(sql);
    expect(JSON.parse(read("legacy"))).toEqual({
      theme: "dark",
      memberPermissions: {
        a: { chat: true, work: false },
        b: { chat: false, manageOwnThreads: true },
        bad: "junk",
      },
      invitationPermissions: { i: { chat: true, work: true } },
    });
  });

  it("leaves absent, non-object and malformed settings untouched", () => {
    insert("empty", "{}");
    insert("array", JSON.stringify({ memberPermissions: [1] }));
    insert("broken", "{not json");
    store.sqlite.exec(sql);
    expect(read("empty")).toBe("{}");
    expect(read("array")).toBe('{"memberPermissions":[1]}');
    expect(read("broken")).toBe("{not json");
  });

  it("is idempotent", () => {
    insert("s", JSON.stringify({ memberPermissions: { a: { chat: true } } }));
    store.sqlite.exec(sql);
    const once = read("s");
    store.sqlite.exec(sql);
    expect(read("s")).toBe(once);
  });
});
