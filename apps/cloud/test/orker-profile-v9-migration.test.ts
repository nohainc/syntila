import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const migration = (name: string) =>
  readFileSync(
    fileURLToPath(new URL(`../migrations-v8/${name}`, import.meta.url)),
    "utf8",
  );

describe("Worker Profile V9 cleanup migration", () => {
  it("keeps the current/history tables and drops V8 lifecycle storage", () => {
    const rows = JSON.parse(
      execFileSync("sqlite3", ["-bail", "-json", ":memory:"], {
        input:
          [
            "0001_syntila_v8.sql",
            "0043_worker_profiles_v9.sql",
            "0044_remove_v8_profile_lifecycle.sql",
            "0046_worker_catalog_profile_identity.sql",
            "0047_remove_worker_profile_signatures.sql",
          ]
            .map(migration)
            .join("\n") +
          "\nSELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('worker_catalog', 'worker_profiles', 'worker_profile_history', 'tool_profile_definitions', 'tool_profile_releases', 'tool_profile_channel_pointers', 'workspace_tool_profile_channels') ORDER BY name;",
        encoding: "utf8",
      }),
    ) as Array<{ name: string }>;
    expect(rows.map((row) => row.name)).toEqual([
      "worker_catalog",
      "worker_profile_history",
      "worker_profiles",
    ]);

    const columns = JSON.parse(
      execFileSync("sqlite3", ["-bail", "-json", ":memory:"], {
        input:
          [
            "0001_syntila_v8.sql",
            "0043_worker_profiles_v9.sql",
            "0044_remove_v8_profile_lifecycle.sql",
            "0046_worker_catalog_profile_identity.sql",
            "0047_remove_worker_profile_signatures.sql",
          ]
            .map(migration)
            .join("\n") + "\nPRAGMA table_info(worker_profiles);",
        encoding: "utf8",
      }),
    ) as Array<{ name: string }>;
    expect(columns.map((column) => column.name)).toEqual(
      expect.arrayContaining(["worker_type_id", "profile_json", "digest"]),
    );
    expect(columns.map((column) => column.name)).not.toEqual(
      expect.arrayContaining(["signature", "signing_key_id"]),
    );
  });
});
