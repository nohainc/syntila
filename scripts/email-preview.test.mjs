import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { describe, expect, it } from "vitest";

describe("email preview command", () => {
  it("renders every catalog template without a transport", () => {
    const root = mkdtempSync(join(tmpdir(), "syntila-email-preview-"));
    try {
      const result = spawnSync(
        process.execPath,
        [
          "--experimental-transform-types",
          "--experimental-loader",
          resolve("scripts/email-ts-loader.mjs"),
          resolve("scripts/email-preview.mjs"),
          "--out",
          root,
        ],
        { encoding: "utf8" },
      );
      expect(result.status).toBe(0);
      const files = readdirSync(root);
      expect(files.filter((file) => file.endsWith(".html"))).toHaveLength(13); // 12 templates + index.html
      expect(files.filter((file) => file.endsWith(".txt"))).toHaveLength(12);
      expect(readFileSync(join(root, "index.html"), "utf8")).toContain(
        "Synthetic data only",
      );
      expect(
        files
          .filter((file) => file.endsWith(".html"))
          .map((file) => readFileSync(join(root, file), "utf8"))
          .join("\n"),
      ).not.toContain("preview-secret");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
