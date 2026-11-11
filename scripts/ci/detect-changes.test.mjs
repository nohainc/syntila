import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const detector = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "detect-changes.sh",
);
for (const path of [
  "packages/syntila_external_worker_protocol/lib/manifest.dart",
  "packages/syntila_external_worker_conformance/lib/mcp_runner.dart",
  "packages/syntila_external_worker_sdk/lib/run_mcp_worker.dart",
  "examples/mcp/echo_worker/echo_worker.dart",
]) {
  test(`plugin change selects Dart and Engine checks: ${path}`, () => {
    const root = mkdtempSync(join(tmpdir(), "syntila-ci-filter-"));
    try {
      const git = (...args) =>
        execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
      git("init", "-q");
      const commit = () => {
        git("add", ".");
        git(
          "-c",
          "user.name=CI Test",
          "-c",
          "user.email=ci@example.invalid",
          "commit",
          "-qm",
          "fixture",
        );
      };
      writeFileSync(join(root, "base"), "base");
      commit();
      const base = git("rev-parse", "HEAD");
      mkdirSync(dirname(join(root, path)), { recursive: true });
      writeFileSync(join(root, path), "fixture");
      commit();
      const output = join(root, "output");
      execFileSync("bash", [detector], {
        cwd: root,
        env: {
          ...process.env,
          EVENT_NAME: "pull_request",
          BASE_SHA: base,
          HEAD_SHA: git("rev-parse", "HEAD"),
          GITHUB_OUTPUT: output,
        },
      });
      const selected = Object.fromEntries(
        readFileSync(output, "utf8")
          .trim()
          .split("\n")
          .map((line) => line.split("=")),
      );
      assert.equal(selected.dart, "true");
      assert.equal(selected.engine, "true");
      assert.equal(selected.cloud, "false");
      if (path.startsWith("packages/"))
        assert.equal(selected.workspace, "true");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
}
