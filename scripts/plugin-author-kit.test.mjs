import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { buildPluginAuthorKit } from "./build-plugin-author-kit.mjs";

test(
  "extracted author kit builds and conformance-tests a plugin without the checkout",
  { timeout: 120000 },
  () => {
    const temp = mkdtempSync(join(tmpdir(), "author-kit-smoke-"));
    try {
      const archive = buildPluginAuthorKit(temp);
      const files = execFileSync("tar", ["-tzf", archive], {
        encoding: "utf8",
      });
      assert.doesNotMatch(
        files,
        /(?:\.dart_tool|\.env|entitlement|trusted-signers|\/test\/|\.pem|node_modules)/,
      );
      execFileSync("tar", ["-xzf", archive, "-C", temp]);
      const root = join(temp, "syntila-plugin-author-kit");
      for (const line of readFileSync(join(root, "MANIFEST.sha256"), "utf8")
        .trim()
        .split("\n")) {
        const [hash, relative] = line.split("  ");
        assert.equal(
          createHash("sha256")
            .update(readFileSync(join(root, relative)))
            .digest("hex"),
          hash,
        );
      }
      const dart = (cwd, args) =>
        execFileSync("dart", args, { cwd, encoding: "utf8", timeout: 60000 });
      const sdk = join(root, "packages/syntila_plugin_sdk");
      dart(sdk, ["pub", "get"]);
      const project = join(root, "my-plugin");
      dart(sdk, ["run", "syntila_plugin_sdk:init", project, "my-plugin"]);
      dart(project, ["pub", "get"]);
      dart(project, [
        "compile",
        "exe",
        "bin/main.dart",
        "-o",
        process.platform === "win32" ? "bin/plugin.exe" : "bin/plugin",
      ]);
      dart(project, ["run", "syntila_plugin_sdk:pack", "."]);
      const runner = join(root, "packages/syntila_plugin_conformance");
      dart(runner, ["pub", "get"]);
      const report = JSON.parse(
        dart(runner, [
          "run",
          "bin/syntila_plugin_conformance.dart",
          "--json",
          project,
        ]),
      );
      assert.equal(report.passed, true);
      assert.equal(report.cases.length, 15);
    } finally {
      rmSync(temp, { recursive: true, force: true });
    }
  },
);
