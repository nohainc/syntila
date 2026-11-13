import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { createHash } from "node:crypto";
import { expect, it } from "./helpers/vitest-compat";
import { parseProfile } from "../../src/domain/tool-profile-validation.js";
import { spaceModelOptions } from "../../src/domain/worker-execution-options.js";

const templates = new URL(
  "../../../profile_lab/assets/profiles/",
  import.meta.url,
);
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

