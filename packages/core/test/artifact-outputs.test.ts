import { describe, expect, it } from "vitest";
import {
  MAX_ARTIFACT_OUTPUTS,
  artifactOutputMatches,
  normalizeArtifactOutputs,
  validArtifactOutputPattern,
} from "../src/artifact-outputs.js";

describe("artifact output declarations", () => {
  it("accepts plain file names with at most one star", () => {
    for (const ok of ["report.md", "*.png", "data-*", "a_b.c"]) expect(validArtifactOutputPattern(ok)).toBe(true);
    for (const bad of ["", "/etc/passwd", "../x", "out/result.json", "a\\b", "**", "*.*", "a b", "..", ".", "x".repeat(101)])
      expect(validArtifactOutputPattern(bad)).toBe(false);
  });

  it("matches exact names and a single star", () => {
    expect(artifactOutputMatches(["report.md"], "report.md")).toBe(true);
    expect(artifactOutputMatches(["report.md"], "other.md")).toBe(false);
    expect(artifactOutputMatches(["*.png"], "chart.png")).toBe(true);
    expect(artifactOutputMatches(["*.png"], "chart.jpg")).toBe(false);
    expect(artifactOutputMatches(["data-*"], "data-1.csv")).toBe(true);
    expect(artifactOutputMatches([], "report.md")).toBe(false);
    expect(artifactOutputMatches(["../x"], "../x")).toBe(false);
  });

  it("drops invalid and duplicate entries and caps the count", () => {
    expect(normalizeArtifactOutputs(["a", "a", "../b", 3, "c"])).toEqual(["a", "c"]);
    expect(normalizeArtifactOutputs("a")).toEqual([]);
    expect(normalizeArtifactOutputs(Array.from({ length: 20 }, (_, i) => `f${i}`))).toHaveLength(MAX_ARTIFACT_OUTPUTS);
  });
});
