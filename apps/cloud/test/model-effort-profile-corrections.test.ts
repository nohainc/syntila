import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { createHash } from "node:crypto";
import { expect, it } from "vitest";
import { parseProfile } from "../src/tool-profile-validation.js";
import { spaceModelOptions } from "../src/worker-execution-options.js";

const templates = new URL(
  "../../profile_lab/assets/profiles/",
  import.meta.url,
);
const migrations = new URL("../migrations-v8/", import.meta.url);
const read = (url: URL) => readFileSync(url, "utf8");

it("Claude authoring templates derive models via discovery with a matching invocation slot", () => {
  const payload = read(new URL("claude.json", templates));
  const profile = parseProfile(JSON.parse(payload)).profile;
  expect(profile.model.discovery?.format).toBe("claude_models_api");
  expect(profile.model.unknownModelPolicy).toBe("pass_through");
  const options = spaceModelOptions(payload, "2.1.287")!;
  expect(options.catalog).toEqual([]);
  expect(profile.execution.arguments).toContainEqual({
    ifPresent: "reasoningEffort",
    values: ["--effort", "{{reasoningEffort}}"],
  });
});

it("Gemini authoring templates derive efforts from the CLI instead of declaring models", () => {
  for (const name of ["gemini.json"]) {
    const profile = parseProfile(
      JSON.parse(read(new URL(name, templates))),
    ).profile;
    expect(profile.model.selectionMapping).toBeUndefined();
    expect(profile.model.selectionMode).toBe("combined");
    expect(profile.model.discovery?.effortVariants).toEqual({
      source: "label_parenthesized_suffix",
      separator: "-",
    });
  }
});

it("migration preserves history, is repeatable, and leaves custom Profiles alone", () => {
  const db = new DatabaseSync(":memory:");
  for (const name of readdirSync(migrations)
    .filter((n) => n.endsWith(".sql") && n < "0053")
    .sort())
    db.exec(read(new URL(name, migrations)));
  const migration = read(
    new URL("0053_correct_model_effort_profiles.sql", migrations),
  );
  const oldDigest = migration.match(
    /worker_type_id = 'gemini' AND digest = '(.*?)'/,
  )![1]!;
  db.prepare(
    "INSERT INTO worker_profiles (worker_type_id, schema_version, profile_json, revision, digest, updated_at) VALUES (?, 1, '{}', 9, ?, 'now')",
  ).run("gemini", oldDigest);
  db.prepare(
    "INSERT INTO worker_profiles (worker_type_id, schema_version, profile_json, revision, digest, updated_at) VALUES (?, 1, '{}', 9, ?, 'now')",
  ).run("claude", "a".repeat(64));
  db.exec(migration);
  const row = db
    .prepare("SELECT * FROM worker_profiles WHERE worker_type_id='gemini'")
    .get()!;
  expect(row.revision).toBe(10);
  expect(row.digest).toBe(
    createHash("sha256").update(String(row.profile_json)).digest("hex"),
  );
  expect(
    db
      .prepare(
        "SELECT digest FROM worker_profile_history WHERE worker_type_id='gemini' AND revision=9",
      )
      .get()!.digest,
  ).toBe(oldDigest);
  db.exec(migration);
  expect(
    db
      .prepare("SELECT * FROM worker_profiles WHERE worker_type_id='gemini'")
      .get(),
  ).toEqual(row);
  expect(
    db
      .prepare(
        "SELECT digest FROM worker_profiles WHERE worker_type_id='claude'",
      )
      .get()!.digest,
  ).toBe("a".repeat(64));
  db.close();
});
