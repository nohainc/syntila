import { describe, expect, it } from "vitest";
import {
  readFileSync,
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  chmodSync,
  rmSync,
  copyFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const source = (path) =>
  readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

describe("CI acceptance orchestration", () => {
  it("builds the Profile Lab Engine without recreating a retired app directory", () => {
    const root = mkdtempSync(join(tmpdir(), "syntila-engine-output-"));
    try {
      mkdirSync(join(root, "scripts/internal"), { recursive: true });
      mkdirSync(join(root, "engines/cli_worker/.dart_tool"), { recursive: true });
      mkdirSync(join(root, "bin"));
      writeFileSync(join(root, "engines/cli_worker/pubspec.yaml"), "name: fake\nversion: 1.2.3\n");
      writeFileSync(join(root, "engines/cli_worker/.dart_tool/package_config.json"), "{}");
      copyFileSync(new URL("./internal/build-cli-worker-engine.sh", import.meta.url), join(root, "scripts/internal/build-cli-worker-engine.sh"));
      const dart = join(root, "bin/dart");
      writeFileSync(dart, '#!/bin/sh\nwhile [ "$1" != "-o" ]; do shift; done\nshift\nprintf engine > "$1"\n');
      chmodSync(dart, 0o755);
      const result = spawnSync("bash", [join(root, "scripts/internal/build-cli-worker-engine.sh")], {
        env: { ...process.env, SYNTILA_DART_EXECUTABLE: dart, SYNTILA_BUILD_TARGET_OS: "", SYNTILA_BUILD_TARGET_ARCH: "" },
        encoding: "utf8",
      });
      expect(result.status, result.stderr).toBe(0);
      expect(readFileSync(join(root, "dist/cli-worker-engine/host/syntila-agent"), "utf8")).toBe("engine");
      expect(readFileSync(join(root, "apps/profile_lab/assets/engines/syntila-agent"), "utf8")).toBe("engine");
      expect(() => readFileSync(join(root, "apps/workspace/assets/engines/syntila-agent"))).toThrow();
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
  it("releases an unsigned selected build and rejects incorrect artifact checksums", () => {
    const root = mkdtempSync(join(tmpdir(), "syntila-windows-release-"));
    try {
      const release = join(root, "release");
      const bin = join(root, "bin");
      mkdirSync(release);
      mkdirSync(bin);
      const version = "1.2.3";
      const sha = "a".repeat(40);
      const installer = `Syntila-Connect-${version}-windows-x64-Setup.exe`;
      const portable = `Syntila-Connect-${version}-windows-x64-portable.zip`;
      writeFileSync(join(release, installer), "installer");
      writeFileSync(join(release, portable), "portable");
      writeFileSync(join(release, "build.json"), JSON.stringify({version, commit: sha, run_id: "123"}));
      const hashes = spawnSync("shasum", ["-a", "256", installer, portable], {cwd: release, encoding: "utf8"});
      expect(hashes.status, hashes.stderr).toBe(0);
      // PowerShell writes CRLF; the release must still verify it.
      writeFileSync(join(release, "SHA256SUMS"), hashes.stdout.replace(/\n/g, "\r\n"));
      const gh = join(bin, "gh");
      writeFileSync(gh, '#!/bin/sh\nif [ "$1" = release ] && [ "$2" = view ]; then\n  if [ "$RELEASE_EXISTS" = 1 ]; then case "$*" in *--json*) printf "SHA256SUMS-macos\\n";; esac; exit 0; fi\n  exit 1\nfi\nif [ "$1" = api ]; then printf "%s\\n" "$TAG_COMMIT"; exit 0; fi\nprintf "%s\\n" "$*" > "$RELEASE_LOG"\n');
      chmodSync(gh, 0o755);
      const workflow = source(".github/workflows/release-windows.yml");
      const script = workflow.split("      - name: Verify artifacts and create release\n")[1]
        .split("        run: |\n")[1].split("\n").map((line) => line.slice(10)).join("\n");
      const run = (extra = {}) => spawnSync("bash", ["-c", script], {
        cwd: root, encoding: "utf8", env: {...process.env, PATH: `${bin}:${process.env.PATH}`,
          BUILD_RUN_ID: "123", BUILD_SHA: sha, NOTES: "", GH_REPO: "o/r", RELEASE_LOG: join(root, "release.log"), ...extra},
      });
      const result = run();
      expect(result.status, result.stderr).toBe(0);
      expect(readFileSync(join(root, "release.log"), "utf8")).toContain(`release create connect-v${version}`);
      // Another platform already created the release on this commit: the Windows files are added to it.
      const added = run({RELEASE_EXISTS: "1", TAG_COMMIT: sha});
      expect(added.status, added.stderr).toBe(0);
      expect(readFileSync(join(root, "release.log"), "utf8")).toContain(`release upload connect-v${version}`);
      // A release on another commit must not receive these files.
      expect(run({RELEASE_EXISTS: "1", TAG_COMMIT: "b".repeat(40)}).status).not.toBe(0);
      writeFileSync(join(release, installer), "modified");
      expect(run().status).not.toBe(0);
    } finally {
      rmSync(root, {recursive: true, force: true});
    }
  });
  it("uses the public Connect platform builder in the release workflow", () => {
    for (const [workflow, command] of [
      ["build-connect-windows.yml", "./scripts/build-connect-windows.ps1 -Production"],
    ]) {
      expect(source(`.github/workflows/${workflow}`)).toContain(command);
    }
  });

  it("derives the Windows release version from complete Git history", () => {
    const content = source(".github/workflows/build-connect-windows.yml");
    expect(content).toContain("node scripts/release-version.mjs");
    expect(content.match(/fetch-depth: 0/g)).toHaveLength(2);
    expect(content).not.toContain("inputs.version");
  });

  it("gives both explicit Cloud fixture files exactly one test owner", () => {
    const scripts = JSON.parse(source("package.json")).scripts;
    for (const file of [
      "v8-schema-clean-room-acceptance.test.ts",
      "work-v1-v8-regression.acceptance.test.ts",
    ]) {
      expect(scripts.test).toContain(`--exclude apps/cloud/test/${file}`);
      expect(scripts["check:fixture-e2e"]).toContain(`apps/cloud/test/${file}`);
    }
    expect(
      scripts["check:typescript"].match(/check:fixture-e2e/g),
    ).toHaveLength(1);
    expect(scripts.check).toContain("check:apps");
    expect(source("scripts/check-dart-packages.sh")).not.toMatch(
      /apps\/(app|profile_lab)/,
    );
  });

  it.each(["profile-lab"])(
    "%s prepared build reuses preparation; default release cleans",
    (name) => {
      const root = mkdtempSync(join(tmpdir(), "syntila-ci-"));
      const appName = name.replaceAll("-", "_");
      const app = join(root, "apps", appName);
      const bin = join(root, "bin");
      const log = join(root, "commands");
      mkdirSync(join(root, "scripts", "internal"), { recursive: true });
      mkdirSync(join(app, ".dart_tool"), { recursive: true });
      mkdirSync(join(app, "assets", "engines"), { recursive: true });
      mkdirSync(bin);
      writeFileSync(join(app, "pubspec.yaml"), "version: 1.0.0\n");
      writeFileSync(join(app, ".dart_tool", "package_config.json"), "{}\n");
      const engine = join(app, "assets", "engines", "syntila-agent");
      writeFileSync(engine, "#!/bin/sh\nexit 0\n");
      chmodSync(engine, 0o755);
      for (const command of [
        "uname",
        "node",
        "flutter",
        "dart",
        "ditto",
        "security",
        "codesign",
      ]) {
        const script =
          command === "uname"
            ? "echo Darwin"
            : command === "node"
              ? "echo '{}'"
              : command === "security"
                ? 'echo "1) ABC Apple Development: vitalii@nohainc.com (7X62W6499P)"'
                : command === "dart"
                  ? 'while [ "$1" != "-o" ] && [ "$#" -gt 0 ]; do shift; done; if [ "$1" = "-o" ]; then shift; mkdir -p "$(dirname "$1")"; touch "$1"; fi'
                  : command === "codesign"
                    ? 'if [ "$1" = "-dv" ] || [ "$1" = "-d" ]; then exit 1; fi; exit 0'
                    : command === "flutter"
                        ? `echo "flutter $*" >> "$CI_TEST_LOG"\nif [ "$1" = build ]; then app='build/macos/Build/Products/Release/Syntila Profile Lab.app'; mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"; printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Syntila</string></dict></plist>' > "$app/Contents/Info.plist"; touch "$app/Contents/MacOS/Syntila"; chmod 755 "$app/Contents/MacOS/Syntila"; fi`
                        : "exit 0";
        writeFileSync(join(bin, command), `#!/bin/sh\n${script}\n`);
        chmodSync(join(bin, command), 0o755);
      }
      writeFileSync(
        join(root, "scripts", "internal", "build-cli-worker-engine.sh"),
        'echo engine >> "$CI_TEST_LOG"\n',
      );
      const script = join(root, "scripts", `build-${name}-macos.sh`);
      copyFileSync(
        new URL(`../scripts/build-${name}-macos.sh`, import.meta.url),
        script,
      );
      const run = (args) =>
        spawnSync("bash", [script, ...args], {
          env: {
            ...process.env,
            PATH: `${bin}:${process.env.PATH}`,
            CI_TEST_LOG: log,
          },
        });
      try {
        const prepared = run(["--prepared"]);
        expect(prepared.status, prepared.stderr.toString()).toBe(0);
        expect(readFileSync(log, "utf8")).toBe(
          "flutter build macos --release --dart-define=" +
            "SYNTILA_PROFILE_LAB_VERSION=1.0.0 --dart-define=SYNTILA_PROFILE_LAB_ENVIRONMENT=production" +
            "\n",
        );
        writeFileSync(log, "");
        expect(run([]).status).toBe(0);
        expect(readFileSync(log, "utf8")).toContain(
          "flutter clean\nflutter pub get\nengine\n",
        );
        rmSync(engine);
        expect(run(["--prepared"]).status).toBe(1);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
  );
});
