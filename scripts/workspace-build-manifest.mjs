import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const [mode, directory, version] = process.argv.slice(2);
if (!["record", "verify"].includes(mode) || !directory || !version) {
  throw new Error(
    "Usage: workspace-build-manifest.mjs record|verify BUNDLE VERSION",
  );
}
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const sources = execFileSync(
  "git",
  [
    "ls-files",
    "--cached",
    "--others",
    "--exclude-standard",
    "--deduplicate",
    "-z",
    "apps/workspace/lib",
    "apps/workspace/bin",
    "apps/workspace/pubspec.yaml",
    "apps/workspace/pubspec.lock",
    "engines/cli_worker/lib",
    "engines/cli_worker/bin",
    "engines/cli_worker/pubspec.yaml",
    "engines/cli_worker/pubspec.lock",
    "packages",
    "scripts/internal/build-workspace-service.sh",
    "scripts/build-workspace-macos.sh",
    "scripts/internal/build-cli-worker-engine.sh",
  ],
  { cwd: root },
)
  .toString()
  .split("\0")
  .filter(Boolean)
  .filter((name) => /\.(dart|yaml|lock|json|sh)$/.test(name))
  .sort();
const sourceDigest = digest(
  sources
    .map((name) => `${name}\0${digest(readFileSync(join(root, name)))}`)
    .join("\n"),
);
const bundle = resolve(directory);
const files = Object.fromEntries(
  ["syntila", "assets/engines/syntila-agent"].map((name) => [
    name,
    digest(readFileSync(join(bundle, name))),
  ]),
);
const expected = { schemaVersion: 1, version, sourceDigest, files };
const manifest = join(bundle, "build-manifest.json");
if (mode === "record") {
  writeFileSync(manifest, `${JSON.stringify(expected, null, 2)}\n`);
  const gitCommit = execFileSync("git", ["rev-parse", "HEAD"], { cwd: root })
    .toString()
    .trim();
  const changedFiles = execFileSync(
    "git",
    ["status", "--porcelain", "--untracked-files=normal"],
    { cwd: root },
  )
    .toString()
    .trim();
  writeFileSync(
    join(bundle, "build-provenance.json"),
    `${JSON.stringify(
      {
        schemaVersion: 1,
        version,
        gitCommit,
        sourceDigest,
        includesUncommittedChanges: changedFiles.length > 0,
        changedFiles: changedFiles.split("\n").filter(Boolean),
        environment: process.env.SYNTILA_WORKSPACE_ENVIRONMENT || "production",
      },
      null,
      2,
    )}\n`,
  );
} else if (
  JSON.stringify(JSON.parse(readFileSync(manifest, "utf8"))) !==
  JSON.stringify(expected)
) {
  throw new Error(
    "Stale or modified Workspace build: rebuild the headless bundle before packaging.",
  );
}
