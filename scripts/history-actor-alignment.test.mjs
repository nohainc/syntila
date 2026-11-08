import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { expect, it } from "vitest";

const history = readFileSync(
  new URL(
    "../apps/cloud/migrations-v8/0012_canonical_conversation_history.sql",
    import.meta.url,
  ),
  "utf8",
);
const migration = readFileSync(
  new URL(
    "../apps/cloud/migrations-v8/0113_history_actor_alignment.sql",
    import.meta.url,
  ),
  "utf8",
);

it.each(["conclave", "syntila"])(
  "preserves %s history and enforces the canonical actor",
  (actor) => {
    const db = new DatabaseSync(":memory:");
    try {
      db.exec(
        "PRAGMA foreign_keys = ON; CREATE TABLE conversations(id TEXT PRIMARY KEY, context_revision INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL DEFAULT '2026-11-08');",
      );
      db.exec(
        history
          .slice(
            history.indexOf("CREATE TABLE"),
            history.indexOf("CREATE TRIGGER trg_history_user_message"),
          )
          .replaceAll("'syntila'", `'${actor}'`),
      );
      db.exec("INSERT INTO conversations(id) VALUES ('conversation');");
      const insert = db.prepare(`INSERT INTO conversation_history_entries
      (id,conversation_id,sequence,kind,event_type,actor_type,source_id,occurred_at)
      VALUES (?, 'conversation', ?, 'workflow_event', 'workflow.request_accepted', ?, 'request', '2026-11-08')`);
      insert.run("existing", 1, actor);
      for (const target of new Set(
        [
          ...migration.matchAll(
            /(?:AFTER|BEFORE) (?:INSERT|DELETE|UPDATE(?: OF \w+)?) ON (\w+)/g,
          ),
        ].map((match) => match[1]),
      )) {
        if (!["conversations", "conversation_history_entries"].includes(target))
          db.exec(`CREATE TABLE ${target}(id TEXT PRIMARY KEY)`);
      }
      db.exec("BEGIN");
      db.exec(migration);
      db.exec("COMMIT");
      expect(
        db
          .prepare(
            "SELECT id, sequence, actor_type, source_id FROM conversation_history_entries",
          )
          .get(),
      ).toEqual({
        id: "existing",
        sequence: 1,
        actor_type: "syntila",
        source_id: "request",
      });
      insert.run("new", 2, "syntila");
      db.exec("UPDATE conversations SET context_revision = 1");
      expect(
        db
          .prepare(
            "SELECT actor_type FROM conversation_history_entries WHERE event_type='context.revision_advanced'",
          )
          .get().actor_type,
      ).toBe("syntila");
      expect(() => insert.run("legacy", 4, "conclave")).toThrow(/CHECK/);
      expect(() =>
        db.exec("UPDATE conversation_history_entries SET source_id='changed'"),
      ).toThrow(/append-only/);
      expect(() => db.exec("DELETE FROM conversation_history_entries")).toThrow(
        /cannot be deleted/,
      );
      expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
      expect(db.prepare("PRAGMA integrity_check").get().integrity_check).toBe(
        "ok",
      );
      expect(
        db
          .prepare(
            "SELECT name FROM sqlite_schema WHERE type='trigger' AND sql LIKE '%''conclave''%'",
          )
          .all(),
      ).toEqual([]);
    } finally {
      db.close();
    }
  },
);
