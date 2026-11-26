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
  it("points signed Connect release and installer checks at the available signer", () => {
    const signer = "sign-connect-windows.ps1";
    expect(source(`scripts/${signer}`)).toContain("VerifyOnly");
    for (const file of [
      ".github/workflows/build-connect-windows.yml",
      "scripts/package-connect-windows.ps1",
      "scripts/test-connect-windows-installer.ps1",
    ]) {
      expect(source(file)).toContain(signer);
    }
  });
  it("uses the public Connect platform builder in the release workflow", () => {
    for (const [workflow, command] of [
      ["build-connect-windows.yml", "./scripts/build-connect-windows.ps1 -Production"],
    ]) {
      expect(source(`.github/workflows/${workflow}`)).toContain(command);
    }
  });

  it("derives every release version from the checked-out pubspec", () => {
    for (const [workflow, pubspec] of [
      ["build-connect-windows.yml", "apps/connect/pubspec.yaml"],
    ]) {
      const content = source(`.github/workflows/${workflow}`);
      expect(content).toContain(
        `awk '/^version:/ {print $2; exit}' ${pubspec}`,
      );
      expect(content).not.toContain("inputs.version");
    }
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
