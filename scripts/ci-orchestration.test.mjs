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
  it("nightly Workspace compilation does not require a release certificate", () => {
    expect(source(".github/workflows/nightly.yml")).toContain(
      "bash scripts/build-workspace-macos.sh --debug --prepared",
    );
    expect(source(".github/workflows/release-macos.yml")).toContain(
      "Configure Developer ID and notarization",
    );
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
      /apps\/(app|workspace|profile_lab)/,
    );
  });

  it("aggregation rejects failed and skipped domains", () => {
    const workflow = source(".github/workflows/ci.yml");
    const gateSection = workflow.slice(workflow.indexOf("  ci-passed:"));
    const dependencies = gateSection
      .match(/needs:\s*\[([\s\S]*?)\]/)[1]
      .split(",")
      .map((name) => name.trim())
      .filter(Boolean);
    expect(dependencies.sort()).toEqual(
      [
        "changes",
        "static",
        "cloud",
        "dart-packages",
        "app",
        "workspace",
        "workspace-gui",
        "profile-lab",
        "engine",
        "site",
      ].sort(),
    );
    const gate = workflow.match(
      /if ! echo "\$NEEDS" \| (jq -e '[^']+') > \/dev\/null/,
    )[1];
    for (const [result, expectedStatus] of [
      ["success", 0],
      ["skipped", 0],
      ["failure", 1],
      ["cancelled", 1],
    ]) {
      const run = spawnSync("sh", ["-c", `echo "$NEEDS" | ${gate}`], {
        env: {
          ...process.env,
          NEEDS: JSON.stringify({ domain: { result } }),
        },
      });
      expect(run.status, run.stderr.toString()).toBe(expectedStatus);
    }
    expect(workflow).toContain(
      "cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
    );
    expect(workflow).not.toContain("windows-latest");
    expect(workflow).not.toContain("pnpm check\n");
  });

  it.each(["profile-lab"])(
    "%s prepared build reuses preparation; default release cleans",
    (name) => {
      const root = mkdtempSync(join(tmpdir(), "syntila-ci-"));
      const appName = name.replaceAll("-", "_");
      const app = join(root, "apps", appName);
      const bin = join(root, "bin");
      const log = join(root, "commands");
      mkdirSync(join(root, "scripts"), { recursive: true });
      mkdirSync(join(app, ".dart_tool"), { recursive: true });
      mkdirSync(join(app, "assets", "engines"), { recursive: true });
      if (name === "workspace") {
        mkdirSync(join(app, "macos", "Runner", "LaunchAgents"), {
          recursive: true,
        });
        writeFileSync(
          join(
            app,
            "macos",
            "Runner",
            "LaunchAgents",
            "com.syntila.workspace.service.plist",
          ),
          `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>com.syntila.workspace.service</string>
<key>AssociatedBundleIdentifiers</key><array><string>com.syntila.workspace</string></array>
<key>BundleProgram</key><string>Contents/Helpers/workspace</string>
<key>ProgramArguments</key><array><string>Contents/Helpers/workspace</string></array>
<key>RunAtLoad</key><false/>
</dict></plist>
`,
        );
      }
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
        "PlistBuddy",
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
                    : command === "PlistBuddy"
                      ? 'if [ "$1" = "-c" ] && [ "$2" = "Print :CFBundleExecutable" ]; then echo Syntila; elif [ "$1" = "-c" ] && [ "$2" = "Print :CFBundleIdentifier" ]; then echo com.syntila.workspace; elif [ "$1" = "-c" ] && [ "$2" = "Print :Label" ]; then echo com.syntila.workspace.service; elif [ "$1" = "-c" ] && [ "$2" = "Print :AssociatedBundleIdentifiers:0" ]; then echo com.syntila.workspace; elif [ "$1" = "-c" ] && [ "$2" = "Print :BundleProgram" ]; then echo Contents/Helpers/workspace; elif [ "$1" = "-c" ] && [ "$2" = "Print :ProgramArguments:0" ]; then echo Contents/Helpers/workspace; elif [ "$1" = "-c" ] && [ "$2" = "Print :RunAtLoad" ]; then echo false; else exit 1; fi'
                      : command === "flutter"
                        ? `echo "flutter $*" >> "$CI_TEST_LOG"\nif [ "$1" = build ]; then app='build/macos/Build/Products/Release/Syntila ${name === "workspace" ? "Workspace" : "Profile Lab"}.app'; mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"; printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Syntila</string></dict></plist>' > "$app/Contents/Info.plist"; touch "$app/Contents/MacOS/Syntila"; chmod 755 "$app/Contents/MacOS/Syntila"; fi`
                        : "exit 0";
        writeFileSync(join(bin, command), `#!/bin/sh\n${script}\n`);
        chmodSync(join(bin, command), 0o755);
      }
      writeFileSync(
        join(root, "scripts", "build-cli-worker-engine.sh"),
        'echo engine >> "$CI_TEST_LOG"\n',
      );
      if (name === "workspace") {
        copyFileSync(
          new URL(
            "../scripts/verify-workspace-service-bundle.sh",
            import.meta.url,
          ),
          join(root, "scripts", "verify-workspace-service-bundle.sh"),
        );
      }
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
            (name === "workspace"
              ? "SYNTILA_WORKSPACE_VERSION=1.0.0 --dart-define=SYNTILA_WORKSPACE_ENVIRONMENT=production --dart-define=SYNTILA_RELEASE_TRUST_KEYS_JSON={}"
              : "SYNTILA_PROFILE_LAB_VERSION=1.0.0 --dart-define=SYNTILA_PROFILE_LAB_ENVIRONMENT=production") +
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

  it("workspace macOS build is a pure Dart bundle; prepared reuses preparation", () => {
    const root = mkdtempSync(join(tmpdir(), "syntila-ci-"));
    const app = join(root, "apps", "workspace");
    const bin = join(root, "bin");
    const log = join(root, "commands");
    mkdirSync(join(root, "scripts"), { recursive: true });
    mkdirSync(join(app, ".dart_tool"), { recursive: true });
    mkdirSync(join(app, "assets", "engines"), { recursive: true });
    mkdirSync(bin);
    writeFileSync(join(app, "pubspec.yaml"), "version: 1.0.0\n");
    writeFileSync(join(app, ".dart_tool", "package_config.json"), "{}\n");
    const engine = join(app, "assets", "engines", "syntila-agent");
    writeFileSync(engine, "#!/bin/sh\nexit 0\n");
    chmodSync(engine, 0o755);
    const mocks = {
      uname: "echo Darwin",
      node: "echo '{}'",
      security:
        'echo "1) ABC Apple Development: vitalii@nohainc.com (7X62W6499P)"',
      codesign:
        'if [ "$1" = "-dv" ] || [ "$1" = "-d" ]; then exit 1; fi; exit 0',
      ditto:
        'if [ "$1" = "-c" ]; then for last; do :; done; touch "$last"; else mkdir -p "$2" && cp -R "$1/." "$2"; fi',
      dart: `echo "dart $1 $2" >> "$CI_TEST_LOG"\nwhile [ "$1" != "-o" ] && [ "$#" -gt 0 ]; do shift; done; if [ "$1" = "-o" ]; then shift; mkdir -p "$(dirname "$1")"; touch "$1"; chmod 755 "$1"; fi`,
    };
    for (const [command, script] of Object.entries(mocks)) {
      writeFileSync(join(bin, command), `#!/bin/sh\n${script}\n`);
      chmodSync(join(bin, command), 0o755);
    }
    writeFileSync(
      join(root, "scripts", "build-cli-worker-engine.sh"),
      'echo engine >> "$CI_TEST_LOG"\n',
    );
    for (const name of [
      "build-workspace-macos.sh",
      "verify-workspace-service-bundle.sh",
    ]) {
      copyFileSync(
        new URL(`../scripts/${name}`, import.meta.url),
        join(root, "scripts", name),
      );
    }
    const script = join(root, "scripts", "build-workspace-macos.sh");
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
      expect(readFileSync(log, "utf8")).toBe("dart compile exe\n");
      const bundle = join(root, "dist", "syntila", "macos", "syntila");
      for (const file of ["syntila", "assets/engines/syntila-agent"]) {
        expect(readFileSync(join(bundle, file)) !== undefined).toBe(true);
      }
      writeFileSync(log, "");
      expect(run([]).status).toBe(0);
      expect(readFileSync(log, "utf8")).toBe(
        "dart pub get\nengine\ndart compile exe\n",
      );
      rmSync(engine);
      expect(run(["--prepared"]).status).toBe(1);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("public site production deployment is decoupled with path filtering and self-contained validation", () => {
    const workflow = source(".github/workflows/deploy-site.yml");
    const checkAction = source(".github/actions/check-site/action.yml");
    expect(workflow).toContain("branches: [main]");
    expect(workflow).toContain('paths:\n      - "apps/site/**"');
    expect(workflow).toContain("workflow_dispatch:");
    expect(workflow).not.toContain('workflows: ["CI"]');
    expect(workflow).not.toContain("workflow_run:");

    // Ensures site builds and all validations are present
    expect(checkAction).toContain("./node_modules/.bin/astro check");
    expect(checkAction).toContain("./node_modules/.bin/astro build");
    expect(checkAction).toContain("node scripts/check-performance.mjs");
    expect(checkAction).toContain("node scripts/check-accessibility.mjs");
    expect(checkAction).toContain("node scripts/check-responsive.mjs");
    expect(checkAction).toContain("node scripts/check-analytics-privacy.mjs");
    expect(checkAction).toContain("node scripts/check-security.mjs");
    expect(checkAction).toContain("node scripts/check-content.mjs");
    expect(checkAction).toContain("node scripts/check-release.mjs");
    expect(checkAction).toContain("./node_modules/.bin/vitest run test");
    expect(checkAction).toContain("Verify static routes");
    expect(workflow).toContain(
      "../../node_modules/.bin/wrangler deploy --config wrangler.production.jsonc",
    );
  });
});

describe("production OAuth secret continuity", () => {
  it("resolves existing repository secret names in both deployment paths", () => {
    for (const path of [
      ".github/workflows/deploy-cloud.yml",
      ".github/workflows/sync-production-oauth.yml",
    ]) {
      for (const suffix of [
        "GITHUB_CLIENT_ID",
        "GITHUB_CLIENT_SECRET",
        "GOOGLE_CLIENT_ID",
        "GOOGLE_CLIENT_SECRET",
      ]) {
        expect(source(path)).toContain(
          `secrets.SYNTILA_AUTH_${suffix} || secrets.CONCLAVE_AUTH_${suffix}`,
        );
      }
    }
  });
  it("syncs only OAuth credentials without rotating the session encryption secret", () => {
    const workflow = source(".github/workflows/sync-production-oauth.yml");
    expect(workflow).toContain(
      "secret bulk oauth-secrets.json --name syntila-app",
    );
    expect(workflow).not.toContain("secrets.BETTER_AUTH_SECRET");
    expect(workflow).toContain("mode: 0o600");
    expect(workflow).toContain("if: always()");
    expect(workflow).toContain("rm -f oauth-secrets.json");
  });
});
